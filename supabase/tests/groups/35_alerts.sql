-- 0024: the floor board's alerts. Three of these put the manager's own name on
-- their own board, or kept an alert up all evening after everyone had gone home;
-- the fourth hid the one alert that cannot afford to be hidden.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '35 · Item 8 · idle and behind pace are about the people working the phones; one test dial is not working them'
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
    format('a manager with a morning of dials behind them is covered like anyone else: %s', al);
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('M') || ':%'),
    format('and is told when those dials are behind pace: %s', al);
end $$;
reset role;
-- The complaint this item came from, to the letter: a manager who made one test
-- dial that morning, app open, tile quiet for 14 minutes, read on their own board
-- that they were idle 14 min and behind pace. "Has dialed today" was never the
-- line that fixes it, because one test dial passes it.
select t.reset() \g /dev/null
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
  values (t.lead('X'), t.uid('M'), now() - interval '2 hours', false, 'no_answer', true);
insert into agent_status (agent_id, status, since, updated_at)
  values (t.uid('M'), 'idle', now() - interval '14 minutes', now());
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  assert exists (select 1 from public.floor_pace() f
                  where f.agent_id = t.uid('M') and f.active_seconds >= 3600
                    and f.dials_per_hour is not null and f.dials_per_hour * 8 < 0.8 * 400),
    'the one test dial is two hours back and behind pace on the arithmetic, so only the dial count can keep it off the board';
  al := public.floor_alerts();
  assert jsonb_array_length(al) = 0,
    format('one test dial puts nothing on the manager''s own board: %s', al);
end $$;
reset role;
-- eight more: still a manager poking at the thing, not a manager on the phones
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('X'), t.uid('M'), now() - interval '2 hours' + make_interval(secs => i * 30),
       false, 'no_answer', true
  from generate_series(1, 8) i;
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert jsonb_array_length(al) = 0, format('nine dials is not working the phones either: %s', al);
end $$;
reset role;
-- the tenth makes it a morning's work, and both alerts are the manager's again
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
  values (t.lead('X'), t.uid('M'), now() - interval '100 minutes', false, 'no_answer', true);
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'idle' and x->>'key' like 'idle:' || t.uid('M') || ':%'),
    format('ten dials in, the idle nudge is the manager''s like anyone else''s: %s', al);
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('M') || ':%'),
    format('and so is behind pace: %s', al);
end $$;
reset role;

\echo '35 · Item 9 · pace stops at the last sign of life; behind pace leaves the gone and the finished alone'
-- These fixtures write a working day of dials into the hours behind now(), and
-- floor_pace only counts from the business day's start — so run at 7am Pacific,
-- an "8 hours ago" dial lands yesterday and vanishes. Pin the business clock to
-- a zone where it is already afternoon, whatever the wall clock here says; for
-- any UTC hour, one of these three is past 09:00 local. Put back at the end.
insert into app_settings (key, value)
select 'business_tz', to_jsonb(z)
  from (values ('UTC'), ('Asia/Tokyo'), ('America/Los_Angeles')) v(z)
 where extract(hour from now() at time zone z) >= 9
 limit 1
on conflict (key) do update set value = excluded.value;
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
-- No tile at all, which is what a browser that never said hello leaves behind: the
-- last sign of life is then simply the last dial, and the clock stops there.
select t.reset() \g /dev/null
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('X'), t.uid('A'), now() - interval '3 hours' + make_interval(secs => (i - 1) * 80),
       false, 'no_answer', true
  from generate_series(1, 45) i;
set role authenticated;
do $$
declare f record; al jsonb;
begin
  perform t.as_user('M');
  select * into f from public.floor_pace() where agent_id = t.uid('A');
  assert f.active_seconds between 3460 and 3580,
    format('with no tile the day is first dial to last dial: %s seconds active', round(f.active_seconds));
  assert f.paused_seconds = 0 and not f.on_break, format('and nothing is paused: %s', f);
  al := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'pace'),
    format('somebody with no tile at all is not on the floor to be chased: %s', al);
end $$;
reset role;
-- A tab left open all evening still pings every minute, so the clock keeps running
-- for it. That is the whole of what this fix does and does not do: it stops the
-- clock when the laptop shuts, not when the dialing stops. 200 dials that finished
-- five hours ago, tile still live, is a person at their desk who has stopped
-- working, and a manager should hear about that.
select t.reset() \g /dev/null
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('X'), t.uid('A'), now() - interval '8 hours' + make_interval(secs => (i - 1) * 54),
       false, 'no_answer', true
  from generate_series(1, 200) i;
