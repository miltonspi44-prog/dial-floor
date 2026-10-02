\set ON_ERROR_STOP 1
set client_min_messages = warning;

-- direct attempt rows: these tests are about counting, not the queue machine
create or replace function t.att(p text, lead text, dispo text, p_connected boolean,
                                 p_dur int default null, p_result text default null,
                                 p_when timestamptz default now()) returns bigint
language sql as $$
  insert into attempts (lead_id, agent_id, clicked_at, disposition, connected, duration_seconds,
                        call_result, matched, disposed_at, auto_logged)
  values (t.lead(lead), t.uid(p), p_when, dispo, p_connected, p_dur,
          p_result, p_result is not null, case when dispo is not null then p_when end, false)
  returning id $$;

\echo '39.1 · One meaning of conversation, one of talk time, and no dials Zoom never placed (items 15–17)'
select t.reset() \g /dev/null
do $$
declare f jsonb; t_ jsonb;
begin
  -- a gatekeeper is a connect but no conversation; a pitch is both; a not-placed is neither a dial
  perform t.att('A', 'X', 'gatekeeper_end', true, 300, 'answered');
  perform t.att('A', 'Y', 'not_interested_soft', true, 120, 'answered');
  perform t.att('A', 'Z', 'not_placed', false);
  perform t.as_user('M');
  f := public.funnel(1);
  t_ := f->'totals';
  assert (t_->>'dials')::int = 2, format('two dials, not three: %s', t_);
  assert (t_->>'connects')::int = 2, format('both people are connects: %s', t_);
  assert (t_->>'conversations')::int = 1, format('only past the gatekeeper is a conversation: %s', t_);
  assert (t_->>'talk_seconds')::int = 120, format('talk time is conversations only: %s', t_);
  -- the floor tile and pace agree
  assert (select dials_today = 2 and connects_today = 2 and conversations_today = 1
            from v_floor_today where agent_id = t.uid('A')),
    format('the tile says the same: %s', (select to_jsonb(v) from v_floor_today v where agent_id = t.uid('A')));
  assert (select f2.dials = 2 and f2.talk_seconds = 120 from public.floor_pace() f2 where f2.agent_id = t.uid('A')),
    'and so does pace';
  -- the leaderboard will not count the phantom dial either
  assert ((select x from jsonb_array_elements(public.leaderboard('today')->'rows') x
            where x->>'agent_id' = t.uid('A')::text)->>'dials')::int = 2,
    'the leaderboard leaves the not-placed out';
end $$;

\echo '39.2 · "By intent" counts each dial once, under its strongest intent (item 24)'
select t.reset() \g /dev/null
do $$
declare f jsonb; v_sum int;
begin
  delete from lead_intents where lead_id = t.lead('X');
  insert into lead_intents (lead_id, intent_key, confidence, source) values
    (t.lead('X'), 'no_website', 1.0, 'manual'),
    (t.lead('X'), 'review_rich', 0.9, 'manual'),
    (t.lead('X'), 'owner_mobile', 0.8, 'manual');
  perform t.att('A', 'X', 'no_answer', false);
  perform t.as_user('M');
  f := public.funnel(1);
  select sum((x->>'dials')::int) into v_sum from jsonb_array_elements(f->'by_intent') x;
  assert v_sum = 1, format('one dial lands in one intent row, got a sum of %s: %s', v_sum, f->'by_intent');
  assert (select (x->>'intent') from jsonb_array_elements(f->'by_intent') x limit 1) = 'no_website',
    'and it lands under the strongest intent';
end $$;

\echo '39.3 · The scorecard''s "ended in a no" keeps to real noes, and its talk time to conversations (item 24)'
select t.reset() \g /dev/null
do $$
declare s jsonb; wk jsonb;
begin
  perform t.att('A', 'X', 'not_interested_hard', true, 300, 'answered');
  perform t.att('A', 'Y', 'wrong_number', true, 400, 'answered');
  perform t.att('A', 'Z', 'dm_not_in', true, 350, 'answered');
  perform t.att('A', 'W', 'gatekeeper_end', true, 500, 'answered');
  perform t.as_user('M');
  s := public.scorecard(t.uid('A'), 1);
  assert jsonb_array_length(s->'review') = 1
     and s->'review'->0->>'disposition' = 'not_interested_hard',
    format('only the real no is worth talking through: %s', s->'review');
  select w->'me' into wk from jsonb_array_elements(s->'weeks') w order by w->>'week' desc limit 1;
  assert (wk->>'talk_seconds')::int = 300 + 400 + 350,
    format('talk time is the conversations'' seconds, not the gatekeeper''s: %s', wk);
end $$;

\echo '39.4 · A dead heat has no winner picked by the alphabet (item 24)'
select t.reset() \g /dev/null
do $$
declare b jsonb;
begin
  perform t.as_user('M');
  perform public.start_sprint('Tie race', 'dials', 30, null);
  -- one transaction, one now(): the race has to start before the dials land in it
  update sprints set starts_at = now() - interval '2 minutes' where ends_at > now();
  perform t.att('A', 'X', 'no_answer', false, null, null, now() - interval '1 minute');
  perform t.att('B', 'Y', 'no_answer', false, null, null, now() - interval '1 minute');
  update sprints set ends_at = now() - interval '1 second' where ends_at > now();
  b := public.sprint_board();
  assert b->'winner' = 'null'::jsonb, format('a tie names no winner, got %s', b->'winner');
  assert jsonb_array_length(b->'winners') = 2, format('it names the dead heat instead: %s', b->'winners');
