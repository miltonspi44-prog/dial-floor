\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '38.1 · Rest, the daily cap and the redial gap belong to the business, not the record (item 20)'
-- D1 and D2 are one business scraped twice: same number, two lead rows.
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  -- the gap: D1 was just dialed, so D2 is not servable and not dialable
  perform t.as_user('A');
  att := public.start_attempt(t.lead('D1'))->>'attempt_id';
  perform t.log('A', att, 'no_answer');
  n := t.next('B');
  assert t.name(n) not in ('D1', 'D2'),
    format('the twin cools down with the business, got %s', t.name(n));
  perform t.as_user('B');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('D2')), 'dialed since you loaded it');
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  -- the cap: two calls to the business today, split across its two records
  perform t.as_user('A');
  att := public.start_attempt(t.lead('D1'))->>'attempt_id';
  perform t.log('A', att, 'no_answer');
  update lead_state set last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('D1');
  att := public.start_attempt(t.lead('D2'))->>'attempt_id';  -- A's own last call: no surprise
  perform t.log('A', att, 'no_answer');
  update lead_state set last_attempt_at = now() - interval '3 hours'
   where lead_id in (t.lead('D1'), t.lead('D2'));
  -- two across the pair is the business's two for the day
  n := t.next('B');
  assert t.name(n) not in ('D1', 'D2'),
    format('two calls across the twins cap the business, got %s', t.name(n));
  perform t.as_user('B');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('D1')), 'all its calls for today');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('D2')), 'all its calls for today');
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  -- the rest: a 20-day "not interested" on D1 parks D2 as well
  perform t.as_user('A');
  att := public.start_attempt(t.lead('D1'))->>'attempt_id';
  perform t.log('A', att, 'not_interested_hard');
  n := t.next('B');
  assert t.name(n) not in ('D1', 'D2'),
    format('the business is resting, whichever row you look at, got %s', t.name(n));
  perform t.as_user('B');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('D2')), 'another agent has just been through');
end $$;
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  -- a promise beats the cap and the gap, but not the business's rest — even when
  -- the rest sits on the twin row
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('D2'), t.uid('B'), now() - interval '1 minute');
  update lead_state set state = 'callback_locked', owner_agent = t.uid('B') where lead_id = t.lead('D2');
  update lead_state set rest_until = now() + interval '20 days' where lead_id = t.lead('D1');
  n := t.next('B');
  assert t.name(n) is distinct from 'D2',
    format('B''s promise waits out the twin''s rest, got %s (%s)', t.name(n), n->>'reason');
  -- and the sweep has ridden the promise's due time to the rest's end, so the
  -- stale screen's Dial is refused off the pool rules, same hint to the agent
  assert (select due_at >= now() + interval '19 days' from callbacks where lead_id = t.lead('D2')),
    'the due time rides to the rest''s end';
  perform t.as_user('B');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('D2')), 'press skip for the next one');
end $$;

\echo '38.2 · A callback nobody could keep is unreached or cancelled, never the agent''s miss (item 18)'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- somebody else's wrong number on the twin kills B's promise: cancelled, not missed
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('D2'), t.uid('B'), now() + interval '1 hour');
  update lead_state set state = 'callback_locked', owner_agent = t.uid('B') where lead_id = t.lead('D2');
  perform t.as_user('A');
  att := public.start_attempt(t.lead('D1'))->>'attempt_id';
  perform t.log('A', att, 'wrong_number');
  assert (select status from callbacks where lead_id = t.lead('D2')) = 'cancelled',
    format('the twin''s suppression cancels the promise, got %s',
           (select status from callbacks where lead_id = t.lead('D2')));
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  -- the owner reaches a dead line: cancelled, there is nothing left to call
  perform t.next('A');
  att := t.dial('A', 'X');
  perform t.log('A', att, 'callback', jsonb_build_object('due_at', now() - interval '1 minute'));
  perform t.next('A');
  att := t.dial('A', 'X');
  perform t.log('A', att, 'disconnected');
  assert (select status from callbacks where lead_id = t.lead('X')) = 'cancelled',
    format('a dead number cancels the promise, got %s', (select status from callbacks where lead_id = t.lead('X')));
