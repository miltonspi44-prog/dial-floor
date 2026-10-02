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
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- A rest that leaves the lead in the queue is the one the state check cannot see:
  -- the gatekeeper ended the call, so X is queued but resting for three days.
  assert t.name(t.next('A')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X';
  att := t.dial('B', 'X');
  perform t.log('B', att, 'gatekeeper_end');
  assert (select state = 'queued' and rest_until > now() + interval '2 days'
            from lead_state where lead_id = t.lead('X')), 'queued, and resting';
  perform t.as_user('A');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'just been through this lead');
end $$;
select t.reset() \g /dev/null
do $$
begin
  -- And a rest with no call behind it at all: B passed on the lead rather than dialing
  -- it. Nobody's own call explains that rest, so it has to hold against A's old screen.
  assert t.name(t.next('A')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X';
  perform t.skip('B', 'X');
  assert (select rest_until > now() + interval '55 minutes' from lead_state where lead_id = t.lead('X')),
    'B''s skip rests X';
  assert (select count(*) from attempts where lead_id = t.lead('X')) = 0, 'and no call was made on it';
  perform t.as_user('A');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'just been through this lead');
  assert (select rest_until > now() + interval '55 minutes' from lead_state where lead_id = t.lead('X')),
    'and B''s skip is still resting the lead';
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
select t.reset() \g /dev/null
-- But a promise on a lead somebody else has parked is a promise that cannot be kept:
-- leaving it scheduled served the lead back as due on a 20-day rest, and the callback's
-- own no-answer then wiped that rest out — item 2's hole, through item 3's door.
insert into callbacks (lead_id, agent_id, due_at) values (t.lead('X'), t.uid('A'), now() - interval '5 minutes');
do $$
declare att bigint; n jsonb;
begin
  att := t.dial('B', 'X');
  perform t.log('B', att, 'not_interested_hard');
  assert (select status = 'cancelled' from callbacks where lead_id = t.lead('X')),
    format('A''s promise is cancelled by the park, not missed by A, got %s',
           (select status from callbacks where lead_id = t.lead('X')));
  n := t.next('A');
  assert t.name(n) is distinct from 'X',
    format('and A is not served a resting lead, got %s (%s)', t.name(n), n->>'reason');
  -- even with the callback still on their screen, the Dial button refuses
  update callbacks set status = 'scheduled' where lead_id = t.lead('X');
  perform t.as_user('A');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'parked since you loaded it');
  assert (select rest_until > now() + interval '19 days' from lead_state where lead_id = t.lead('X')),
    'so B''s 20-day rest survives';
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
  -- nobody comes back for this one, and Zoom never wrote a thing: no match, no
  -- call id, no result. That is a click whose call never rang anywhere (item 17),
  -- so it is closed as not placed and everything the click charged comes back.
  att := t.dial('A', 'X');
  update attempts set clicked_at = now() - interval '3 hours' where id = att;
  update lead_state set in_progress_since = now() - interval '3 hours',
      last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  -- the tab is gone, so it stopped pinging: that is what tells the sweep it is dead,
  -- and the board keeps showing A on this call until the sweep finishes it
  update agent_status set updated_at = now() - interval '3 hours' where agent_id = t.uid('A');
  -- the next lead anyone asks for sweeps it up
  perform t.next('B');
  assert (select state = 'queued' and owner_agent is null and in_progress_since is null
            from lead_state where lead_id = t.lead('X')), 'the stranded lead is back in the queue';
  assert (select disposition = 'not_placed' and not auto_logged and disposed_at is not null
            from attempts where id = att),
    format('a call Zoom never saw is closed as not placed, got %s',
           (select disposition from attempts where id = att));
  assert (select attempts_today = 0 and attempts_total = 0 and last_attempt_at is null
            from lead_state where lead_id = t.lead('X')),
    'and the cap, the gap and the totals get the click back';
  assert (select status = 'idle' and lead_id is null from agent_status where agent_id = t.uid('A')),
    'A is not shown dialing a lead that is back in the queue';
  assert (select updated_at < now() - interval '2 hours' from agent_status where agent_id = t.uid('A')),
    'and their last ping is left alone, so the board still shows the dead tab as offline';
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
  -- the abandoned call is three hours old, and the call that promised the callback older
  -- still. Zoom did place this one — its result is on the row, only the outcome write
  -- was lost — so the sweep finishes it as a no-answer rather than a not-placed.
  update attempts set clicked_at = now() - interval '4 hours' where lead_id = t.lead('X') and id <> att;
  update attempts set clicked_at = now() - interval '3 hours',
      call_result = 'not_answered', matched = true where id = att;
  update lead_state set in_progress_since = now() - interval '3 hours',
      last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  -- the tab is gone, so it stopped pinging: that is what tells the sweep it is dead
  update agent_status set updated_at = now() - interval '3 hours' where agent_id = t.uid('A');
  perform t.next('B');
  assert (select status = 'scheduled' and tries = 1 and due_at > now() from callbacks where lead_id = t.lead('X')),
    'the promise is kept and tried again later';
  assert (select state = 'callback_locked' and owner_agent = t.uid('A')
            from lead_state where lead_id = t.lead('X')),
    'and the lead goes back to the agent who promised it, not to whoever loaded next';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- A call Zoom says was answered is a conversation nobody wrote down, not a no-answer:
  -- calling it one tells the radar this business never picks up and books the
  -- conversation as a miss. There is nothing to guess, so the sweep leaves the whole
  -- thing alone — the lead stays with the agent who had the conversation, so the call
  -- is still theirs to come back and log, and it stays on the manager's long-call list
  -- until a person settles it.
  att := t.dial('A', 'X');
  update attempts set call_result = 'answered', duration_seconds = 90, matched = true,
      clicked_at = now() - interval '3 hours' where id = att;
  update lead_state set in_progress_since = now() - interval '3 hours',
      last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  -- the tab is gone, so it stopped pinging: that is what tells the sweep it is dead
  update agent_status set updated_at = now() - interval '3 hours' where agent_id = t.uid('A');
  perform t.next('B');
  assert (select disposition is null and not auto_logged from attempts where id = att),
    format('the answered call is not written off as a no-answer, got %s',
           (select disposition from attempts where id = att));
  assert (select state = 'in_progress' and owner_agent = t.uid('A')
            from lead_state where lead_id = t.lead('X')),
    'and the lead stays with the agent who had the conversation';
  assert (select count(*) from missed_tries(t.lead('X'))) = 0,
    'and it is not counted against the business as a missed try';
  -- A's own next request hands it straight back to them to log
  assert (t.next('A')->>'attempt_id')::bigint = att, 'A gets the call back to finish';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint; i int;
