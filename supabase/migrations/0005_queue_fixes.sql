-- Dial Floor · 0005 queue fixes + API lockdown
-- Fixes from the Phase 0 review (each one reproduced before it was fixed):
--   · callbacks finish (done / retried / missed) instead of resurfacing forever
--   · Skip works (skip_lead), and a loaded lead is reserved so two agents never share one
--   · a minimum gap before the same lead is served again
--   · "today" is a business-timezone day (UTC rolled over at 5pm PT, mid-shift)
--   · handoffs keep state 'handoff'; the pool no longer takes other agents' list leads
--   · a suppressed number is never served or dialed again, whichever lead record carries it
--   · reloading the page mid-call resumes the open attempt
--   · anon can no longer call SECURITY DEFINER functions; internal ones are service-role only

-- ------------------------------------------------------------ new columns --
alter table public.lead_state
  add column if not exists reserved_by uuid references public.profiles(id),
  add column if not exists reserved_until timestamptz;
create index if not exists lead_state_reserved_idx on public.lead_state (reserved_by) where reserved_by is not null;

alter table public.callbacks add column if not exists tries int not null default 0;
create index if not exists callbacks_lead_idx on public.callbacks (lead_id) where status = 'scheduled';

-- set by the sync worker when a lead is new; cleared once the console has been told
alter table public.leads add column if not exists console_mark_pending boolean not null default false;
create index if not exists leads_console_mark_idx on public.leads (source_id) where console_mark_pending;

-- --------------------------------------------------------------- settings --
insert into public.app_settings (key, value) values
  ('business_tz',            '"America/Los_Angeles"'), -- the business day; midnight PT is outside every US calling window
  ('min_redial_minutes',     '120'),  -- gap before the same lead is served again (0 = allow back-to-back)
  ('reserve_minutes',        '10'),   -- a loaded lead stays with the agent who loaded it this long
  ('skip_rest_minutes',      '60'),   -- a skipped lead sits out this long
  ('callback_retry_minutes', '60'),   -- unanswered callback: try again after this long
  ('callback_max_tries',     '3')     -- then it is marked missed and the lead rejoins the queue
on conflict (key) do nothing;

-- ---------------------------------------------------------------- helpers --
alter function public.norm_phone(text) set search_path = public;
alter function public.derive_tz(text, text) set search_path = public;
alter function public.setting(text) set search_path = public;
alter function public.local_ok(text) set search_path = public;