insert into agent_status (agent_id, status, since, updated_at)
  values (t.uid('A'), 'idle', now() - interval '5 hours', now());
set role authenticated;
do $$
declare f record; al jsonb;
begin
  perform t.as_user('M');
  select * into f from public.floor_pace() where agent_id = t.uid('A');
  assert f.active_seconds between 28700 and 28900,
    format('a live tile keeps the clock running: %s seconds active', round(f.active_seconds));
  assert abs(f.dials_per_hour - 25) < 0.5, format('200 dials over eight hours is 25 an hour: %s', f.dials_per_hour);
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('A') || ':%'),
    format('at their desk and not dialing is behind pace: %s', al);
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'idle' and x->>'key' like 'idle:' || t.uid('A') || ':%'),
    format('and idle five hours, which says what is really going on: %s', al);
end $$;
reset role;
-- the same evening, with the laptop shut when the dialing stopped
update agent_status set updated_at = now() - interval '5 hours' where agent_id = t.uid('A');
set role authenticated;
do $$
declare f record; al jsonb;
begin
  perform t.as_user('M');
  select * into f from public.floor_pace() where agent_id = t.uid('A');
  assert f.active_seconds between 10700 and 10900,
    format('the day was three hours long and ends when the laptop shut: %s seconds active', round(f.active_seconds));
  assert abs(f.dials_per_hour - 66.7) < 0.5, format('200 dials over three hours is 67 an hour: %s', f.dials_per_hour);
  al := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'pace'),
    format('nobody is behind pace at home: %s', al);
end $$;
reset role;
-- the remaining fixtures stay inside three hours, which the pinned afternoon
-- zone also covers; the pin comes off at the end of this file
-- A pause someone started and never ended is a sign of life of its own: they told
-- the app they were stepping away. Without it a lunch taken after the browser went
-- quiet got clipped to nothing, so the strip read "paused 0 min" in the middle of
-- lunch and the active and paused halves stopped adding up to the day.
select t.reset() \g /dev/null
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, matched)
select t.lead('X'), t.uid('A'), now() - interval '3 hours' + make_interval(mins => i),
       false, 'no_answer', true
  from generate_series(0, 60) i;
insert into agent_status (agent_id, status, since, updated_at)
  values (t.uid('A'), 'break', now() - interval '110 minutes', now() - interval '110 minutes');
insert into agent_breaks (agent_id, reason, started_at)
  values (t.uid('A'), 'lunch', now() - interval '110 minutes');
set role authenticated;
do $$
declare f record; p jsonb;
begin
  perform t.as_user('M');
  select * into f from public.floor_pace() where agent_id = t.uid('A');
  assert f.on_break and f.break_reason = 'lunch', format('still on lunch: %s', f);
  assert f.paused_seconds between 6540 and 6660,
    format('the lunch nobody ended is still running: %s seconds paused', round(f.paused_seconds));
  assert f.active_seconds between 4140 and 4260,
    format('and the hour of dialing before it is the active day: %s seconds active', round(f.active_seconds));
  assert abs(f.active_seconds + f.paused_seconds - extract(epoch from now() - f.first_dial)) < 90,
    format('active and paused add up to the day: %s + %s', round(f.active_seconds), round(f.paused_seconds));
  perform t.as_user('A');
  p := public.my_pace();
  assert (p->>'paused_minutes')::int between 109 and 111, format('the agent''s own strip agrees: %s', p);
  assert (p->>'active_minutes')::int between 69 and 71, format('on both halves: %s', p);
