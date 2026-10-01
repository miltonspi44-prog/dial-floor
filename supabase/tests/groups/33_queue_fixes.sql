-- 0022: the seven dialing-queue bugs. Runs after queue_test.sql, which leaves the
-- fixtures (leads X, Y, Z, W and the twins D1/D2 on one number) and the t.* helpers.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '33.1 · A stale screen cannot dial a lead that has been rested, capped or dialed since (item 2)'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- A loads X and looks away long enough for the ten-minute hold to lapse
  assert t.name(t.next('A')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  -- so B is served the same lead, dials it and gets a hard no
  assert t.name(t.next('B')) = 'X', 'a lapsed reservation frees the lead';
  att := t.dial('B', 'X');
  perform t.log('B', att, 'not_interested_hard');
  -- A's screen still shows X, and the Dial button must not go through
  perform t.as_user('A');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'parked since you loaded it');
  assert (select state = 'resting' and rest_until > now() + interval '19 days'
            from lead_state where lead_id = t.lead('X')), 'the 20-day rest B just set is still there';
  assert (select count(*) from attempts where lead_id = t.lead('X')) = 1, 'and no second call was placed';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- the same stale screen, but B's call was X's last one for today
  assert t.name(t.next('A')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X';
  att := t.dial('B', 'X');
  perform t.log('B', att, 'no_answer');
  update lead_state set attempts_today = 2, attempts_today_date = business_date(),
      last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  perform t.as_user('A');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'all its calls for today');
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- and once more, inside the redial gap
  assert t.name(t.next('A')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X';
  att := t.dial('B', 'X');
  perform t.log('B', att, 'no_answer');
  perform t.as_user('A');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'dialed since you loaded it');
  -- the gap passes: the lead is dialable again, so this is no blanket refusal
  update lead_state set last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  assert t.dial('A', 'X') is not null, 'once the gap has passed the dial goes through';
end $$;

\echo '33.2 · An unanswered callback stays with the agent who promised it (item 3)'
select t.reset() \g /dev/null
-- A promised to call X back, and X is in the queue rather than locked to A: the state
-- a call taken over and logged by somebody else leaves behind.
insert into callbacks (lead_id, agent_id, due_at) values (t.lead('X'), t.uid('A'), now() - interval '5 minutes');
do $$
declare att bigint; n jsonb; v_due timestamptz;
begin
  v_due := (select due_at from callbacks where lead_id = t.lead('X'));
  -- B is handed X by the pool, and nobody picks up
  att := t.dial('B', 'X');
  n := t.log('B', att, 'no_answer');
  assert (select status = 'scheduled' and tries = 0 and due_at = v_due from callbacks where lead_id = t.lead('X')),
    'B''s call leaves A''s promise exactly as it was';
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')),
    'and does not lock the lead to B';
  assert t.name(n->'next') is distinct from 'X', 'B moves on to another lead';
  -- A is served their own promise, and this time the dial goes out
  n := t.next('A');
  assert n->>'reason' = 'callback_due' and t.name(n) = 'X',
    format('A is still served their callback: %s %s', n->>'reason', t.name(n));
  att := t.dial('A', 'X');
  n := t.log('A', att, 'no_answer');
  assert (select status = 'scheduled' and tries = 1 and due_at > now() from callbacks where lead_id = t.lead('X')),
    'A''s own unanswered call moves the promise on';
  assert (select state = 'callback_locked' and owner_agent = t.uid('A')
            from lead_state where lead_id = t.lead('X')), 'and keeps the lead with A';
end $$;