end $$;

\echo '38.3 · A promise a day past due, never dialed, is missed — and its lead is not stranded'
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('X'), t.uid('A'), now() - interval '26 hours');
  update lead_state set state = 'callback_locked', owner_agent = t.uid('A') where lead_id = t.lead('X');
  perform t.next('B');  -- anyone's next request runs the sweep
  assert (select status from callbacks where lead_id = t.lead('X')) = 'missed',
    format('a day overdue and untried is missed, got %s', (select status from callbacks where lead_id = t.lead('X')));
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')),
    'and the lead it was holding goes back to the queue';
end $$;
select t.reset() \g /dev/null
do $$
begin
  -- not while the lead is mid-call: that call may be the promise being kept
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('X'), t.uid('A'), now() - interval '26 hours');
  update lead_state set state = 'in_progress', owner_agent = t.uid('A'), in_progress_since = now()
   where lead_id = t.lead('X');
  perform t.next('B');
  assert (select status from callbacks where lead_id = t.lead('X')) = 'scheduled',
    'a promise being kept right now is left alone';
end $$;
select t.reset() \g /dev/null
do $$
declare v_rest timestamptz := now() + interval '3 days';
begin
  -- and not while the queue itself refuses to serve it: somebody else's rest on
  -- the business (here on the twin record) blocks B from dialing, so the due
  -- time rides to the rest's end instead of the miss clock running on B
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('D2'), t.uid('B'), now() - interval '26 hours');
  update lead_state set state = 'callback_locked', owner_agent = t.uid('B') where lead_id = t.lead('D2');
  update lead_state set rest_until = v_rest where lead_id = t.lead('D1');
  perform t.next('A');
  assert (select status = 'scheduled' and due_at = v_rest from callbacks where lead_id = t.lead('D2')),
    format('a promise the rest blocks is not B''s miss — it waits for the rest''s end, got %s due %s',
           (select status from callbacks where lead_id = t.lead('D2')),
           (select due_at from callbacks where lead_id = t.lead('D2')));
  -- the rest over, the owner gets their day; ignored past that, it is missed
  update lead_state set rest_until = null where lead_id = t.lead('D1');
  update callbacks set due_at = now() - interval '26 hours' where lead_id = t.lead('D2');
  perform t.next('A');
  assert (select status from callbacks where lead_id = t.lead('D2')) = 'missed',
    'ignored for a day with nothing in the way, it is missed';
end $$;

\echo '38.4 · Deactivating an agent hands their work back by itself (item 25)'
select t.reset() \g /dev/null
do $$
declare v_list bigint;
begin
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('X'), t.uid('A'), now() + interval '2 hours');
  update lead_state set state = 'callback_locked', owner_agent = t.uid('A') where lead_id = t.lead('X');
  insert into lists (name, agent_id, rules) values ('A''s list', t.uid('A'), '{}') returning id into v_list;
  update lead_state set reserved_by = t.uid('A'), reserved_until = now() + interval '5 minutes'
   where lead_id = t.lead('Y');
  -- the manager switches A off — nothing else pressed
  perform t.as_user('M');
  update profiles set active = false where id = t.uid('A');
  assert (select status from callbacks where lead_id = t.lead('X')) = 'requeued',
    format('their promise goes back to the queue, got %s', (select status from callbacks where lead_id = t.lead('X')));
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')),
    'and the lead it locked is free';
  assert (select agent_id is null from lists where id = v_list), 'their list is shared with everyone';
  assert (select reserved_by is null from lead_state where lead_id = t.lead('Y')), 'their hold is dropped';
  update profiles set active = true where id = t.uid('A');
end $$;
\echo 'outcome tests passed'
