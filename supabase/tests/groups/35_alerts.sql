-- 0024: the floor board's alerts. Three of these put the manager's own name on
-- their own board, or kept an alert up all evening after everyone had gone home;
-- the fourth hid the one alert that cannot afford to be hidden.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '35 · Item 8 · idle and behind pace are about agents; a manager who is really dialing is covered'
select t.reset() \g /dev/null
-- A worked the phones until 25 minutes ago and is sitting there with the app
-- open: 45 dials over an hour and a half, which is 30 an hour against 400 over
-- an 8-hour shift. M is the manager watching the board, and has dialed nothing.
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('X'), t.uid('A'), now() - interval '90 minutes' + make_interval(secs => (i - 1) * 86),
       false, 'no_answer', true
  from generate_series(1, 45) i;
insert into agent_status (agent_id, status, since, updated_at) values
  (t.uid('A'), 'idle', now() - interval '25 minutes', now()),
  (t.uid('M'), 'idle', now() - interval '25 minutes', now());
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'idle' and x->>'key' like 'idle:' || t.uid('A') || ':%'),
    format('the agent idle 25 minutes is still flagged: %s', al);
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('A') || ':%'),
    format('30 dials an hour against a target of 50 is behind pace: %s', al);
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'key' like '%' || t.uid('M') || '%'),
    format('the manager who has not dialed is on no list at all: %s', al);
end $$;
reset role;
-- the manager spends the same hour and a half on the phones
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('Y'), t.uid('M'), now() - interval '90 minutes' + make_interval(secs => (i - 1) * 86),
       false, 'no_answer', true
  from generate_series(1, 45) i;
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'idle' and x->>'key' like 'idle:' || t.uid('M') || ':%'),
    format('a manager with dials today is covered like anyone else: %s', al);
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('M') || ':%'),
    format('and is told when those dials are behind pace: %s', al);
end $$;
reset role;

\echo '35 · Item 9 · pace stops at the last sign of life; behind pace leaves the gone and the finished alone'
select t.reset() \g /dev/null
-- A dialed from three hours ago until two hours ago and the tile went quiet 90
-- minutes ago: an hour and a half of work, not the three hours now() would make it.
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('X'), t.uid('A'), now() - interval '3 hours' + make_interval(secs => (i - 1) * 80),
       false, 'no_answer', true
  from generate_series(1, 45) i;
insert into agent_status (agent_id, status, since, updated_at)
  values (t.uid('A'), 'idle', now() - interval '2 hours', now() - interval '90 minutes');
set role authenticated;
do $$
declare f record; al jsonb; p jsonb;
begin
  perform t.as_user('M');
  select * into f from public.floor_pace() where agent_id = t.uid('A');
  assert f.active_seconds between 5340 and 5460,
    format('the clock stopped at the last sign of life: %s seconds active', round(f.active_seconds));
  assert abs(f.dials_per_hour - 30) < 0.5, format('45 dials in an hour and a half is 30 an hour: %s', f.dials_per_hour);
  al := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(al) x
                      where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('A') || ':%'),
    format('a tile quiet for 90 minutes is someone gone, not someone behind: %s', al);
  perform t.as_user('A');
  p := public.my_pace();
  assert (p->>'active_minutes')::int between 89 and 91, format('the agent''s own strip agrees: %s', p);
  assert abs((p->>'dials_per_hour')::numeric - 30) < 0.5, format('and shows the same rate: %s', p);
end $$;
reset role;
-- the same agent, back at their desk: the alert is theirs again
update agent_status set updated_at = now() where agent_id = t.uid('A');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('A') || ':%'),
    format('present and behind pace is still an alert: %s', al);
end $$;
reset role;
-- A full day's number, dialed slowly: behind pace on the arithmetic, but the 300
-- dials are in. The shift is an hour here so the fixture does not need the eleven
-- hours it would otherwise take to be both past the target and behind pace.
select t.reset() \g /dev/null
update app_settings set value = '1' where key = 'shift_hours';
update kpi_targets set target = 300 where metric = 'dials_per_day' and scope = 'agent_day';
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('X'), t.uid('A'), now() - interval '90 minutes' + make_interval(secs => (i - 1) * 18),
       false, 'no_answer', true
  from generate_series(1, 300) i;