create or replace function public.business_tz()
returns text language sql stable set search_path = public as
$$ select coalesce(public.setting('business_tz') #>> '{}', 'America/Los_Angeles') $$;

create or replace function public.business_date()
returns date language sql stable set search_path = public as
$$ select (now() at time zone public.business_tz())::date $$;

create or replace function public.business_day_start()
returns timestamptz language sql stable set search_path = public as
$$ select public.business_date()::timestamp at time zone public.business_tz() $$;

alter table public.lists alter column list_date set default public.business_date();
alter table public.number_stats alter column stat_date set default public.business_date();
alter table public.radar_items alter column radar_date set default public.business_date();

-- ------------------------------------------------------------ refresh_lead --
create or replace function public.refresh_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  l leads%rowtype;
  st lead_state%rowtype;
begin
  select * into l from leads where id = p_lead_id;
  if not found then return; end if;

  update leads set tz = derive_tz(l.phone_norm, l.addr_state) where id = l.id;

  insert into lead_state (lead_id, state)
  values (l.id, 'queued')
  on conflict (lead_id) do nothing;
  select * into st from lead_state where lead_id = l.id;

  -- suppression wins over everything, forever (a handoff keeps its own state)
  if exists (select 1 from suppression s where s.phone_norm = l.phone_norm) then
    update lead_state set state = 'suppressed', owner_agent = null, reserved_by = null,
        reserved_until = null, updated_at = now()
      where lead_id = l.id and state not in ('suppressed', 'handoff');
    update callbacks set status = 'missed' where lead_id = l.id and status = 'scheduled';
    return;
  end if;

  delete from lead_intents where lead_id = l.id and source = 'auto';
  insert into lead_intents (lead_id, intent_key, confidence, source)
  select l.id, k, c, 'auto' from (values
    ('no_website',      case when l.website_type = 'none' then 1.0 end),
    ('social_only',     case when l.website_type = 'social' then 1.0 end),
    ('free_subdomain',  case when l.platform_detail like 'free-subdomain%' then 1.0 end),
    ('cheap_builder',   case when l.platform in ('wix','godaddy','weebly','duda') then 0.9 end),
    ('broken_site',     case when l.platform = 'unreachable' or l.website_type = 'unreachable' then 0.9 end),
    ('fresh_listing',   case when l.first_seen > now() - interval '30 days' then 0.8 end),
    ('review_rich',     case when l.review_count between 20 and 150 and coalesce(l.rating, 0) >= 4 then 0.9 end),
    ('reputation_risk', case when l.review_count >= 10 and l.rating < 3.8 then 0.8 end),
    ('owner_mobile',    case when l.phone_type = 'mobile' then 0.9 end),
    ('multi_trade',     case when coalesce(array_length(l.categories, 1), 0) >= 3 then 0.7 end),
    ('ad_spend',        case when (l.extras->>'sponsored') in ('true','1') then 0.8 end),
    ('badge_holder',    case when (l.extras->>'guaranteed') in ('true','1') then 0.7 end),
    ('never_answers',   case when st.attempts_total >= 4 and st.connects_total = 0 then 0.9 end)
  ) v(k, c)
  where c is not null
  on conflict (lead_id, intent_key) do update set confidence = excluded.confidence, computed_at = now();
end $$;

-- --------------------------------------------------------------- next_lead --
-- Serves one lead and reserves it for the caller, so no other agent is served
-- the same lead until it is dialed, skipped, or the reservation lapses.
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

  -- an agent holds one lead at a time
  update lead_state set reserved_by = null, reserved_until = null where reserved_by = v_uid;

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

-- ---------------------------------------------------------------- skip_lead --
-- The agent passes on the lead in front of them without dialing it.
create or replace function public.skip_lead(p_lead_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_rest interval := make_interval(mins => coalesce((public.setting('skip_rest_minutes'))::int, 60));
  v_defer interval := make_interval(mins => coalesce((public.setting('callback_retry_minutes'))::int, 60));
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  perform 1 from lead_state
    where lead_id = p_lead_id and (reserved_by = v_uid or owner_agent = v_uid)
    for update;
  if found then
    -- a skipped callback comes back later rather than right away
    update callbacks set due_at = now() + v_defer
      where lead_id = p_lead_id and agent_id = v_uid and status = 'scheduled'
        and due_at <= now() + interval '10 minutes';

    -- a skipped list lead is done for that list
    update list_items li set served_at = now()
      from lists ld
      where li.list_id = ld.id and li.lead_id = p_lead_id and li.served_at is null
        and ld.status = 'active' and (ld.agent_id = v_uid or ld.agent_id is null);

    -- and it sits out a while, so the pool doesn't hand it straight back
    update lead_state set
        reserved_by = null,
        reserved_until = null,
        rest_until = case when state = 'callback_locked' then rest_until
                          else greatest(coalesce(rest_until, now()), now() + v_rest) end,
        updated_at = now()
      where lead_id = p_lead_id;
  end if;

  return jsonb_build_object('ok', true, 'next', next_lead());
end $$;

-- --------------------------------------------------------- log_disposition --
create or replace function public.log_disposition(p_attempt_id bigint, p_dispo text, p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  a attempts%rowtype;
  l leads%rowtype;
  cb callbacks%rowtype;
  v_has_cb boolean;
  v_connected boolean;
  v_rest interval;
  v_state text := 'queued';
  v_wb_status text;
  v_wb_note text;
  v_note text := nullif(p_args->>'note', '');
  v_due timestamptz;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into a from attempts where id = p_attempt_id for update;
  if not found then raise exception 'attempt not found'; end if;
  if a.agent_id <> v_uid and not is_manager() then raise exception 'not your attempt'; end if;

  -- Logged already (double key press, network retry): don't run the machine twice.
  -- A webhook auto-log is only a placeholder, so the agent's own key still counts.
  if a.disposed_at is not null and not a.auto_logged then
    return jsonb_build_object('ok', true, 'already_logged', true, 'next', next_lead());
  end if;

  select * into l from leads where id = a.lead_id;

  v_connected := p_dispo in ('wrong_number','gatekeeper_end','not_interested_soft','not_interested_hard',
                             'has_provider','dm_not_in','callback','email_requested','dnc',
                             'chance_website','sale_closed','language_barrier');

  -- the callback this call was keeping, if any
  select * into cb from callbacks
    where lead_id = a.lead_id and status = 'scheduled'
    order by due_at limit 1
    for update;
  v_has_cb := found;

  update attempts set
    disposition = p_dispo,
    connected = v_connected,
    auto_logged = false,
    voicemail_left = case when p_dispo = 'voicemail' then coalesce((p_args->>'left_message')::boolean, false) end,
    note = coalesce(v_note, note),
    disposed_at = now()
  where id = p_attempt_id;

  case p_dispo
    when 'not_interested_soft' then
      v_rest := make_interval(days => coalesce((public.setting('rest_soft_days'))::int, 10)); v_state := 'resting';
      v_wb_status := 'not_interested';
    when 'not_interested_hard' then
      v_rest := make_interval(days => coalesce((public.setting('rest_hard_days'))::int, 20)); v_state := 'resting';
      v_wb_status := 'not_interested';
    when 'language_barrier' then
      v_rest := interval '60 days'; v_state := 'resting'; v_wb_status := 'not_interested';
    when 'has_provider' then
      v_state := 'provider_list'; v_wb_status := 'long_term'; v_wb_note := 'has provider';
    when 'gatekeeper_end' then
      v_rest := interval '3 days'; v_state := 'queued';
    when 'dm_not_in' then
      v_rest := coalesce((p_args->>'retry_at')::timestamptz - now(), interval '1 day'); v_state := 'queued';
    when 'voicemail' then
      v_state := 'queued';
    when 'no_answer' then v_state := 'queued';
    when 'busy_failed' then v_state := 'queued';
    when 'skipped' then v_state := 'queued';
    when 'disconnected' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'disconnected', p_attempt_id) on conflict do nothing;
      v_wb_status := 'wrong_number'; v_wb_note := 'disconnected number';
    when 'wrong_number' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'wrong_number', p_attempt_id) on conflict do nothing;
      v_wb_status := 'wrong_number';
    when 'dnc' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'dnc', p_attempt_id) on conflict do nothing;
      v_wb_status := 'do_not_call'; v_wb_note := coalesce(v_note, 'asked not to be called');
    when 'callback' then
      -- due_local is the lead's wall-clock time ("call me at 2"), read in the lead's own timezone
      v_due := case when nullif(p_args->>'due_local', '') is not null
                    then (p_args->>'due_local')::timestamp at time zone coalesce(l.tz, 'America/New_York')
                    else (p_args->>'due_at')::timestamptz end;
      if v_due is null then raise exception 'callback needs a date and time'; end if;
      v_state := 'callback_locked'; v_wb_status := 'callback';
    when 'email_requested' then
      if p_args->>'email' is null then raise exception 'email_requested needs email'; end if;
      insert into email_queue (lead_id, email, flagged_by) values (a.lead_id, p_args->>'email', v_uid);
      update leads set email = p_args->>'email' where id = a.lead_id;
      v_rest := interval '3 days'; v_state := 'queued'; v_wb_status := 'long_term'; v_wb_note := 'asked for email';
    when 'chance_website' then
      insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
        values (a.lead_id, to_jsonb(l), 'chance_website', p_args->>'summary', (p_args->>'rating')::int, a.agent_id);
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'handoff_website', p_attempt_id) on conflict do nothing;
      v_state := 'handoff'; v_wb_status := 'captured'; v_wb_note := coalesce(p_args->>'summary', 'gave upfront - website');
    when 'sale_closed' then
      insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
        values (a.lead_id, to_jsonb(l), 'sale_closed', p_args->>'summary', (p_args->>'rating')::int, a.agent_id);
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'handoff_sale', p_attempt_id) on conflict do nothing;
      v_state := 'handoff'; v_wb_status := 'captured'; v_wb_note := coalesce(p_args->>'summary', 'sale closed - seo/receptionist');
    else
      raise exception 'unknown disposition %', p_dispo;
  end case;

  -- Close out the callback this call was keeping. Nobody picked up: keep the
  -- promise and try again later, up to callback_max_tries; then it is missed.
  if v_has_cb then
    if p_dispo in ('no_answer', 'voicemail', 'busy_failed', 'skipped')
       and cb.tries + 1 < coalesce((public.setting('callback_max_tries'))::int, 3) then
      update callbacks set tries = tries + 1,
          due_at = now() + make_interval(mins => coalesce((public.setting('callback_retry_minutes'))::int, 60))
        where id = cb.id;
      v_state := 'callback_locked'; v_rest := null;
    else
      update callbacks set tries = tries + 1,
          status = case when v_connected then 'done' else 'missed' end
        where id = cb.id;
    end if;
  end if;

  if p_dispo = 'callback' then
    insert into callbacks (lead_id, agent_id, due_at) values (a.lead_id, a.agent_id, v_due);
  end if;

  -- a dead or excluded number is dead for every lead record that carries it
  if v_state in ('suppressed', 'handoff') then
    update lead_state ls set state = 'suppressed', owner_agent = null, reserved_by = null,
        reserved_until = null, updated_at = now()
      from leads x
      where x.id = ls.lead_id and x.phone_norm = l.phone_norm and ls.lead_id <> a.lead_id
        and ls.state not in ('suppressed', 'handoff');
    update callbacks c set status = 'missed'
      from leads x
      where x.id = c.lead_id and x.phone_norm = l.phone_norm and c.status = 'scheduled';
  end if;

  update lead_state set
    state = v_state,
    owner_agent = case when v_state in ('callback_locked','in_progress') then a.agent_id else null end,
    rest_until = case when v_rest is not null then now() + v_rest else null end,
    connects_total = connects_total + case when v_connected then 1 else 0 end,
    in_progress_since = null,
    reserved_by = null,
    reserved_until = null,
    writeback_status = coalesce(v_wb_status, writeback_status),
    writeback_note = coalesce(v_wb_note, v_note, writeback_note),
    writeback_done = case when v_wb_status is null then writeback_done else false end,
    updated_at = now()
  where lead_id = a.lead_id;

  perform refresh_lead(a.lead_id);

  insert into agent_status (agent_id, status, lead_id, lead_name, phone_display, since, updated_at)
  values (v_uid, 'idle', null, null, null, now(), now())
  on conflict (agent_id) do update
    set status = 'idle', lead_id = null, lead_name = null, phone_display = null, since = now(), updated_at = now();

  return jsonb_build_object('ok', true, 'next', next_lead());
