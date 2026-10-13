-- Dial Floor · 0036 the sync shows its face (Wave 5)
-- What eleven days of unattended running asked for, reproduced in
-- supabase/tests/groups/45_sync_health.sql:
--   · a manager can see the lead sync without the SQL editor: sync_health() feeds
--     a card on the Settings page, and the Floor raises three new alerts — the
--     sync has gone quiet, the console has gone quiet, and calls placed outside
--     the dialer today (the floor cannot see their outcomes).
--   · a manager can ask for a pull or a push now: sync_request() makes the same
--     request the cron jobs make.
--   · a lead remembers when it arrived here (added_at). first_seen is the
--     console's clock, which says when the business was scraped, not when the
--     floor got it.
--   · number health ignores anything that is not a ten-digit number.
--   · the advisors: four foreign keys get their index.
--   · HAND-APPLY (bottom): toll-free and invalid numbers are never dialed, two
--     duplicate indexes go, and seven doubled policies become one per action.

-- -------------------------------------------------------------- when it arrived --
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'leads' and column_name = 'added_at') then
    alter table public.leads add column added_at timestamptz not null default now();
    -- the rows already here arrived before the column did: the console's own
    -- clock is the closest thing to the truth for them
    update public.leads set added_at = coalesce(first_seen, synced_at, now());
  end if;
end $$;
create index if not exists leads_added_at_idx on public.leads (added_at);
create index if not exists webhook_events_received_idx on public.webhook_events (received_at);

-- --------------------------------------------------------------- number health --
-- A caller number that is not ten digits is not one of our seats: the webhook once
-- counted a call whose number parsed down to "800". Such rows stay in number_stats
-- and never reach the board.
create or replace view public.v_number_health with (security_invoker = true) as
select number,
       sum(dials) filter (where stat_date >= business_date() - 6) as dials_7d,
       sum(connects) filter (where stat_date >= business_date() - 6) as connects_7d,
       round(100.0 * sum(connects) filter (where stat_date >= business_date() - 6)::numeric
             / nullif(sum(dials) filter (where stat_date >= business_date() - 6), 0)::numeric, 1) as rate_7d,
       round(100.0 * sum(connects) filter (where stat_date >= business_date() - 13 and stat_date <= business_date() - 7)::numeric
             / nullif(sum(dials) filter (where stat_date >= business_date() - 13 and stat_date <= business_date() - 7), 0)::numeric, 1) as rate_prev_7d,
       sum(dials) filter (where stat_date >= business_date() - 13 and stat_date <= business_date() - 7) as dials_prev_7d
  from number_stats
 where length(number) = 10
 group by number;

-- ------------------------------------------------------------------- FK indexes --
create index if not exists agent_status_lead_idx on public.agent_status (lead_id);
create index if not exists attempts_ab_test_idx on public.attempts (ab_test_id);
create index if not exists lead_intents_key_idx on public.lead_intents (intent_key);
create index if not exists radar_items_agent_idx on public.radar_items (agent_id);