end $$;
reset role;
-- A full day's number, dialed slowly: behind pace on the arithmetic, but the 300
-- dials are in. The shift is an hour here so the fixture does not need the eleven
-- hours it would otherwise take to be both past the target and behind pace. Both
-- of those are floor-wide settings, so they go back exactly as they were found
-- rather than to whatever the seed happens to say.
select t.reset() \g /dev/null
create temp table saved_pace as
  select (select value from app_settings where key = 'shift_hours') as shift_hours,
         (select target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day') as dials_target;
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
-- the manager raises the day's number: now there are 100 dials still to go
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
update app_settings set value = (select shift_hours from saved_pace) where key = 'shift_hours';
update kpi_targets set target = (select dials_target from saved_pace)
 where metric = 'dials_per_day' and scope = 'agent_day';
drop table saved_pace;

\echo '35 · Item 10 · a number nobody answers at all is what the spam alert is for; two dials a week are not a collapse'
select t.reset() \g /dev/null
insert into number_stats (number, stat_date, dials, connects) values
  ('3055557777', business_date() - 1, 80, 0),    -- carrier-flagged: 80 dials, not one pickup
  ('3055558888', business_date() - 9, 4, 1),     -- a number hardly used at all
  ('3055558888', business_date() - 1, 5, 0),
  ('3055559999', business_date() - 9, 100, 25),  -- a real collapse, on weeks worth comparing
  ('3055559999', business_date() - 1, 100, 5),
  ('3055556666', business_date() - 9, 30, 6),    -- exactly the 30 dials a week the drop rule asks for
  ('3055556666', business_date() - 1, 30, 1),
  ('3055555555', business_date() - 9, 29, 6),    -- one dial short of it last week
  ('3055555555', business_date() - 1, 30, 1),
  ('3055554444', business_date() - 9, 40, 0),    -- last week had dials and no pickups either
  ('3055554444', business_date() - 1, 40, 8);
set role authenticated;
do $$
declare al jsonb; n record;
begin
  perform t.as_user('M');
  select * into n from v_number_health where number = '3055557777';
  assert n.rate_7d = 0.0, format('no pickups is a rate of 0, not no rate: %s', n.rate_7d);
  select * into n from v_number_health where number = '3055554444';
  assert n.rate_prev_7d = 0.0,
    format('and last week reads the same way, not as a blank: %s', n.rate_prev_7d);
  assert n.dials_prev_7d = 40, format('last week''s dial count comes along for the drop rule: %s', n.dials_prev_7d);
  select * into n from v_number_health where number = '3055559999';
  assert n.dials_prev_7d = 100, format('on every number, not just that one: %s', n.dials_prev_7d);
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
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'spam' and x->>'number' = '3055556666'),
    format('exactly 30 dials a week is a week worth comparing: %s', al);
  assert not exists (select 1 from jsonb_array_elements(al) x
                      where x->>'kind' = 'spam' and x->>'number' = '3055555555'),
    format('29 is not, and neither week on its own is big enough for the absolute rule: %s', al);
  assert not exists (select 1 from jsonb_array_elements(al) x
                      where x->>'kind' = 'spam' and x->>'number' = '3055554444'),
    format('a number that went from 0%% up to 20%% is going the right way: %s', al);
end $$;
reset role;

\echo '35 · Item 11 · a call still open shows up even when the browser that made it is gone, and goes when the call is really finished'
select t.reset() \g /dev/null
-- One dial through start_attempt, wound back twenty minutes: the open attempt, the
-- lead in progress under A, and A's tile, exactly as the app leaves them.
select t.dial('A', 'X') \g /dev/null
update attempts set clicked_at = now() - interval '20 minutes';
update lead_state set in_progress_since = now() - interval '20 minutes' where lead_id = t.lead('X');
-- and then the browser died and took the heartbeat with it: no tile at all
delete from agent_status where agent_id = t.uid('A');
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
insert into agent_status (agent_id, status, lead_id, lead_name, since, updated_at)
  values (t.uid('A'), 'dialing', t.lead('X'), 'X', now() - interval '20 minutes', now() - interval '30 minutes');
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
-- Zoom's webhook writes its placeholder the moment Zoom says the call ended. The
-- call still owes a real outcome and next_lead still hands it straight back to A to
-- log, so the board has to go on saying so: the board and the queue read "open" the
-- same way or a call falls between them.
update attempts set disposition = 'no_answer', auto_logged = true, disposed_at = now();
set role authenticated;
do $$
declare al jsonb; att bigint := (select id from attempts);
begin
  perform t.as_user('A');
  assert (public.next_lead()->>'attempt_id')::bigint = att,
    'next_lead still hands A that call back to log';
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x
                  where x->>'kind' = 'long_call' and x->>'key' = 'long:' || t.uid('A') || ':' || att),
    format('a placeholder outcome is not an outcome: %s', al);
end $$;
reset role;
-- A logs it properly: now the call is finished and comes off the board.
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.log('A', (select max(id) from attempts), 'not_interested_soft');
  perform t.as_user('M');
  al := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call'),
    format('the agent''s own outcome ends it: %s', al);
