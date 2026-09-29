-- Dial Floor · 0006 Phase 1 fixes
-- Found auditing the build against the Phase 1 plan (each one reproduced by a test first):
--   · a rest ends: "not interested" and language-barrier leads rejoin the queue when
--     their 10/20/60-day rest is over (they were dropped from the queue for good)
--   · agents can't change their own role or active flag (anyone could make themselves manager)
--   · a deactivated user is served nothing and can't dial
--   · the calling window is checked again at dial time, not only when the lead was served
--   · heartbeat('ping') keeps a tile fresh; the floor board shows a browser that went quiet as offline

-- ---------------------------------------------------------------- rests end --
create index if not exists lead_state_resting_idx on public.lead_state (rest_until) where state = 'resting';

-- Rests that have run out rejoin the queue. SKIP LOCKED: agents loading leads at
-- the same moment each wake what the other isn't already waking, never waiting.
create or replace function public.wake_rested()
returns void language sql security definer set search_path = public as $$
  update lead_state set state = 'queued', updated_at = now()
   where lead_id in (select lead_id from lead_state
                      where state = 'resting' and (rest_until is null or rest_until <= now())
                      for update skip locked);
$$;

-- --------------------------------------------------------------- next_lead --
create or replace function public.next_lead()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_max int := coalesce((public.setting('max_attempts_per_day'))::int, 2);
  v_reclaim interval := make_interval(mins => coalesce((public.setting('reclaim_minutes'))::int, 30));
  v_gap interval := make_interval(mins => coalesce((public.setting('min_redial_minutes'))::int, 120));
  v_hold interval := make_interval(mins => coalesce((public.setting('reserve_minutes'))::int, 10));
  v_today date := public.business_date();
  v_lead bigint;
  v_reason text;
  r record;
begin
  if v_uid is null then return jsonb_build_object('error', 'not signed in'); end if;

  -- 0. a call I started and never logged (page reloaded mid-call): pick it back up
  --    (even when deactivated meanwhile, so the call still gets its outcome)
  select a.id, a.lead_id, a.clicked_at into r
    from attempts a
    join lead_state ls on ls.lead_id = a.lead_id
    where a.agent_id = v_uid and (a.disposition is null or a.auto_logged)
      and ls.state = 'in_progress' and ls.owner_agent = v_uid
      and a.clicked_at > now() - v_reclaim
    order by a.clicked_at desc limit 1;
  if found then
    return build_workspace(r.lead_id, 'resume')
      || jsonb_build_object('attempt_id', r.id, 'clicked_at', r.clicked_at);
  end if;

  if not exists (select 1 from profiles where id = v_uid and active) then
    return jsonb_build_object('error', 'your account is deactivated — ask your manager');
  end if;

  -- an agent holds one lead at a time
  update lead_state set reserved_by = null, reserved_until = null where reserved_by = v_uid;

  perform wake_rested();

  -- 1. my due callbacks (a promise beats every cold dial)
  select c.lead_id into v_lead
    from callbacks c
    join lead_state ls on ls.lead_id = c.lead_id
    join leads l on l.id = c.lead_id
    where c.agent_id = v_uid and c.status = 'scheduled' and c.due_at <= now() + interval '10 minutes'
      and ls.state not in ('suppressed', 'handoff')
      and (ls.state <> 'in_progress' or ls.owner_agent = v_uid or ls.in_progress_since < now() - v_reclaim)
      and (ls.reserved_by is null or ls.reserved_by = v_uid or ls.reserved_until < now())
      and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
      and local_ok(l.tz)
    order by c.due_at limit 1
    for update of ls skip locked;
  if found then v_reason := 'callback_due'; end if;

  -- 2. next from my lists, then from unassigned (shared) lists
  if v_lead is null then
    select li.lead_id into v_lead
      from lists ld
      join list_items li on li.list_id = ld.id and li.served_at is null
      join lead_state ls on ls.lead_id = li.lead_id
      join leads l on l.id = li.lead_id
      where (ld.agent_id = v_uid or ld.agent_id is null) and ld.status = 'active'
        and (ls.state in ('fresh','queued')
             or (ls.state = 'in_progress' and ls.in_progress_since < now() - v_reclaim))
        and (ls.rest_until is null or ls.rest_until <= now())
        and (ls.attempts_today_date is distinct from v_today or ls.attempts_today < v_max)
        and (ls.last_attempt_at is null or ls.last_attempt_at <= now() - v_gap)
        and (ls.reserved_by is null or ls.reserved_by = v_uid or ls.reserved_until < now())
        and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
        and local_ok(l.tz)
      order by (ld.agent_id is null), ld.list_date desc, li.position limit 1
      for update of ls skip locked;
    if found then v_reason := 'list'; end if;
  end if;

  -- 3. general pool (manager can turn this off in settings)
  if v_lead is null and coalesce((public.setting('allow_general_pool'))::boolean, true) then
    select ls.lead_id into v_lead
      from lead_state ls
      join leads l on l.id = ls.lead_id
      where (ls.state in ('fresh','queued')
             or (ls.state = 'in_progress' and ls.in_progress_since < now() - v_reclaim))
        and (ls.rest_until is null or ls.rest_until <= now())
        and (ls.attempts_today_date is distinct from v_today or ls.attempts_today < v_max)
        and (ls.last_attempt_at is null or ls.last_attempt_at <= now() - v_gap)
        and (ls.reserved_by is null or ls.reserved_by = v_uid or ls.reserved_until < now())
        and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
        -- a lead waiting on another agent's list stays with that agent
        and not exists (select 1 from list_items li join lists ld on ld.id = li.list_id
                        where li.lead_id = ls.lead_id and li.served_at is null and ld.status = 'active'
                          and ld.agent_id is not null and ld.agent_id <> v_uid)
        and local_ok(l.tz)
      order by l.score desc nulls last, l.review_count desc nulls last limit 1
      for update of ls skip locked;
    if found then v_reason := 'pool'; end if;
  end if;

  if v_lead is null then
    return jsonb_build_object('empty', true,
      'hint', 'No eligible lead right now: lists empty, callbacks not due, recently dialed leads still cooling down, or every lead is outside its local calling window.');
  end if;

  update lead_state set reserved_by = v_uid, reserved_until = now() + v_hold where lead_id = v_lead;
  return build_workspace(v_lead, v_reason);