end $$;
select t.reset() \g /dev/null
do $$
declare b jsonb;
begin
  perform t.as_user('M');
  perform public.start_sprint('Clear race', 'dials', 30, null);
  update sprints set starts_at = now() - interval '2 minutes' where ends_at > now();
  perform t.att('A', 'X', 'no_answer', false, null, null, now() - interval '1 minute');
  perform t.att('A', 'Y', 'no_answer', false, null, null, now() - interval '1 minute');
  perform t.att('B', 'Z', 'no_answer', false, null, null, now() - interval '1 minute');
  update sprints set ends_at = now() - interval '1 second' where ends_at > now();
  b := public.sprint_board();
  assert b->'winner'->>'agent_id' = t.uid('A')::text, format('a clear lead still wins, got %s', b->'winner');
  assert not (b ? 'winners'), 'and no dead heat is claimed';
end $$;

\echo '39.5 · "Never answers" counts the business across its records, inside a window (item 24)'
select t.reset() \g /dev/null
do $$
declare v_hours jsonb := public.setting('business_hours');
begin
  update app_settings set value = '{"start":"00:00","end":"23:59","days":[1,2,3,4,5,6,7]}'
   where key = 'business_hours';
  perform t.att('A', 'D1', 'no_answer', false, null, 'not_answered', now() - interval '1 hour');
  perform t.att('A', 'D2', 'no_answer', false, null, 'not_answered', now() - interval '2 hours');
  perform t.att('B', 'D2', 'voicemail', false, null, 'not_answered', now() - interval '3 hours');
  perform t.att('B', 'D1', 'no_answer', false, null, 'not_answered', now() - interval '100 days');
  assert (select count(*) from missed_tries(t.lead('D1'))) = 3,
    format('both records'' recent misses count, the stale one does not: %s',
           (select count(*) from missed_tries(t.lead('D1'))));
  update app_settings set value = v_hours where key = 'business_hours';
end $$;

\echo '39.6 · Windows land on midnight, business clock, whatever the season (item 24)'
do $$
declare f jsonb;
begin
  assert not exists (select 1 from generate_series(0, 400) g
                      where ((public.business_days_ago(g)) at time zone public.business_tz())::time
                            <> time '00:00'),
    'every "N days ago" is a midnight on the business clock, across both daylight-saving changes';
  perform t.as_user('M');
  f := public.funnel(30);
  assert (f->>'from')::timestamptz = public.business_days_ago(29), 'and the funnel uses it';
end $$;

\echo '39.7 · The target is conversations, under one name'
do $$
declare d jsonb;
begin
  assert exists (select 1 from kpi_targets where metric = 'conversations_per_day' and scope = 'agent_day'),
    'the saved target survives under its real name';
  assert not exists (select 1 from kpi_targets where metric = 'connects_per_day'),
    'and the old name is gone';
  perform t.as_user('M');
  d := public.digest(t.uid('A'), 7);
  assert d->'targets' ? 'conversations', format('the digest hands it over as conversations: %s', d->'targets');
end $$;

\echo '39.8 · The radar''s "converting above average" is about conversations (item 24)'
select t.reset() \g /dev/null
do $$
declare r jsonb; v_rr text := (select label from intents_catalog where key = 'review_rich');
        v_nw text := (select label from intents_catalog where key = 'no_website');
begin
  delete from lead_intents where lead_id in (t.lead('X'), t.lead('Y'));
  insert into lead_intents (lead_id, intent_key, confidence, source)
    values (t.lead('X'), 'no_website', 1.0, 'manual'), (t.lead('Y'), 'review_rich', 1.0, 'manual');
  -- X: 25 gatekeeper stops (connected, no conversation). Y: 25 pitches. Plus noise
  -- that must not count: 30 not-placed clicks on X.
  for i in 1..25 loop
    perform t.att('A', 'X', 'gatekeeper_end', true, 30, 'answered');
    perform t.att('A', 'Y', 'not_interested_soft', true, 60, 'answered');
  end loop;
  for i in 1..30 loop
    perform t.att('A', 'X', 'not_placed', false);
  end loop;
  perform t.as_user('M');
  r := public.radar();
  assert exists (select 1 from jsonb_array_elements(r->'converting') x
                  where x->>'kind' = 'intent' and x->>'label' = v_rr),
    format('the intent whose conversations run above the floor is listed: %s', r->'converting');
  assert not exists (select 1 from jsonb_array_elements(r->'converting') x
                      where x->>'kind' = 'intent' and x->>'label' = v_nw),
    format('the one that only reaches gatekeepers is not: %s', r->'converting');
end $$;

\echo '39.9 · Best time learns from calls that happened'
select t.reset() \g /dev/null
do $$
begin
  perform t.att('A', 'X', 'no_answer', false, null, 'not_answered');
  perform t.att('A', 'Y', 'not_interested_soft', true, 60, 'answered');
  perform t.att('A', 'Z', 'not_placed', false);
  perform public.best_time_refresh();
  assert ((public.setting('best_time_state'))->>'total')::int = 2,
    format('two real calls in the sample, not three: %s', public.setting('best_time_state'));
end $$;
\echo 'metric tests passed'