end $$;
reset role;
-- A manager releasing a lead the agent still has open leaves the attempt behind
-- with nothing to close it. Reading the attempt without asking whose call it still
-- is put that on the board as "on one call 240 min" and climbing, for the rest of
-- the day, with no way for anybody to clear it.
select t.reset() \g /dev/null
select t.dial('A', 'X') \g /dev/null
update attempts set clicked_at = now() - interval '20 minutes';
update lead_state set in_progress_since = now() - interval '20 minutes' where lead_id = t.lead('X');
-- the tile has gone quiet too: push-back refuses a live call since 0032 (item 39),
-- and a browser that died mid-call is exactly the case this scenario is about
update agent_status set updated_at = now() - interval '6 minutes' where agent_id = t.uid('A');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  assert exists (select 1 from jsonb_array_elements(public.floor_alerts()) x where x->>'kind' = 'long_call'),
    'the call is A''s and open, so it is on the board';
  perform public.release_lead(t.lead('X'));
  al := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call'),
    format('a lead the manager has taken back is not A''s call to finish any more: %s', al);
  assert exists (select 1 from attempts where disposition is null),
    'and the attempt is still sitting there unlogged, which is what made this a permanent alert';
end $$;
reset role;
-- Two leads left open by one agent are two calls to ask about, one alert each,
-- because the key is the attempt and not the agent.
select t.reset() \g /dev/null
select t.dial('A', 'X') \g /dev/null
select t.dial('A', 'Y') \g /dev/null
update attempts set clicked_at = now() - interval '20 minutes';
update lead_state set in_progress_since = now() - interval '20 minutes' where owner_agent = t.uid('A');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert (select count(*) from jsonb_array_elements(al) x where x->>'kind' = 'long_call') = 2,
    format('one alert for each open call: %s', al);
  assert (select count(distinct x->>'key') from jsonb_array_elements(al) x) = 2,
    format('and two keys, so neither hides the other: %s', al);
end $$;
reset role;
-- A call outliving the queue's patience is the case this alert exists for, not a
-- reason to stop showing it. Past reclaim_minutes the queue may hand the lead back
-- to the pool, and for an answered call it deliberately leaves the outcome blank
-- rather than write a wrong one — so the lead is no longer in progress and nobody
-- owns it, and the only thing still saying a human must look is this alert.
select t.reset() \g /dev/null
create temp table saved_reclaim as select value from app_settings where key = 'reclaim_minutes';
select t.dial('A', 'X') \g /dev/null
update attempts set clicked_at = now() - interval '45 minutes';
update lead_state set in_progress_since = now() - interval '45 minutes' where lead_id = t.lead('X');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call'),
    format('45 minutes on one call is still a manager''s to look at: %s', al);
end $$;
reset role;
-- and an hour and a half in, long past anything the queue waits for, it is still the
-- one thing saying a human has to look
update attempts set clicked_at = now() - interval '90 minutes';
update lead_state set in_progress_since = now() - interval '90 minutes' where lead_id = t.lead('X');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call'),
    format('a call open for an hour and a half is still a manager''s to look at: %s', al);
end $$;
reset role;
-- A call that began just before the business day rolled over. The alert used to be
-- bounded by the business day, so a call started ten minutes before the rollover
-- went silent at the rollover — the part of the night when a dead browser is most
-- likely and least likely to be noticed.
update app_settings set value = '1500' where key = 'reclaim_minutes';
update attempts set clicked_at = public.business_day_start() - interval '5 minutes';
update lead_state set in_progress_since = public.business_day_start() - interval '5 minutes'
 where lead_id = t.lead('X');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  assert (select clicked_at from attempts) < public.business_day_start(),
    'the fixture really is a call from before the rollover';
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call'),
    format('last night''s open call is still somebody''s to finish: %s', al);
end $$;
reset role;
update app_settings set value = (select value from saved_reclaim) where key = 'reclaim_minutes';
drop table saved_reclaim;
-- a call that only just started is not a long call yet
select t.reset() \g /dev/null
select t.dial('A', 'X') \g /dev/null
update attempts set clicked_at = now() - interval '5 minutes';
update lead_state set in_progress_since = now() - interval '5 minutes' where lead_id = t.lead('X');
set role authenticated;
do $$
declare al jsonb;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call'),
    format('five minutes in is just a call: %s', al);
end $$;
reset role;
select t.reset() \g /dev/null
\echo 'alerts tests passed'

-- the business clock goes back to its default
delete from app_settings where key = 'business_tz';