\echo '33.3 · A call abandoned by a dead tab is finished, and a long call still resumes (item 4)'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  -- A dials, Zoom's webhook writes the no-answer on the attempt, and the tab dies
  att := t.dial('A', 'X');
  update attempts set call_result = 'not_answered', disposition = 'no_answer', auto_logged = true,
      connected = false, disposed_at = now(), matched = true, clicked_at = now() - interval '2 hours'
    where id = att;
  update lead_state set in_progress_since = now() - interval '2 hours',
      last_attempt_at = now() - interval '2 hours' where lead_id = t.lead('X');
  -- A comes back two hours later: the call is still theirs to log
  n := t.next('A');
  assert n->>'reason' = 'resume' and (n->>'attempt_id')::bigint = att,
    format('an old open call still comes back: %s', n->>'reason');
  n := t.log('A', att, 'not_interested_soft');
  assert (select state = 'resting' from lead_state where lead_id = t.lead('X')), 'and its outcome reaches the lead';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- nobody comes back for this one
  att := t.dial('A', 'X');
  update attempts set clicked_at = now() - interval '3 hours' where id = att;
  update lead_state set in_progress_since = now() - interval '3 hours',
      last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  -- the next lead anyone asks for sweeps it up
  perform t.next('B');
  assert (select state = 'queued' and owner_agent is null and in_progress_since is null
            from lead_state where lead_id = t.lead('X')), 'the stranded lead is back in the queue';
  assert (select disposition = 'no_answer' and auto_logged and disposed_at is not null
            from attempts where id = att), 'and the call is recorded as a no-answer';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- the same, on a call that was keeping a callback
  att := t.dial('A', 'X');
  perform t.log('A', att, 'callback', jsonb_build_object('due_at', now() + interval '1 minute'));
  perform t.next('A');
  att := t.dial('A', 'X');
  -- the abandoned call is three hours old, and the call that promised the callback older still
  update attempts set clicked_at = now() - interval '4 hours' where lead_id = t.lead('X') and id <> att;
  update attempts set clicked_at = now() - interval '3 hours' where id = att;
  update lead_state set in_progress_since = now() - interval '3 hours',
      last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  perform t.next('B');
  assert (select status = 'scheduled' and tries = 1 and due_at > now() from callbacks where lead_id = t.lead('X')),
    'the promise is kept and tried again later';
  assert (select state = 'callback_locked' and owner_agent = t.uid('A')
            from lead_state where lead_id = t.lead('X')),
    'and the lead goes back to the agent who promised it, not to whoever loaded next';
end $$;

\echo '33.4 · Do-not-call reaches the console for every record of the business (item 7)'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  att := t.dial('A', 'D1');
  perform t.log('A', att, 'dnc', '{"note":"asked us to stop"}');
  assert (select count(*) from lead_state ls join leads l on l.id = ls.lead_id
           where l.phone_norm = '3055550099' and ls.writeback_status = 'do_not_call'
             and not ls.writeback_done) = 2,
    format('both records are queued for the console, got %s',
           (select jsonb_agg(jsonb_build_object('name', l.name, 'status', ls.writeback_status, 'done', ls.writeback_done))
              from lead_state ls join leads l on l.id = ls.lead_id where l.phone_norm = '3055550099'));
  assert (select state from lead_state where lead_id = t.lead('D2')) = 'suppressed', 'the twin is suppressed too';
end $$;
do $$ begin
  -- a re-scrape brings the same number back as a new row: the console hears about
  -- that one as well, and only once
  update lead_state set state = 'queued', writeback_status = null, writeback_note = null,
      writeback_done = true where lead_id = t.lead('D2');
  perform refresh_lead(t.lead('D2'));
end $$;
do $$ begin
  assert (select state = 'suppressed' and writeback_status = 'do_not_call' and not writeback_done
            from lead_state where lead_id = t.lead('D2')), 'a freshly synced twin is written back too';
  update lead_state set writeback_done = true where lead_id = t.lead('D2');  -- the sync worker pushes it
  perform refresh_lead(t.lead('D2'));
end $$;
do $$ begin
  assert (select writeback_done from lead_state where lead_id = t.lead('D2')),
    'and it is not queued again every time the lead is synced';
end $$;

