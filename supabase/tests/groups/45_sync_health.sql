-- 0036: the sync shows its face (Wave 5). What eleven days of unattended running
-- asked for: numbers nobody should dial, a health card, three alerts, and the
-- policy tidy-up the advisors wanted.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '45.1 · A toll-free or invalid number is never dialed, and comes back the moment the console corrects it'
select t.reset() \g /dev/null
do $$
declare v_id bigint;
begin
  insert into leads (source_id, name, phone_norm, phone_display, addr_state, phone_type, score, review_count)
    values (901, 'Tollfree Co', '8005550199', '(800) 555-0199', 'FL', 'toll_free', 50, 5) returning id into v_id;
  perform refresh_lead(v_id);
  assert (select state from lead_state where lead_id = v_id) = 'suppressed', 'a toll-free number is suppressed';
  assert (select reason from suppression where phone_norm = '8005550199') = 'undialable', 'under its own reason';
  assert (select writeback_done and writeback_status is null from lead_state where lead_id = v_id),
    'and the console is told nothing: this is the floor''s own call';
  assert t.name(t.next('A')) <> 'Tollfree Co', 'the queue never serves it';
  -- the console corrects the number type: back in the queue, the row gone
  update leads set phone_type = 'mobile' where id = v_id;
  perform refresh_lead(v_id);
  assert (select state from lead_state where lead_id = v_id) = 'queued', 'corrected, it is callable again';
  assert not exists (select 1 from suppression where phone_norm = '8005550199'), 'and nothing keeps it out';
  -- an invalid number goes the same way, and a real exclusion still outranks it
  update leads set phone_type = 'invalid' where id = v_id;
  perform refresh_lead(v_id);
  assert (select state from lead_state where lead_id = v_id) = 'suppressed', 'invalid is suppressed too';
  insert into suppression (phone_norm, reason) values ('8005550199', 'dnc');
  update lead_state set state = 'queued' where lead_id = v_id;
  perform refresh_lead(v_id);
  assert (select writeback_status from lead_state where lead_id = v_id) = 'do_not_call',
    'a do-not-call on the same number still reaches the console';
  delete from lead_intents where lead_id = v_id;
  delete from lead_state where lead_id = v_id;
  delete from leads where id = v_id;
end $$;

\echo '45.2 · Number health ignores anything that is not a ten-digit number'
select t.reset() \g /dev/null
do $$
begin
  insert into number_stats (number, stat_date, dials, connects)
    values ('800', public.business_date(), 1, 1), ('2524012775', public.business_date(), 10, 9);
  assert (select count(*) from v_number_health) = 1 and (select number from v_number_health) = '2524012775',
    'only real seat numbers reach the board';
end $$;

\echo '45.3 · sync_health() tells a manager how the sync is doing, in one call; a request says what it can do'
select t.reset() \g /dev/null
truncate sync_runs restart identity;
do $$
declare h jsonb;
begin
  insert into sync_runs (kind, started_at, finished_at, ok, rows, detail) values
    ('pull_leads', now() - interval '20 minutes', now() - interval '19 minutes', true, 12, null),
    ('pull_leads', now() - interval '5 minutes', now() - interval '5 minutes', false, 0, 'ConsoleError: console me: non-JSON response (504)'),
    ('push_status', now() - interval '2 minutes', now() - interval '2 minutes', true, 3, 'Nothing is waiting to go to the lead console.'),
    ('pull_leads', now() - interval '1 minute', null, null, 0, null);
  perform t.as_user('M');
  h := public.sync_health();
  assert h ? 'pull' and h ? 'push' and h ? 'failures' and h ? 'runs' and h ? 'leads' and h ? 'outside_calls' and h ? 'cron',
    format('every pane in one call: %s', (select string_agg(k, ',') from jsonb_object_keys(h) k));
  assert (h->'pull'->'last_ok'->>'rows')::int = 12, 'the last good pull';
  assert (h->'pull'->>'failed_24h')::int = 1 and (h->'pull'->>'runs_24h')::int = 3, 'and the day''s count';
  assert (h->'pull'->>'running')::int = 1, 'a run inside its lease counts as running';
  assert jsonb_array_length(h->'failures') = 1 and h->'failures'->0->>'detail' like '%504%', 'the failure, with its text';
  assert jsonb_array_length(h->'runs') = 4, 'the recent runs';
  assert (h->'push'->'last'->>'rows')::int = 3, 'the last push';
  assert (h->'leads'->>'total')::int = (select count(*) from leads), 'the lead count';
  assert (h->'leads'->>'added_today')::int = (select count(*) from leads),
    'what arrived today (every seed lead was added by this run of the tests)';
  assert jsonb_typeof(h->'cron') in ('null', 'array'), 'the scheduler is read only where it exists';
  perform t.as_user('A');
  perform t.fails('select public.sync_health()', 'manager only');
  perform t.fails('select public.sync_request(''pull'')', 'manager only');
  perform t.as_user('M');
  perform t.fails('select public.sync_request(''dance'')', 'pull or push');
  assert (public.sync_request('pull')->>'ok') = 'false' and public.sync_request('push')->>'why' like '%no scheduler%',
    'without pg_net (this stub) a request says so instead of failing';
end $$;
truncate sync_runs restart identity;