-- ------------------------------------------------------------------ sync health --
-- Everything the Settings page's sync card shows, in one call. The scheduler's
-- tables exist only on the hosted database, so that part is read by name and is
-- null anywhere else (the local test stub, a PC-loop-only setup).
create or replace function public.sync_health()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_day_start timestamptz := public.business_day_start();
  v_cron jsonb := null;
  -- an edge instance cannot outlive its 150 s clock, so a run still open after
  -- this long is not running any more (sync-console marks it failed)
  v_lease interval := interval '3 minutes';
  v_unmatched text := 'no dial of ours matched%';
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  if to_regclass('cron.job') is not null then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('name', j.jobname, 'schedule', j.schedule, 'active', j.active,
               'last_run', d.start_time, 'last_status', d.status) order by j.jobid), '[]'::jsonb)
        from cron.job j
        left join lateral (select r.status, r.start_time from cron.job_run_details r
                            where r.jobid = j.jobid order by r.start_time desc limit 1) d on true
       where j.jobname like 'dial-floor%' $q$ into v_cron;
  end if;
  return jsonb_build_object(
    'now', now(),
    'pull', jsonb_build_object(
      'last_ok', (select jsonb_build_object('at', started_at, 'rows', rows,
                           'secs', round(extract(epoch from finished_at - started_at)), 'detail', detail)
                    from sync_runs where kind = 'pull_leads' and ok order by id desc limit 1),
      'last', (select jsonb_build_object('at', started_at, 'ok', ok, 'rows', rows, 'finished', finished_at is not null,
                        'secs', round(extract(epoch from coalesce(finished_at, now()) - started_at)), 'detail', detail)
                 from sync_runs where kind = 'pull_leads' order by id desc limit 1),
      'runs_24h', (select count(*) from sync_runs where kind = 'pull_leads' and started_at > now() - interval '24 hours'),
      'failed_24h', (select count(*) from sync_runs where kind = 'pull_leads' and ok = false
                        and started_at > now() - interval '24 hours'),
      'running', (select count(*) from sync_runs where finished_at is null and started_at > now() - v_lease)),
    'push', jsonb_build_object(
      'last', (select jsonb_build_object('at', started_at, 'ok', ok, 'rows', rows, 'detail', detail)
                 from sync_runs where kind = 'push_status' order by id desc limit 1),
      'waiting', (select count(*) from lead_state where writeback_done = false and writeback_status is not null),
      'oldest_waiting', (select min(updated_at) from lead_state where writeback_done = false and writeback_status is not null)),
    'failures', (select coalesce(jsonb_agg(jsonb_build_object('at', started_at, 'kind', kind, 'detail', left(detail, 300))
                                           order by id desc), '[]'::jsonb)
                   from (select * from sync_runs where ok = false and started_at > now() - interval '7 days'
                          order by id desc limit 5) f),
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'at', started_at, 'ok', ok, 'rows', rows,
                      'secs', case when finished_at is null then null else round(extract(epoch from finished_at - started_at)) end,
                      'detail', left(detail, 200)) order by id desc), '[]'::jsonb)
               from (select * from sync_runs order by id desc limit 15) r),
    'leads', jsonb_build_object(
      'total', (select count(*) from leads),
      'added_today', (select count(*) from leads where added_at >= v_day_start),
      'added_7d', (select count(*) from leads where added_at > now() - interval '7 days'),
      'last_added', (select max(added_at) from leads),
      'last_changed', (select max(synced_at) from leads),
      'queued', (select count(*) from lead_state where state = 'queued'),
      'undialable', (select count(*) from suppression where reason = 'undialable')),
    'outside_calls', jsonb_build_object(
      'today', (select count(*) from webhook_events
                 where received_at >= v_day_start and payload->>'dial_floor_outcome' like v_unmatched),
      'week', (select count(*) from webhook_events
                where received_at > now() - interval '7 days' and payload->>'dial_floor_outcome' like v_unmatched)),
    'cron', v_cron);
end $$;

-- A pull or a push, now. The same request the cron jobs make (0034), so it
-- arrives at the function with the same secret and goes through the same
-- one-at-a-time guard; the run shows up in sync_health() within the minute.
-- pg_net returns straight away, so the answer here is "asked", not "done".
create or replace function public.sync_request(p_task text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_req bigint;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  if p_task not in ('pull', 'push') then raise exception 'the task is pull or push'; end if;
  begin
    execute format($q$
      select net.http_post(
        url := 'https://fevjrcxmktjwbaozbngo.supabase.co/functions/v1/sync-console',
        headers := jsonb_build_object('content-type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_cron_secret')),
        body := %L::jsonb,
        timeout_milliseconds := 150000) $q$, jsonb_build_object('task', p_task)::text)
      into v_req;
  exception when undefined_function or undefined_table or invalid_schema_name or insufficient_privilege then
    -- not the hosted database: here the sync runs from the PC loop, on its own clocks
    return jsonb_build_object('ok', false, 'why', 'no scheduler on this database — the sync runs from the PC loop here');
  end;
  return jsonb_build_object('ok', true, 'task', p_task, 'request_id', v_req);