end $$;

-- ------------------------------------------------------------ start_attempt --
create or replace function public.start_attempt(p_lead_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_reclaim interval := make_interval(mins => coalesce((public.setting('reclaim_minutes'))::int, 30));
  v_today date := public.business_date();
  l leads%rowtype;
  st lead_state%rowtype;
  v_attempt bigint;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and active) then
    raise exception 'your account is deactivated — ask your manager';
  end if;
  select * into l from leads where id = p_lead_id;
  if not found then raise exception 'lead not found'; end if;

  select * into st from lead_state where lead_id = p_lead_id for update;
  if not found or st.state in ('suppressed', 'handoff') then
    raise exception 'this lead can no longer be dialed';
  end if;
  if exists (select 1 from suppression s where s.phone_norm = l.phone_norm) then
    raise exception 'this number is on the do-not-call list';
  end if;
  if st.state = 'in_progress' and st.owner_agent is distinct from v_uid
     and st.in_progress_since > now() - v_reclaim then
    raise exception 'another agent is already dialing this lead';
  end if;
  if st.state = 'callback_locked' and st.owner_agent is distinct from v_uid then
    raise exception 'this lead is locked to another agent''s callback';
  end if;
  if st.reserved_by is not null and st.reserved_by <> v_uid and st.reserved_until > now() then
    raise exception 'another agent has this lead open';
  end if;
  -- served while the window was open doesn't mean it still is (the lead stays loaded for minutes)
  if not local_ok(l.tz) then
    raise exception 'outside this lead''s calling window: it is % there',
      to_char(now() at time zone coalesce(l.tz, 'America/New_York'), 'FMHH12:MI AM');
  end if;

  insert into attempts (lead_id, agent_id) values (p_lead_id, v_uid) returning id into v_attempt;

  update lead_state set
    state = 'in_progress',
    owner_agent = v_uid,
    in_progress_since = now(),
    reserved_by = null,
    reserved_until = null,
    attempts_today = case when attempts_today_date = v_today then attempts_today + 1 else 1 end,
    attempts_today_date = v_today,
    attempts_total = attempts_total + 1,
    last_attempt_at = now(),
    updated_at = now()
  where lead_id = p_lead_id;

  -- dialed means served, whichever list it was waiting on
  update list_items li set served_at = now()
    from lists ld
    where li.lead_id = p_lead_id and li.list_id = ld.id and ld.status = 'active' and li.served_at is null;

  insert into agent_status (agent_id, status, lead_id, lead_name, phone_display, since, updated_at)
  values (v_uid, 'dialing', p_lead_id, l.name, l.phone_display, now(), now())
  on conflict (agent_id) do update
    set status = 'dialing', lead_id = excluded.lead_id, lead_name = excluded.lead_name,
        phone_display = excluded.phone_display, since = now(), updated_at = now();

  return jsonb_build_object('attempt_id', v_attempt, 'phone', l.phone_norm, 'display', l.phone_display);