\echo '33.5 · A callback in the past is refused; "not in" retries on the lead''s clock (item 28)'
select t.reset() \g /dev/null
do $$
declare att bigint;
        v_past text := to_char((now() at time zone 'America/New_York') - interval '10 minutes', 'YYYY-MM-DD"T"HH24:MI');
        v_soon text := to_char((now() at time zone 'America/New_York') + interval '3 days', 'YYYY-MM-DD"T"HH24:MI');
begin
  att := t.dial('A', 'X');
  -- a month (or an hour) typed wrong used to book the callback in the past, and the
  -- lead came straight back as due on the same screen
  perform t.fails(format('select public.log_disposition(%s, ''callback'', jsonb_build_object(''due_local'', %L))',
                         att, v_past), 'already gone past');
  assert (select disposition is null from attempts where id = att), 'and nothing is logged';
  perform t.log('A', att, 'callback', jsonb_build_object('due_local', v_soon));
  assert (select count(*) = 1 and min(due_at) > now() from callbacks where lead_id = t.lead('X')),
    'a time still to come is booked as usual';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
        v_at text := to_char((now() at time zone 'America/New_York') + interval '4 hours', 'YYYY-MM-DD"T"HH24:MI');
        v_past text := to_char((now() at time zone 'America/New_York') - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI');
begin
  -- "he is back after four" is four o'clock where the lead is
  att := t.dial('A', 'X');
  perform t.log('A', att, 'dm_not_in', jsonb_build_object('retry_local', v_at));
  assert (select rest_until = v_at::timestamp at time zone 'America/New_York'
            from lead_state where lead_id = t.lead('X')),
    format('back at %s on the lead''s clock, got %s', v_at, (select rest_until from lead_state where lead_id = t.lead('X')));
  att := t.dial('A', 'Y');
  perform t.fails(format('select public.log_disposition(%s, ''dm_not_in'', jsonb_build_object(''retry_local'', %L))',
                         att, v_past), 'already gone past');
end $$;

\echo '33.6 · Skip still works once the reservation has lapsed (item 33)'
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  assert t.name(t.next('A')) = 'X';
  -- ten minutes of looking away: A's hold lapses and B is served X, then B's lapses too
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  -- A comes back and presses Skip on the lead still in front of them
  n := t.skip('A', 'X');
  assert (select rest_until > now() + interval '55 minutes' from lead_state where lead_id = t.lead('X')),
    'the skipped lead sits out';
  assert t.name(n->'next') is distinct from 'X', format('and A is given another lead, got %s', t.name(n->'next'));
end $$;
select t.reset() \g /dev/null
do $$
begin
  -- but a lead another agent has open right now is not ours to skip
  assert t.name(t.next('B')) = 'X';
  perform t.skip('A', 'X');
  assert (select rest_until is null and reserved_by = t.uid('B') from lead_state where lead_id = t.lead('X')),
    'B keeps the lead they have open';
end $$;

\echo '33.7 · A failure loading the next lead keeps the outcome that was logged (item 34)'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  att := t.dial('A', 'X');
  -- a setting typed wrong: next_lead cannot even work out the daily cap
  update app_settings set value = '"two"' where key = 'max_attempts_per_day';
  n := t.log('A', att, 'not_interested_soft');
  assert (n->>'ok')::boolean and (n->'next'->>'empty')::boolean,
    format('the outcome comes back with an empty next: %s', n);
  assert n->'next'->>'hint' like '%Check again%', format('and something plain to do: %s', n->'next'->>'hint');
  assert (select disposition = 'not_interested_soft' and disposed_at is not null from attempts where id = att),
    'the call stays logged';
  assert (select state = 'resting' from lead_state where lead_id = t.lead('X')), 'and the lead stays parked';
end $$;
update app_settings set value = '2' where key = 'max_attempts_per_day';
do $$
declare n jsonb;
begin
  assert t.name(t.next('A')) is not null, 'and the next request works again';
end $$;

\echo 'queue fix tests passed'