insert into agent_status (agent_id, status, since, updated_at)
  values (t.uid('A'), 'idle', now() - interval '1 minute', now());
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from public.floor_pace() f
                  where f.agent_id = t.uid('A') and f.dials = 300 and f.dials_per_hour * 1 < 0.8 * 300),
    'the fixture is behind pace on the arithmetic';
  assert not exists (select 1 from jsonb_array_elements(al) x
                      where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('A') || ':%'),
    format('300 of 300 dials is nobody''s idea of behind: %s', al);
end $$;
reset role;
update kpi_targets set target = 400 where metric = 'dials_per_day' and scope = 'agent_day';
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('A') || ':%'),
    format('with 100 dials still to go it is an alert again: %s', al);
end $$;
reset role;
update app_settings set value = '8' where key = 'shift_hours';

\echo '35 · Item 10 · a number nobody answers at all is what the spam alert is for; two dials a week are not a collapse'
select t.reset() \g /dev/null
insert into number_stats (number, stat_date, dials, connects) values
  ('3055557777', business_date() - 1, 80, 0),    -- carrier-flagged: 80 dials, not one pickup
  ('3055558888', business_date() - 9, 4, 1),     -- a number hardly used at all
  ('3055558888', business_date() - 1, 5, 0),
  ('3055559999', business_date() - 9, 100, 25),  -- a real collapse, on weeks worth comparing
  ('3055559999', business_date() - 1, 100, 5);
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  assert (select rate_7d from v_number_health where number = '3055557777') = 0.0,
    format('no pickups is a rate of 0, not no rate: %s', (select rate_7d from v_number_health where number = '3055557777'));
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'spam' and x->>'number' = '3055557777'),
    format('80 dials and no answers raises the spam alert: %s', al);
  assert not exists (select 1 from jsonb_array_elements(al) x
                      where x->>'kind' = 'spam' and x->>'number' = '3055558888'),
    format('four dials last week against five this week is noise: %s', al);
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'spam' and x->>'number' = '3055559999'),
    format('25%% down to 5%% on a hundred dials each week still counts: %s', al);
end $$;
reset role;

\echo '35 · Item 11 · a call still open shows up even when the browser that made it is gone'
select t.reset() \g /dev/null
-- A dialed 20 minutes ago and nothing was ever logged. There is no tile at all:
-- the browser died and took the heartbeat with it.
insert into attempts (lead_id, agent_id, clicked_at, matched)
  values (t.lead('X'), t.uid('A'), now() - interval '20 minutes', false);
set role authenticated;
do $$
declare al jsonb; att bigint := (select id from attempts);
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert jsonb_array_length(al) = 1 and al->0->>'kind' = 'long_call', format('the open call is the one alert: %s', al);
  assert al->0->>'key' = 'long:' || t.uid('A') || ':' || att, format('keyed to the attempt: %s', al->0);
  assert al->0->>'detail' like 'X: %', format('and says which lead: %s', al->0);
  assert public.floor_alerts()->0->>'key' = al->0->>'key', 'the key does not move between looks';
end $$;
reset role;
-- the tile the dead browser left behind, half an hour stale: it used to clear the alert
insert into agent_status (agent_id, status, lead_name, since, updated_at)
  values (t.uid('A'), 'dialing', 'X', now() - interval '20 minutes', now() - interval '30 minutes');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'long_call' and x->>'key' like 'long:' || t.uid('A') || ':%'),
    format('a stale heartbeat no longer hides the open call: %s', al);
end $$;
reset role;
-- Zoom's webhook writes its placeholder: the call is over, so it is not a long
-- call any more, and a call that only just started is not one yet either.
update attempts set disposition = 'no_answer', auto_logged = true, disposed_at = now();
insert into attempts (lead_id, agent_id, clicked_at, matched)
  values (t.lead('Y'), t.uid('A'), now() - interval '5 minutes', false);
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call'),
    format('a call Zoom says ended, and a call five minutes old, raise nothing: %s', al);
end $$;
reset role;
select t.reset() \g /dev/null
\echo 'alerts tests passed'