end $$;

-- ------------------------------------------------------------ release_lead --
-- Manager pushing a locked lead back to the general queue (A7).
create or replace function public.release_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  perform 1 from lead_state
    where lead_id = p_lead_id and (owner_agent = v_uid or reserved_by = v_uid or is_manager());
  if not found then raise exception 'not allowed'; end if;
  update callbacks set status = 'requeued', requeued_by = v_uid
    where lead_id = p_lead_id and status = 'scheduled' and is_manager();
  update lead_state set
      state = case when state in ('in_progress','callback_locked') then 'queued' else state end,
      owner_agent = case when state in ('in_progress','callback_locked') then null else owner_agent end,
      in_progress_since = case when state in ('in_progress','callback_locked') then null else in_progress_since end,
      reserved_by = null,
      reserved_until = null,
      updated_at = now()
    where lead_id = p_lead_id;
end $$;

-- --------------------------------------------------------------- heartbeat --
create or replace function public.heartbeat(p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_status not in ('idle','wrap','break','offline') then raise exception 'bad status'; end if;
  insert into agent_status (agent_id, status, since, updated_at)
  values (auth.uid(), p_status, now(), now())
  on conflict (agent_id) do update set status = excluded.status, since = now(), updated_at = now();
end $$;

-- -------------------------------------------------------------- build_list --
create or replace function public.build_list(p_name text, p_agent uuid, p_rules jsonb, p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_list bigint; v_count int;
begin
  if not is_manager() then raise exception 'manager only'; end if;
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

-- ------------------------------------------------------ bump_number_stats --
create or replace function public.bump_number_stats(p_number text, p_connect boolean)
returns void language sql security definer set search_path = public as $$
  insert into number_stats (number, stat_date, dials, connects)
  values (p_number, public.business_date(), 1, case when p_connect then 1 else 0 end)
  on conflict (number, stat_date) do update
    set dials = number_stats.dials + 1,
        connects = number_stats.connects + (case when p_connect then 1 else 0 end);
$$;

-- ------------------------------------------------------------------ boards --
-- "Today" is the business day (business_tz), not the UTC day.
create or replace view public.v_floor_today with (security_invoker = true) as
select
  p.id as agent_id, p.name, p.role,
  coalesce(s.status, 'offline') as status,
  s.lead_name, s.phone_display, s.since,
  count(a.id) as dials_today,
  count(a.id) filter (where a.connected) as connects_today,
  count(a.id) filter (where a.disposition in ('chance_website','sale_closed')) as handoffs_today,
  count(a.id) filter (where a.disposition = 'email_requested') as emails_today
from profiles p
left join agent_status s on s.agent_id = p.id
left join attempts a on a.agent_id = p.id and a.clicked_at >= public.business_day_start()
where p.active
group by p.id, p.name, p.role, s.status, s.lead_name, s.phone_display, s.since;

create or replace view public.v_number_health with (security_invoker = true) as
select number,
  sum(dials) filter (where stat_date >= public.business_date() - 6) as dials_7d,
  sum(connects) filter (where stat_date >= public.business_date() - 6) as connects_7d,
  round(100.0 * nullif(sum(connects) filter (where stat_date >= public.business_date() - 6), 0)
      / nullif(sum(dials) filter (where stat_date >= public.business_date() - 6), 0), 1) as rate_7d,
  round(100.0 * nullif(sum(connects) filter (where stat_date between public.business_date() - 13 and public.business_date() - 7), 0)
      / nullif(sum(dials) filter (where stat_date between public.business_date() - 13 and public.business_date() - 7), 0), 1) as rate_prev_7d
from number_stats
group by number;

create or replace view public.v_funnel with (security_invoker = true) as
select
  (a.clicked_at at time zone public.business_tz())::date as day,
  count(*) as dials,
  count(*) filter (where a.connected) as connects,
  count(*) filter (where a.disposition in ('not_interested_soft','not_interested_hard')) as rejections,
  count(*) filter (where a.disposition = 'callback') as callbacks,
  count(*) filter (where a.disposition = 'email_requested') as emails,
  count(*) filter (where a.disposition in ('chance_website','sale_closed')) as handoffs
from attempts a
group by 1;

-- -------------------------------------------------------------- API surface --
-- Supabase grants EXECUTE on every new function to anon; nothing here is for
-- callers who aren't signed in.
revoke execute on function public.next_lead() from public, anon;
revoke execute on function public.start_attempt(bigint) from public, anon;
revoke execute on function public.skip_lead(bigint) from public, anon;
revoke execute on function public.log_disposition(bigint, text, jsonb) from public, anon;
revoke execute on function public.release_lead(bigint) from public, anon;
revoke execute on function public.heartbeat(text) from public, anon;
revoke execute on function public.build_list(text, uuid, jsonb, int) from public, anon;
revoke execute on function public.is_manager() from public, anon;
grant execute on function
  public.next_lead(), public.start_attempt(bigint), public.skip_lead(bigint),
  public.log_disposition(bigint, text, jsonb), public.release_lead(bigint), public.heartbeat(text),
  public.build_list(text, uuid, jsonb, int), public.is_manager()
  to authenticated;

-- Internal: called by other functions, the sync worker or the webhook (service role).
revoke execute on function public.build_workspace(bigint, text) from public, anon, authenticated;
revoke execute on function public.refresh_lead(bigint) from public, anon, authenticated;
revoke execute on function public.bump_number_stats(text, boolean) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.refresh_lead(bigint), public.bump_number_stats(text, boolean) to service_role;