\echo '45.4 · The Floor says when the sync or the console has gone quiet, and when calls were placed outside the dialer'
select t.reset() \g /dev/null
truncate sync_runs restart identity;
do $$
declare a jsonb;
begin
  perform t.as_user('M');
  a := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(a) x where x->>'kind' = 'sync'),
    'silence from a sync that never ran is not an outage';
  -- a good pull two hours ago, then a failure: an outage, told with the failure''s words
  insert into sync_runs (kind, started_at, finished_at, ok, rows)
    values ('pull_leads', now() - interval '2 hours', now() - interval '2 hours', true, 0);
  insert into sync_runs (kind, started_at, finished_at, ok, rows, detail)
    values ('pull_leads', now() - interval '30 minutes', now() - interval '30 minutes', false, 0, 'console me: 504 Gateway Time-out');
  a := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(a) x where x->>'kind' = 'sync' and x->>'detail' like '%504%'),
    format('the sync alert carries the failure: %s', a);
  -- a pull came through since: quiet again
  insert into sync_runs (kind, started_at, finished_at, ok, rows)
    values ('pull_leads', now() - interval '3 minutes', now() - interval '2 minutes', true, 0);
  a := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(a) x where x->>'kind' = 'sync'), 'a pull that came through clears it';
  -- the console: nothing new for four days
  assert not exists (select 1 from jsonb_array_elements(a) x where x->>'kind' = 'console'), 'leads that arrived today are not a quiet console';
  update leads set added_at = now() - interval '4 days';
  a := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(a) x where x->>'kind' = 'console' and x->>'detail' like '%4 days ago%'),
    format('four days without a lead is worth a look: %s', a);
  update leads set added_at = now();
  -- a call placed straight from Zoom today
  insert into webhook_events (event_id, event_type, payload) values ('t45-1', 'phone.caller_ended',
    '{"event":"phone.caller_ended","dial_floor_outcome":"no dial of ours matched this call; counted towards the number''s health"}');
  a := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(a) x where x->>'kind' = 'outside' and x->>'title' like '1 call placed outside%'),
    format('the outside call is on the board: %s', a);
  -- each has its own switch
  insert into app_settings (key, value) values ('alerts', '{"outside_calls": false, "sync_quiet_minutes": 0, "console_quiet_days": 0}')
    on conflict (key) do update set value = app_settings.value || excluded.value;
  update leads set added_at = now() - interval '4 days';
  a := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(a) x where x->>'kind' in ('outside', 'console', 'sync')),
    'switched off, none of the three says anything';
  update app_settings set value = value - 'outside_calls' - 'sync_quiet_minutes' - 'console_quiet_days' where key = 'alerts';
  -- an agent sees none of this
  perform t.as_user('A');
  a := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(a) x where x->>'kind' in ('outside', 'console', 'sync')),
    'manager lines stay with managers';
  update leads set added_at = now();
end $$;
-- floor_alerts() runs as whoever asks, so a manager's own session has to be able
-- to read the webhook's record of calls for the outside-calls line to count
set role authenticated;
do $$
begin
  perform t.as_user('M');
  assert exists (select 1 from jsonb_array_elements(public.floor_alerts()) x where x->>'kind' = 'outside'),
    'a manager session sees the outside call through the policy on webhook_events';
  perform t.as_user('A');
  assert (select count(*) from webhook_events) = 0, 'an agent reads none of the webhook''s record';
end $$;
reset role;
delete from webhook_events where event_id = 't45-1';
truncate sync_runs restart identity;

\echo '45.5 · After the policy tidy-up: agents still read what the Dial page needs, and only managers write it'
select t.reset() \g /dev/null
set role authenticated;
do $$
declare v_target numeric;
begin
  perform t.as_user('A');
  assert (select count(*) from kpi_targets where scope = 'agent_day') = 3, 'the targets still read';
  assert (select count(*) from battlecards where active) > 0, 'the cards still read';
  assert (select count(*) from app_settings) > 0, 'the settings still read';
  perform count(*) from email_templates;
  perform count(*) from ab_tests;
  assert (select count(*) from lists) = 0 and (select count(*) from list_items) = 0, 'lists stay the manager''s (0032)';
  select target into v_target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day';
  update kpi_targets set target = 1 where metric = 'dials_per_day' and scope = 'agent_day';
  assert (select target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day') = v_target,
    'an agent''s update changes nothing';
  perform t.fails('insert into app_settings (key, value) values (''t45'', ''1'')', 'row-level security');
  perform t.fails('insert into battlecards (objection) values (''t45'')', 'row-level security');
  perform t.as_user('M');
  update kpi_targets set target = target where metric = 'dials_per_day' and scope = 'agent_day';
  insert into app_settings (key, value) values ('t45', '1');
  update app_settings set value = '2' where key = 't45';
  delete from app_settings where key = 't45';
  assert not exists (select 1 from app_settings where key = 't45'), 'a manager writes, changes and removes';
end $$;
reset role;

\echo '45.6 · A lead remembers when it arrived here'
do $$
declare v_id bigint;
begin
  insert into leads (source_id, name, phone_norm, phone_display, addr_state, score, review_count)
    values (902, 'Arrived Today', '3055550902', '(305) 555-0902', 'FL', 1, 1) returning id into v_id;
  assert (select added_at from leads where id = v_id) between now() - interval '5 seconds' and now(),
    'added_at is set on arrival, not copied from the console';
  delete from leads where id = v_id;
end $$;
