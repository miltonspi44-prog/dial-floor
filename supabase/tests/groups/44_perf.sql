\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '44.1 · Streaks come from a once-a-day cache, and the cache tells the truth (item 42)'
select t.reset() \g /dev/null
do $$
declare v int; v_target numeric;
begin
  -- pin the day's target to 1 for the block (the seed ships a real one)
  select target into v_target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day';
  update kpi_targets set target = 1 where metric = 'dials_per_day' and scope = 'agent_day';
  -- B hit the target today; A did not
  perform t.att('B', 'Y', 'no_answer', false);
  select streak into v from public.streaks() s where s.agent_id = t.uid('B');
  assert v = 1, format('first read computes and caches: %s', v);
  assert (select count(*) from streak_cache where day = public.business_date()) >= 2, 'the cache holds the floor';
  -- the cache answers now; a second dial today shows tomorrow (day-grain number)
  update streak_cache set streak = 7 where agent_id = t.uid('B');
  select streak into v from public.streaks() s where s.agent_id = t.uid('B');
  assert v = 7, 'reads come from the cache, not a fresh 60-day walk';
  update kpi_targets set target = v_target where metric = 'dials_per_day' and scope = 'agent_day';
end $$;

\echo '44.2 · The whole floor board arrives in one call, manager panes included (item 42)'
select t.reset() \g /dev/null
do $$
declare b jsonb;
begin
  perform t.att('A', 'X', 'not_interested_soft', true, 120, 'answered');
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('Y'), t.uid('A'), now() + interval '1 hour');
  perform t.as_user('M');
  b := public.floor_board();
  assert b ? 'tiles' and b ? 'pace' and b ? 'alerts' and b ? 'leaderboard'
     and b ? 'callbacks' and b ? 'recent' and b ? 'health', format('one call, every pane: %s', (select array_agg(k) from jsonb_object_keys(b) k));
  assert jsonb_array_length(b->'callbacks') = 1 and b->'callbacks'->0->>'lead' = 'Y',
    'the callbacks pane carries the lead and its clock';
  assert (b->'callbacks'->0->>'tz') is not null, 'with the lead''s timezone for lead-local display (item 45)';
  assert jsonb_array_length(b->'recent') = 1, 'and the recent calls';
  -- agents get the shared panes and none of the manager''s
  perform t.as_user('A');
  b := public.floor_board();
  assert b->'callbacks' = 'null'::jsonb and b->'recent' = 'null'::jsonb and b->'health' = 'null'::jsonb,
    'the manager panes stay the manager''s';
  assert b ? 'tiles' and b ? 'leaderboard', 'the floor itself is everyone''s';
end $$;

\echo '44.3 · The morning radar can run with no login attached (item 49)'
select t.reset() \g /dev/null
do $$
declare r jsonb;
begin
  delete from app_settings where key = 'radar_last_run';
  perform t.as_user(null);
  r := public.radar_cron();
  assert (r->>'ran')::boolean, format('the scheduler''s run deals the day: %s', r);
  assert not (public.radar_cron()->>'ran')::boolean, 'and only once';
  assert (select count(*) from streak_cache where day = public.business_date()) > 0,
    'the day''s streaks land with the day''s lists';
end $$;
\echo 'perf tests passed'
