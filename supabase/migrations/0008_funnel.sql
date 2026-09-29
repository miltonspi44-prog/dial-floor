-- Dial Floor · 0008 funnel (F1) and targets (F4)
--   · every dial records where it came from (a due callback, a list, or the pool)
--     and which list, so the funnel can be read by list
--   · funnel(days): dials → answered → conversations → handoffs over the last N
--     business days (1 = today), in total and by agent, source, intent and the
--     lead's local hour (manager only)

alter table public.attempts
  add column if not exists source text check (source in ('callback', 'list', 'pool')),
  add column if not exists list_id bigint references public.lists(id) on delete set null;
create index if not exists attempts_clicked_idx on public.attempts (clicked_at);

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
  v_source text := 'pool';
  v_list bigint;
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

  -- where this dial came from, for the funnel (same order next_lead serves in)
  if exists (select 1 from callbacks c
              where c.lead_id = p_lead_id and c.agent_id = v_uid and c.status = 'scheduled'
                and c.due_at <= now() + interval '10 minutes') then
    v_source := 'callback';
  else
    select li.list_id into v_list
      from list_items li join lists ld on ld.id = li.list_id
      where li.lead_id = p_lead_id and li.served_at is null and ld.status = 'active'
        and (ld.agent_id = v_uid or ld.agent_id is null)
      order by (ld.agent_id is null), ld.list_date desc, li.position limit 1;
    if v_list is not null then v_source := 'list'; end if;
  end if;

  insert into attempts (lead_id, agent_id, source, list_id)
    values (p_lead_id, v_uid, v_source, v_list) returning id into v_attempt;

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

-- ------------------------------------------------------------------ funnel --
-- answered      = Zoom says the far end picked up (person, voicemail or machine),
--                 or the agent logged a conversation (Zoom may not have matched the
--                 call), so every stage is a subset of the one before
-- conversations = the agent logged a live-person outcome (attempts.connected)
-- handoffs      = the W / S exits (chance given, sale closed)
create or replace function public.funnel(p_days int default 1)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 1), 366));
  v_from timestamptz := public.business_day_start() - make_interval(days => v_days - 1);
  r jsonb;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  with a as (
    select a.agent_id, a.lead_id, a.clicked_at, a.source, a.list_id, a.disposition, l.tz,
           coalesce(a.call_result = 'answered', false) or coalesce(a.connected, false) as answered,
           coalesce(a.connected, false) as convo,
           coalesce(a.disposition in ('chance_website', 'sale_closed'), false) as handoff,
           case when a.call_result = 'answered' then coalesce(a.duration_seconds, 0) else 0 end as talk
      from attempts a join leads l on l.id = a.lead_id
     where a.clicked_at >= v_from
  )
  select jsonb_build_object(
    'from', v_from, 'days', v_days,
    'totals', (select jsonb_build_object(
        'dials', count(*), 'answered', count(*) filter (where answered),
        'conversations', count(*) filter (where convo), 'handoffs', count(*) filter (where handoff),
        'callbacks', count(*) filter (where disposition = 'callback'),
        'emails', count(*) filter (where disposition = 'email_requested'),
        'talk_seconds', coalesce(sum(talk), 0)) from a),
    'by_agent', (select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
        select jsonb_build_object('agent_id', p.id, 'name', p.name,
          'days', count(distinct (a.clicked_at at time zone public.business_tz())::date),
          'dials', count(*), 'answered', count(*) filter (where a.answered),
          'conversations', count(*) filter (where a.convo), 'handoffs', count(*) filter (where a.handoff),
          'talk_seconds', coalesce(sum(a.talk), 0)) as x
        from a join profiles p on p.id = a.agent_id
        group by p.id, p.name) s),
    'by_source', (select coalesce(jsonb_agg(x order by (x->>'dials')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('source', coalesce(a.source, 'untracked'), 'list', ld.name,
          'dials', count(*), 'answered', count(*) filter (where a.answered),
          'conversations', count(*) filter (where a.convo), 'handoffs', count(*) filter (where a.handoff)) as x
        from a left join lists ld on ld.id = a.list_id
        group by coalesce(a.source, 'untracked'), ld.id, ld.name) s),
    'by_intent', (select coalesce(jsonb_agg(x order by (x->>'dials')::int desc, x->>'label'), '[]'::jsonb) from (
        select jsonb_build_object('intent', ic.key, 'label', ic.label,
          'dials', count(*), 'answered', count(*) filter (where a.answered),
          'conversations', count(*) filter (where a.convo), 'handoffs', count(*) filter (where a.handoff)) as x
        from a join lead_intents li on li.lead_id = a.lead_id join intents_catalog ic on ic.key = li.intent_key
        group by ic.key, ic.label) s),
    'by_hour', (select coalesce(jsonb_agg(x order by (x->>'hour')::int), '[]'::jsonb) from (
        select jsonb_build_object('hour', h,
          'dials', count(*), 'answered', count(*) filter (where answered),
          'conversations', count(*) filter (where convo), 'handoffs', count(*) filter (where handoff)) as x
        from (select *, extract(hour from clicked_at at time zone coalesce(tz, 'America/New_York'))::int as h from a) t
        group by h) s)
  ) into r;
  return r;
end $$;

revoke execute on function public.funnel(int) from public, anon;
grant execute on function public.funnel(int) to authenticated;