end $$;

revoke execute on function public.sync_health(), public.sync_request(text) from public, anon;
grant execute on function public.sync_health(), public.sync_request(text) to authenticated;

-- ------------------------------------------------------------------ the alerts --
-- 0033's floor_alerts with three more lines for managers, each with its own
-- switch in the alerts setting: sync_quiet_minutes (45), console_quiet_days (3),
-- outside_calls (on).
create or replace function public.floor_alerts()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  cfg jsonb := coalesce(public.setting('alerts'), '{}'::jsonb);
  v_idle int := coalesce((cfg->>'idle_minutes')::int, 10);
  v_long int := coalesce((cfg->>'long_call_minutes')::int, 15);
  v_pace numeric := coalesce((cfg->>'pace_pct')::numeric, 80);
  v_cb int := coalesce((cfg->>'callback_overdue_minutes')::int, 15);
  v_target numeric := (select target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day');
  v_shift numeric := greatest(1, least(coalesce((public.setting('shift_hours'))::numeric, 8), 16));
  v_drop numeric := coalesce((public.setting('spam_alert_drop_pts'))::numeric, 10);
  -- dials a week before the two weeks are worth comparing at all
  v_sample int := 30;
  -- Dials that count as a manager working the phones. The complaint this came
  -- from was a manager who made one test dial being told on their own board that
  -- they were idle 14 minutes and behind pace, so "has dialed today" is not the
  -- line: one dial is poking at the thing, a morning of them is working it.
  v_mgr_dials int := 10;
  v_tz text := public.business_tz();
  -- Wave 5: the sync pulls every quarter hour, so three quarters of an hour of
  -- silence is a pull that did not happen; the console scrapes most days, so
  -- three days without a new lead is worth a look; and a call the floor cannot
  -- see is worth knowing about the day it happens
  v_sync_quiet int := coalesce((cfg->>'sync_quiet_minutes')::int, 45);
  v_console_quiet int := coalesce((cfg->>'console_quiet_days')::int, 3);
  v_last_pull timestamptz;
  v_last_added timestamptz;
  v_outside int;
  r jsonb := '[]';
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  -- wins ring the bell for everyone
  if coalesce((cfg->>'celebrate')::boolean, true) then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'win:' || a.id, 'kind', 'win', 'level', 'good', 'agent', p.name, 'at', a.disposed_at,
               'title', p.name || case when a.disposition = 'sale_closed' then ' closed a sale'
                                       else ' got the chance to build a website' end,
               'detail', l.name) order by a.disposed_at desc)
        from attempts a join profiles p on p.id = a.agent_id join leads l on l.id = a.lead_id
       where a.clicked_at >= now() - interval '1 day' and a.disposed_at >= now() - interval '60 minutes'
         and a.disposition in ('chance_website', 'sale_closed')), '[]'::jsonb);
  end if;
  if not is_manager() then return r; end if;

  r := r || coalesce((
    select jsonb_agg(x order by x->>'at') from (
      -- Idle: a live tile, up and quiet. A manager only counts here once they
      -- have really worked the phones today; otherwise the manager watching the
      -- board was told they were the one standing around.
      select jsonb_build_object(
               'key', 'idle:' || s.agent_id || ':' || extract(epoch from s.since)::bigint,
               'kind', 'idle', 'level', 'warn', 'agent', p.name, 'at', s.since,
               'title', p.name || ' idle ' || floor(extract(epoch from now() - s.since) / 60) || ' min',
               'detail', 'no dial since ' || to_char(s.since at time zone v_tz, 'FMHH12:MI AM')) as x
        from agent_status s join profiles p on p.id = s.agent_id
       where v_idle > 0 and p.active and s.updated_at >= now() - interval '5 minutes'
         and s.status in ('idle', 'wrap') and s.since < now() - make_interval(mins => v_idle)
         and (p.role = 'agent' or (select count(*) from attempts d
                                    where d.agent_id = p.id
                                      and d.clicked_at >= public.business_day_start()) >= v_mgr_dials)
      union all
      -- The long call is the open attempt itself, not the heartbeat: a browser
      -- that died mid-call used to clear this alert after five quiet minutes,
      -- which is exactly when somebody should be walking over, and the outcome of
      -- that call was never going to be logged by itself. "Open" is said here
      -- the same way next_lead says it when it hands an agent back a call they
      -- started and never logged: no outcome on the attempt, or only the
      -- placeholder the webhook writes when Zoom says the call ended, with the
      -- lead still in progress under that agent and the call still inside the
      -- reclaim window. Saying it the same way is the point — every call the
      -- queue still wants an outcome for is on the board and nothing else is. So
      -- a lead a manager has released, and one the queue has already finished and
      -- handed on, stop being that agent's call and stop raising an alert,
      -- instead of sitting on the board with the minutes climbing and no way for
      -- anyone to clear them. Whoever has a call open is dialing, manager or not,
      -- so there is nothing to filter.
      select jsonb_build_object(
               'key', 'long:' || a.agent_id || ':' || a.id,
               'kind', 'long_call', 'level', 'warn', 'agent', p.name, 'at', a.clicked_at,
               'title', p.name || ' on one call ' || floor(extract(epoch from now() - a.clicked_at) / 60) || ' min',
               'detail', l.name || ': still talking, or the browser closed before the outcome was logged')
        from attempts a join profiles p on p.id = a.agent_id join leads l on l.id = a.lead_id
       -- "Open" has to mean the same thing here as it does in next_lead, which hands a
       -- call back to its agent while the outcome is still only Zoom's placeholder.
       -- If the board read it any other way a call would fall between the two.
       where v_long > 0 and p.active and (a.disposition is null or a.auto_logged)
         and exists (select 1 from lead_state ls
                      where ls.lead_id = a.lead_id and ls.state = 'in_progress'
                        and ls.owner_agent = a.agent_id)
         -- No upper bound on age. Tying this to the window the queue waits before
         -- calling a call abandoned is what hid the case the alert exists for: a real
         -- conversation outlives it, and so does a browser that died. The day is not
         -- the bound either — a call open across the rollover is exactly when a dead
         -- tab is least likely to be noticed. A day's grace only stops a call nobody
         -- ever resolved from nagging for ever; by then the lead needs a manager.
         and a.clicked_at > now() - interval '24 hours'
         and a.clicked_at < now() - make_interval(mins => v_long)) q), '[]'::jsonb);

  if v_pace > 0 and v_target > 0 then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'pace:' || f.agent_id || ':' || public.business_date(),
               'kind', 'pace', 'level', 'warn', 'agent', p.name, 'at', f.first_dial,
               'title', p.name || ' behind pace',
               'detail', round(f.dials_per_hour) || ' dials an hour, on pace for ' || round(f.dials_per_hour * v_shift)
                         || ' of ' || round(v_target) || ' (that takes ' || ceil(v_target / v_shift) || ' an hour)'))
        from public.floor_pace() f
        join profiles p on p.id = f.agent_id
        join agent_status s on s.agent_id = f.agent_id
       where f.active_seconds >= 3600 and not f.on_break and f.dials_per_hour is not null
         and f.dials_per_hour * v_shift < v_pace / 100 * v_target
         -- somebody who has already made the day's number is not behind anything
         and f.dials < v_target
         -- and somebody whose tile has gone quiet has gone home: nothing to chase
         and s.status <> 'offline' and s.updated_at >= now() - interval '5 minutes'
         and (p.role = 'agent' or f.dials >= v_mgr_dials)), '[]'::jsonb);
  end if;

  if v_cb > 0 then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'callback:' || c.id || ':' || extract(epoch from c.due_at)::bigint,
               'kind', 'callback', 'level', 'warn', 'agent', p.name, 'at', c.due_at,
               'title', 'Callback overdue: ' || l.name,
               -- item 45: the promise was made on the lead's clock, so that is the
               -- clock this line reads
               'detail', p.name || '''s callback, due ' ||
                         to_char(c.due_at at time zone coalesce(l.tz, 'America/New_York'), 'FMHH12:MI AM Dy')
                         || ' their time') order by c.due_at)
        from callbacks c join profiles p on p.id = c.agent_id join leads l on l.id = c.lead_id
       where c.status = 'scheduled' and c.due_at < now() - make_interval(mins => v_cb)), '[]'::jsonb);
  end if;

  if coalesce((cfg->>'spam')::boolean, true) then
    -- The drop rule holds two weeks up against each other, so both weeks need
    -- enough dials to be saying anything: four dials last week against five this
    -- week is noise, not a number going bad. The absolute rule below it already
    -- carries its own floor of 60 dials.
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'spam:' || n.number || ':' || public.business_date(),
               'kind', 'spam', 'level', 'warn', 'agent', null, 'number', n.number, 'at', now(),
               'title', 'Possible spam label',
               'detail', 'connect rate ' || coalesce(n.rate_prev_7d || '% → ', '') || n.rate_7d
                         || '% over the last 7 days: swap the number in Zoom'))
        from v_number_health n
       where n.rate_7d is not null
         and ((n.rate_prev_7d is not null and n.rate_prev_7d - n.rate_7d >= v_drop
               and coalesce(n.dials_7d, 0) >= v_sample and coalesce(n.dials_prev_7d, 0) >= v_sample)
              or (coalesce(n.dials_7d, 0) >= 60 and n.rate_7d < 8))), '[]'::jsonb);
  end if;

  -- The sync has gone quiet. Only once it has been running at all this week:
  -- a floor fed by the PC loop on somebody's desk, or a brand-new database, is
  -- not a sync that stopped. Keyed on the last good pull, so the alert is one
  -- notification per outage rather than one per board refresh.
  select max(started_at) into v_last_pull from sync_runs where kind = 'pull_leads' and ok;
  if v_sync_quiet > 0 and v_last_pull > now() - interval '7 days'
     and v_last_pull < now() - make_interval(mins => v_sync_quiet) then
    r := r || jsonb_build_array(jsonb_build_object(
      'key', 'sync:' || extract(epoch from v_last_pull)::bigint,
      'kind', 'sync', 'level', 'warn', 'agent', null, 'at', v_last_pull,
      'title', 'Lead sync has gone quiet',
      'detail', 'last good pull ' || to_char(v_last_pull at time zone v_tz, 'FMHH12:MI AM Dy')
                || coalesce((select ' — latest run failed: ' || left(s.detail, 140) from sync_runs s
                              where s.ok = false and s.started_at > v_last_pull order by s.id desc limit 1),
                            ' — no pull has run since')));
  end if;

  -- The console has gone quiet: nothing new has arrived for days. The scraper
  -- feeds the floor most days, so this usually means it stopped. Keyed on the
  -- day, so it says so once a morning until something arrives.
  select max(added_at) into v_last_added from leads;
  if v_console_quiet > 0 and v_last_added < now() - make_interval(days => v_console_quiet) then
    r := r || jsonb_build_array(jsonb_build_object(
      'key', 'console:' || public.business_date(),
      'kind', 'console', 'level', 'warn', 'agent', null, 'at', v_last_added,
      'title', 'No new leads from the console',
      'detail', 'the last one arrived ' || to_char(v_last_added at time zone v_tz, 'FMMon FMDD')
                || ' (' || floor(extract(epoch from now() - v_last_added) / 86400) || ' days ago) — the scraper may have stopped'));
  end if;

  -- Calls placed outside the dialer today. The webhook sees every outbound call
  -- from our seats; one that no dial matched was started straight from Zoom, so
  -- no lead, outcome or note was recorded for it.
  if coalesce((cfg->>'outside_calls')::boolean, true) then
    select count(*) into v_outside from webhook_events
     where received_at >= public.business_day_start()
       and payload->>'dial_floor_outcome' like 'no dial of ours matched%';
    if v_outside > 0 then
      r := r || jsonb_build_array(jsonb_build_object(
        'key', 'outside:' || public.business_date(),
        'kind', 'outside', 'level', 'warn', 'agent', null, 'at', now(),
        'title', v_outside || ' call' || case when v_outside = 1 then '' else 's' end || ' placed outside the dialer today',
        'detail', 'dialed straight from Zoom, so no lead, outcome or note was recorded — the floor only counts calls started from the Dial page'));
    end if;
  end if;
  return r;
end $$;

-- ====================================================================================
-- HAND-APPLY AT LIVE TIME: everything below carries a drop or a delete, which the
-- management API's confirmation scanner stalls on (see 0022). Dashboard SQL
-- editor, in this order. The local test stub runs it like any other migration.
-- ====================================================================================

-- ------------------------------------------------------ numbers nobody should dial --
-- A toll-free number reaches a call centre, not an owner, and "invalid" is what
-- the console's own validator says. Such a lead lives on the suppression list as
-- 'undialable' — so every record sharing the number stays out of every queue and
-- every list — and comes straight off it when the console corrects the number:
-- that row is the only thing keeping the lead out. The console is told nothing;
-- this is the floor's own choice.
alter table public.suppression drop constraint suppression_reason_check;
alter table public.suppression add constraint suppression_reason_check
  check (reason in ('dnc', 'handoff_website', 'handoff_sale', 'disconnected', 'wrong_number', 'undialable'));

create or replace function public.refresh_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  l leads%rowtype;
  st lead_state%rowtype;
  v_reason text;
  v_wb_status text;
  v_wb_note text;
begin
  select * into l from leads where id = p_lead_id;
  if not found then return; end if;

  update leads set tz = derive_tz(l.phone_norm, l.addr_state) where id = l.id;

  insert into lead_state (lead_id, state)
  values (l.id, 'queued')
  on conflict (lead_id) do nothing;
  select * into st from lead_state where lead_id = l.id;

  -- Wave 5: a number nobody on a sales floor should dial. On the list while the
  -- console says so, off it the moment the console says otherwise.
  if l.phone_type in ('toll_free', 'invalid') then
    insert into suppression (phone_norm, place_id, reason) values (l.phone_norm, l.place_id, 'undialable')
    on conflict do nothing;
  else
    delete from suppression where phone_norm = l.phone_norm and reason = 'undialable';
  end if;

  -- suppression wins over everything, forever (a handoff keeps its own state)
  if exists (select 1 from suppression s where s.phone_norm = l.phone_norm) then
    -- A number can be on the list for more than one reason; the console hears the
    -- most final one. This is the path a freshly synced twin of an excluded number
    -- takes, so it is also where that twin is queued for write-back — only on the
    -- way into suppressed, so a lead already excluded is not pushed again and again.
    -- 'undialable' is the floor's own call, so the console is told nothing of it.
    select s.reason into v_reason from suppression s
      where s.phone_norm = l.phone_norm
      order by case s.reason when 'dnc' then 1 when 'handoff_sale' then 2 when 'handoff_website' then 3
                             when 'wrong_number' then 4 when 'disconnected' then 5 else 6 end
      limit 1;
    v_wb_status := case v_reason when 'dnc' then 'do_not_call'
                                when 'handoff_sale' then 'captured'
                                when 'handoff_website' then 'captured'
                                when 'undialable' then null
                                else 'wrong_number' end;
    v_wb_note := case v_reason when 'dnc' then 'asked not to be called'
                               when 'disconnected' then 'disconnected number'
                               when 'wrong_number' then 'wrong number'
                               when 'undialable' then 'a number nobody can dial (toll-free or invalid)'
                               else 'already handed off' end;
    update lead_state set state = 'suppressed', owner_agent = null, reserved_by = null,
        reserved_until = null, writeback_status = v_wb_status,
        writeback_note = v_wb_note, writeback_done = (v_wb_status is null),
        updated_at = now()
      where lead_id = l.id and state not in ('suppressed', 'handoff');
    update callbacks set status = 'cancelled' where lead_id = l.id and status = 'scheduled';
    return;
  end if;

  -- 22: suppressed, but nothing on the list matches this number any more — the
  -- console fixed the number (or a manager cleared the entry), so the business
  -- is callable again. Back to the queue, rest and counters as they were; the
  -- console is not written to, since the console is where the change came from —
  -- and a write-back still waiting from the old number is dropped for the same
  -- reason: pushing "wrong number" at a record whose number was just fixed would
  -- kill the fix. A handoff is not a suppression: sold stays sold whatever the
  -- number does.
  if st.state = 'suppressed' then
    update lead_state set state = 'queued', owner_agent = null, reserved_by = null,
        reserved_until = null, writeback_status = null, writeback_note = null,
        writeback_done = true, updated_at = now()
      where lead_id = l.id and state = 'suppressed';
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
    -- C4: no pickup on N+ tries during their own business hours, and never a live conversation
    ('never_answers',   case when st.connects_total = 0
                              and (select count(*) from missed_tries(l.id))
                                  >= coalesce((public.setting('missed_call_threshold'))::int, 4) then 0.9 end)
  ) v(k, c)
  where c is not null
  on conflict (lead_id, intent_key) do update set confidence = excluded.confidence, computed_at = now();
end $$;

-- the leads already here with such numbers
do $$ begin perform public.refresh_lead(id) from leads where phone_type in ('toll_free', 'invalid'); end $$;

-- ------------------------------------------------------------- duplicate indexes --
-- 0033 added these beside two that already existed under other names.
drop index if exists public.handoff_lead_idx;
drop index if exists public.handoff_agent_idx;

-- ------------------------------------------------------------- doubled policies --
-- Each of these tables had a read policy and a manager "for all" policy, so every
-- select ran both. Lists read manager-only since 0032, so there the manager
-- policy is the only one needed; elsewhere the manager policy becomes one per
-- write action and the read policy stands alone.
drop policy if exists lists_read on public.lists;
drop policy if exists list_items_read on public.list_items;

drop policy if exists ab_manager on public.ab_tests;
create policy ab_manage_insert on public.ab_tests for insert to authenticated with check (public.is_manager());
create policy ab_manage_update on public.ab_tests for update to authenticated using (public.is_manager()) with check (public.is_manager());
create policy ab_manage_delete on public.ab_tests for delete to authenticated using (public.is_manager());

drop policy if exists settings_manager on public.app_settings;
create policy settings_manage_insert on public.app_settings for insert to authenticated with check (public.is_manager());
create policy settings_manage_update on public.app_settings for update to authenticated using (public.is_manager()) with check (public.is_manager());
create policy settings_manage_delete on public.app_settings for delete to authenticated using (public.is_manager());

drop policy if exists battlecards_manager on public.battlecards;
create policy battlecards_manage_insert on public.battlecards for insert to authenticated with check (public.is_manager());
create policy battlecards_manage_update on public.battlecards for update to authenticated using (public.is_manager()) with check (public.is_manager());
create policy battlecards_manage_delete on public.battlecards for delete to authenticated using (public.is_manager());

drop policy if exists email_templates_manager on public.email_templates;
create policy email_templates_manage_insert on public.email_templates for insert to authenticated with check (public.is_manager());
create policy email_templates_manage_update on public.email_templates for update to authenticated using (public.is_manager()) with check (public.is_manager());
create policy email_templates_manage_delete on public.email_templates for delete to authenticated using (public.is_manager());

drop policy if exists kpi_manager on public.kpi_targets;
create policy kpi_manage_insert on public.kpi_targets for insert to authenticated with check (public.is_manager());
create policy kpi_manage_update on public.kpi_targets for update to authenticated using (public.is_manager()) with check (public.is_manager());
create policy kpi_manage_delete on public.kpi_targets for delete to authenticated using (public.is_manager());