begin
  -- and because it is left alone, it must not sit in the sweep's window either: the
  -- sweep takes the oldest few, so a lead it will only ever skip would starve the rest
  update app_settings set value = '1' where key = 'reclaim_sweep_max';
  att := t.dial('A', 'X');
  update attempts set call_result = 'answered', duration_seconds = 90,
      clicked_at = now() - interval '5 hours' where id = att;
  update lead_state set in_progress_since = now() - interval '5 hours' where lead_id = t.lead('X');
  insert into attempts (lead_id, agent_id, clicked_at)
    values (t.lead('Y'), t.uid('A'), now() - interval '3 hours');
  update lead_state set state = 'in_progress', owner_agent = t.uid('A'),
      in_progress_since = now() - interval '3 hours' where lead_id = t.lead('Y');
  update agent_status set updated_at = now() - interval '5 hours' where agent_id = t.uid('A');
  perform t.next('B');
  assert (select state = 'queued' from lead_state where lead_id = t.lead('Y')),
    'the newer stranded call is still swept though an older conversation is waiting';
  update app_settings set value = '25' where key = 'reclaim_sweep_max';
end $$;
select t.reset() \g /dev/null
do $$
declare ids bigint[] := array[t.lead('X'), t.lead('Y'), t.lead('Z'), t.lead('W')]; i int; n int;
begin
  -- The first Check after this ships meets every call stranded since the bug began, and
  -- it runs under the API's statement timeout: the sweep takes the oldest few and
  -- leaves the rest for the next Check, rather than timing out and starting again.
  update app_settings set value = '2' where key = 'reclaim_sweep_max';
  for i in 1..4 loop
    insert into attempts (lead_id, agent_id, clicked_at)
      values (ids[i], t.uid('A'), now() - make_interval(hours => 5 - i));
    update lead_state set state = 'in_progress', owner_agent = t.uid('A'),
        in_progress_since = now() - make_interval(hours => 5 - i),
        last_attempt_at = now() - make_interval(hours => 5 - i)
      where lead_id = ids[i];
  end loop;
  -- a hand-written automatic intent: re-deriving the lead would wipe it, and that is
  -- the per-lead work that made the sweep too slow to ever finish
  insert into lead_intents (lead_id, intent_key, confidence, source)
    values (t.lead('X'), 'owner_mobile', 0.5, 'auto');
  perform t.next('B');
  n := (select count(*) from lead_state where state = 'in_progress' and lead_id = any(ids));
  assert n = 2, format('two stranded calls finished per Check, %s still in progress', n);
  assert (select count(*) from lead_state
           where state = 'queued' and lead_id in (t.lead('X'), t.lead('Y'))) = 2, 'the oldest first';
  assert exists (select 1 from lead_intents where lead_id = t.lead('X') and intent_key = 'owner_mobile'),
    'and the sweep does not re-derive each lead on the way past';
  perform t.next('B');
  n := (select count(*) from lead_state where state = 'in_progress' and lead_id = any(ids));
  assert n = 0, format('the next Check takes the rest, %s left', n);