end $$;

-- -------------------------------------------------------------- build_list --
create or replace function public.build_list(p_name text, p_agent uuid, p_rules jsonb, p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_list bigint; v_count int;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  perform wake_rested();
  insert into lists (name, agent_id, rules, created_by)
    values (p_name, p_agent, p_rules, auth.uid()) returning id into v_list;
  insert into list_items (list_id, lead_id, position)
  select v_list, l.id, row_number() over (order by l.score desc nulls last, l.review_count desc nulls last)
    from leads l
    join lead_state ls on ls.lead_id = l.id
    where ls.state in ('fresh','queued')
      and (ls.rest_until is null or ls.rest_until <= now())
      and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
      and (p_rules->>'state' is null or l.addr_state = upper(p_rules->>'state'))
      and (p_rules->>'tier' is null or l.tier = upper(p_rules->>'tier'))
      and (p_rules->>'min_score' is null or l.score >= (p_rules->>'min_score')::int)
      and (p_rules->>'intent' is null or exists
            (select 1 from lead_intents li where li.lead_id = l.id and li.intent_key = p_rules->>'intent'))
      and (p_rules->>'phone_type' is null or l.phone_type = p_rules->>'phone_type')
      and not exists (select 1 from list_items li2 join lists ld2 on ld2.id = li2.list_id
                      where li2.lead_id = l.id and ld2.status = 'active' and li2.served_at is null)
    limit p_limit;
  get diagnostics v_count = row_count;
  return jsonb_build_object('list_id', v_list, 'count', v_count);
end $$;

-- --------------------------------------------------------------- heartbeat --
create or replace function public.heartbeat(p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  -- 'ping' only says "still here": the tile keeps its status and stays off the stale list
  if p_status = 'ping' then
    update agent_status set updated_at = now() where agent_id = auth.uid();
    return;
  end if;
  if p_status not in ('idle','wrap','break','offline') then raise exception 'bad status'; end if;
  insert into agent_status (agent_id, status, since, updated_at)
  values (auth.uid(), p_status, now(), now())
  on conflict (agent_id) do update set status = excluded.status, since = now(), updated_at = now();
end $$;

-- ------------------------------------------------------------------ boards --
-- The app pings every minute; a browser that crashed or lost its connection
-- stops, and after 5 quiet minutes its tile shows offline instead of "dialing" forever.
create or replace view public.v_floor_today with (security_invoker = true) as
select
  p.id as agent_id, p.name, p.role,
  case when s.status is null or s.updated_at < now() - interval '5 minutes' then 'offline'
       else s.status end as status,
  case when s.updated_at < now() - interval '5 minutes' then null else s.lead_name end as lead_name,
  case when s.updated_at < now() - interval '5 minutes' then null else s.phone_display end as phone_display,
  s.since,
  count(a.id) as dials_today,
  count(a.id) filter (where a.connected) as connects_today,
  count(a.id) filter (where a.disposition in ('chance_website','sale_closed')) as handoffs_today,
  count(a.id) filter (where a.disposition = 'email_requested') as emails_today,
  s.updated_at as last_seen
from profiles p
left join agent_status s on s.agent_id = p.id
left join attempts a on a.agent_id = p.id and a.clicked_at >= public.business_day_start()
where p.active
group by p.id, p.name, p.role, s.status, s.lead_name, s.phone_display, s.since, s.updated_at;

-- --------------------------------------------------------------- profiles --
-- Agents may rename themselves and nothing else: role and active are the
-- manager's (the self-update policy used to let an agent set role = 'manager').
revoke update on public.profiles from anon, authenticated;
grant update (name) on public.profiles to authenticated;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.wake_rested() from public, anon, authenticated;