end $$;
delete from lead_intents where lead_id = t.lead('X') and intent_key = 'owner_mobile';
update app_settings set value = '25' where key = 'reclaim_sweep_max';
select t.reset() \g /dev/null
do $$
declare a_old bigint; a_now bigint; n jsonb;
begin
  -- Resume is for the call the lead is on. A has an old auto-logged call on X from last
  -- week and a fresh one they logged properly; if the lead is still in progress (a
  -- crash between the two writes), resume must not hand back last week's call and
  -- stamp today's outcome on it.
  a_old := t.dial('A', 'X');
  update attempts set clicked_at = now() - interval '5 days', disposition = 'no_answer',
      auto_logged = true, connected = false, disposed_at = now() - interval '5 days' where id = a_old;
  update lead_state set state = 'queued', owner_agent = null, in_progress_since = null,
      attempts_today = 0, attempts_today_date = null, last_attempt_at = now() - interval '5 days'
    where lead_id = t.lead('X');
  a_now := t.dial('A', 'X');
  update attempts set disposition = 'voicemail', auto_logged = false, disposed_at = now() where id = a_now;
  n := t.next('A');
  assert n->>'reason' is distinct from 'resume' and n->>'attempt_id' is null,
    format('a call already logged is not resumed: %s on attempt %s', n->>'reason', n->>'attempt_id');
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
select t.reset() \g /dev/null
do $$
declare a1 bigint; a2 bigint;
begin
  -- Two agents on the two records of one business at once. The console keeps one status
  -- per record, so what it is told about the record that was sold must not be replaced
  -- by the wrong number found on the other one a moment later. The per-business redial
  -- gap now stops two clicks landing together (group 38), so the second call starts
  -- after a cleared gap — both are still open when the outcomes land.
  a1 := t.dial('A', 'D1');
  update lead_state set last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('D1');
  a2 := t.dial('B', 'D2');
  perform t.log('A', a1, 'sale_closed', '{"summary":"sold - seo","rating":5}');
  perform t.log('B', a2, 'wrong_number');
  assert (select state = 'handoff' and writeback_status = 'captured' and not writeback_done
            from lead_state where lead_id = t.lead('D1')),
    format('D1 keeps the sale, got %s',
           (select jsonb_build_object('state', state, 'status', writeback_status)
              from lead_state where lead_id = t.lead('D1')));
  assert (select writeback_status = 'wrong_number' from lead_state where lead_id = t.lead('D2')),
    'and D2 still carries its own wrong number';
end $$;
select t.reset() \g /dev/null
do $$
declare a1 bigint; a2 bigint;
begin
  -- the other way round: do-not-call is the most final thing the console can be told,
  -- so it goes over a sale on the twin (same gap-clearing as above)
  a1 := t.dial('A', 'D1');
  update lead_state set last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('D1');
  a2 := t.dial('B', 'D2');
  perform t.log('A', a1, 'sale_closed', '{"summary":"sold - seo","rating":5}');
  perform t.log('B', a2, 'dnc', '{"note":"asked us to stop"}');
  assert (select writeback_status = 'do_not_call' and not writeback_done
            from lead_state where lead_id = t.lead('D1')),
    format('do-not-call reaches the twin, got %s',
           (select writeback_status from lead_state where lead_id = t.lead('D1')));
  assert (select state = 'handoff' from lead_state where lead_id = t.lead('D1')),
    'and the handoff is still a handoff';
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
  -- ten minutes of looking away: A's hold lapses while X is still on their screen
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
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
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  -- A lead handed on to somebody else while A was looking away is not A's to rest, even
  -- once that agent's hold has lapsed in turn: B was the one served it, and a rest would
  -- stop B dialing what is on their screen. A is given a lead instead — which may well
  -- be this same one, now properly theirs, and the Skip after that does rest it. That is
  -- the trade for Skip taking a lead id: one extra press here, rather than any agent
  -- being able to rest a lead they were never served.
  assert t.name(t.next('A')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  n := t.skip('A', 'X');
  assert (select rest_until is null from lead_state where lead_id = t.lead('X')),
    format('X is not rested by an agent it was handed away from, got %s',
           (select rest_until from lead_state where lead_id = t.lead('X')));
  assert (n->>'ok')::boolean, 'and A still gets an answer';
  if t.name(n->'next') = 'X' then
    n := t.skip('A', 'X');
    assert (select rest_until > now() + interval '55 minutes' from lead_state where lead_id = t.lead('X')),
      'and once the pool has handed it back it is theirs to skip';
    assert t.name(n->'next') is distinct from 'X', 'so the second press moves on';
  end if;
end $$;
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  -- And a lead that was never on their screen is not theirs to rest either: Skip takes
  -- a lead id, so otherwise one agent could walk the ids and rest the whole pool.
  assert t.name(t.next('A')) = 'X';
  n := t.skip('A', 'W');
  assert (select rest_until is null and reserved_by is null from lead_state where lead_id = t.lead('W')),
    format('W was never served to A, got rest %s', (select rest_until from lead_state where lead_id = t.lead('W')));
  assert (select count(*) from list_items li join lists ld on ld.id = li.list_id
           where li.lead_id = t.lead('W') and li.served_at is not null) = 0,
    'and no list has it marked as served';
  assert (n->>'ok')::boolean, 'the agent still gets a lead to work on';
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
-- The failure that actually happens is the statement timeout the API puts on every
-- call, and a timeout is a cancel: PL/pgSQL's "when others" does not catch one, so the
-- outcome went down with it. This makes next_lead slow on purpose (a sweep that sits in
-- a trigger) and runs the whole thing under a two-second timeout. If the cancel escapes
-- again, this block fails with "canceling statement due to statement timeout".
select t.reset() \g /dev/null
create or replace function t.slow() returns trigger language plpgsql as $$
begin perform pg_sleep(4); return new; end $$;
create trigger t_slow_sweep before update on attempts for each row
  when (new.auto_logged and old.disposition is null) execute function t.slow();
do $$
declare other bigint;
begin
  -- a call stranded by a dead tab, so the sweep inside next_lead has work to do
  -- (one Zoom really placed, so the sweep's auto-log — where the slow trigger
  -- sits — is the branch it takes, not the not-placed close)
  other := t.dial('B', 'Y');
  update attempts set clicked_at = now() - interval '3 hours',
      call_result = 'not_answered', matched = true where id = other;
  update lead_state set in_progress_since = now() - interval '3 hours',
      last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('Y');
  -- B's tab is the one that died, so it is B's pings that stopped
  update agent_status set updated_at = now() - interval '3 hours' where agent_id = t.uid('B');
  perform t.dial('A', 'X');
end $$;
set statement_timeout = '2s';
do $$
declare att bigint; n jsonb;
begin
  att := (select id from attempts where lead_id = t.lead('X') and agent_id = t.uid('A'));
  n := t.log('A', att, 'not_interested_soft');
  assert (n->>'ok')::boolean and (n->'next'->>'empty')::boolean,
    format('a timeout fetching the next lead still returns the outcome: %s', n);
end $$;
reset statement_timeout;
drop trigger t_slow_sweep on attempts;
drop function t.slow();
do $$
begin
  assert (select disposition = 'not_interested_soft' and disposed_at is not null
            from attempts where lead_id = t.lead('X') and agent_id = t.uid('A')), 'the call stays logged';
  assert (select state = 'resting' from lead_state where lead_id = t.lead('X')), 'and the lead is parked';
end $$;

\echo '33.8 · A call still being made is not written off, and a lead nothing can finish is let go'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- A is thirty-five minutes into a conversation. Their tab is pinging and their tile
  -- still says they are on this lead, so the sweep must leave the whole thing alone.
  perform t.next('A');
  att := t.dial('A', 'X');
  update attempts set clicked_at = now() - interval '35 minutes' where id = att;
  update lead_state set in_progress_since = now() - interval '35 minutes' where lead_id = t.lead('X');
  perform t.as_user('A');
  perform public.heartbeat('ping');
  perform t.next('B');
  assert (select disposition is null from attempts where id = att),
    'a call whose agent is still on it keeps its outcome open';
  assert (select state = 'in_progress' and owner_agent = t.uid('A') from lead_state where lead_id = t.lead('X')),
    'and the lead stays with them';
  assert (select status = 'dialing' from agent_status where agent_id = t.uid('A')),
    'and the board still shows them on the call';
end $$;

select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- the same call, but the tab is gone: nothing has pinged for an hour
  perform t.next('A');
  att := t.dial('A', 'X');
  update attempts set clicked_at = now() - interval '35 minutes' where id = att;
  update lead_state set in_progress_since = now() - interval '35 minutes' where lead_id = t.lead('X');
  update agent_status set updated_at = now() - interval '1 hour' where agent_id = t.uid('A');
  perform t.next('B');
  assert (select state = 'queued' from lead_state where lead_id = t.lead('X')),
    'a dead tab does let the lead go';
end $$;

select t.reset() \g /dev/null
do $$
begin
  -- A lead stuck in progress with no call behind it can never be finished by the
  -- sweep. It must still be let go, or it holds its place in the oldest-few window
  -- and everything behind it waits for ever.
  update lead_state set state = 'in_progress', owner_agent = t.uid('A'),
      in_progress_since = now() - interval '2 hours' where lead_id = t.lead('X');
  perform t.next('B');
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')),
    'a lead with nothing to finish is handed back rather than jamming the sweep';
end $$;

\echo '33.9 · A promise somebody else holds is not served to me'
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  -- Both agents end up holding a scheduled callback on one business. B's lock is the
  -- live one, so A must be given something else: serving A the lead only hands back
  -- one the dial refuses, and the page reloads it again behind the toast.
  insert into callbacks (lead_id, agent_id, due_at, status)
    values (t.lead('X'), t.uid('A'), now() - interval '5 minutes', 'scheduled'),
           (t.lead('X'), t.uid('B'), now() - interval '5 minutes', 'scheduled');
  update lead_state set state = 'callback_locked', owner_agent = t.uid('B') where lead_id = t.lead('X');
  n := t.next('A');
  assert t.name(n) <> 'X', format('A must not be served a lead locked to B, got %s', t.name(n));
  assert (select status = 'scheduled' from callbacks where lead_id = t.lead('X') and agent_id = t.uid('A')),
    'and A''s own promise is left standing';
end $$;

select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  -- but my own callback lock is mine to dial
  insert into callbacks (lead_id, agent_id, due_at, status)
    values (t.lead('X'), t.uid('A'), now() - interval '5 minutes', 'scheduled');
  update lead_state set state = 'callback_locked', owner_agent = t.uid('A') where lead_id = t.lead('X');
  n := t.next('A');
  assert t.name(n) = 'X', format('my own callback still comes to me, got %s', t.name(n));
end $$;

select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  -- and a promise on a lead somebody else's outcome has parked waits for the rest to
  -- end: serving it only let the dial erase their rest
  insert into callbacks (lead_id, agent_id, due_at, status)
    values (t.lead('X'), t.uid('A'), now() - interval '5 minutes', 'scheduled');
  update lead_state set rest_until = now() + interval '5 days' where lead_id = t.lead('X');
  n := t.next('A');
  assert t.name(n) <> 'X', format('a parked lead is not served as a callback, got %s', t.name(n));
end $$;

\echo 'queue fix tests passed'
