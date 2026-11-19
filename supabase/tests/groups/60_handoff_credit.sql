-- 0052: a handoff recorded by hand belongs to the agent picked, and counts
-- in their stats as their call and their handoff.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

select t.reset() \g /dev/null

\echo '60.1 · Recorded by hand for the agent who took the callback, not the list''s: it counts in their numbers'
do $$
declare att bigint; r jsonb; v_list bigint; a_before jsonb; b_before jsonb; c record;
begin
  -- A dialed X and got no answer; X is on A's list. B (who shares A's Zoom number) took the callback.
  att := t.dial('A', 'X'); perform t.log('A', att, 'no_answer');
  perform t.as_user('M');
  v_list := (public.build_list('Roofers', t.uid('A'), '{}', 50)->>'list_id')::bigint;
  select jsonb_build_object('dials', dials_today, 'convos', conversations_today, 'handoffs', handoffs_today) into a_before
    from v_floor_today where agent_id = t.uid('A');
  select jsonb_build_object('dials', dials_today, 'convos', conversations_today, 'handoffs', handoffs_today) into b_before
    from v_floor_today where agent_id = t.uid('B');

  r := public.record_handoff(t.lead('X'), 'chance_website', 'called back on the shared number', t.uid('B'));

  assert (select agent_id from handoff_ledger where id = (r->>'handoff_id')::bigint) = t.uid('B'), format('credited to B: %s', r);
  select a.* into c from attempts a where a.id = (r->>'attempt_id')::bigint;
  assert c.agent_id = t.uid('B') and c.lead_id = t.lead('X') and c.disposition = 'chance_website' and c.connected
     and c.matched and c.source = 'callback' and c.call_result like '%recorded by hand%' and c.note = 'called back on the shared number',
    format('logged as B''s call, a chance given, connected, never to be matched to a Zoom call: %s', to_jsonb(c));
  assert (select manual_attempt_id from handoff_ledger where id = (r->>'handoff_id')::bigint) = c.id, 'the handoff knows its call';

  -- the floor board, today
  assert (select handoffs_today from v_floor_today where agent_id = t.uid('B')) = (b_before->>'handoffs')::int + 1
     and (select conversations_today from v_floor_today where agent_id = t.uid('B')) = (b_before->>'convos')::int + 1
     and (select dials_today from v_floor_today where agent_id = t.uid('B')) = (b_before->>'dials')::int + 1,
    'B: one more handoff, conversation and call on the floor board';
  assert (select jsonb_build_object('dials', dials_today, 'convos', conversations_today, 'handoffs', handoffs_today)
            from v_floor_today where agent_id = t.uid('A')) = a_before, 'A, whose list it was, is untouched';
  -- the Dial page's own numbers
  assert (select handoffs from public.floor_pace() where agent_id = t.uid('B')) = 1, 'B''s Dial page counts it';
  assert coalesce((select handoffs from public.floor_pace() where agent_id = t.uid('A')), 0) = 0, 'A''s does not';
  -- the default is still the manager, when no one is named
  r := public.record_handoff(t.lead('Y'), 'sale_closed');
  assert (select agent_id from attempts where id = (r->>'attempt_id')::bigint) = t.uid('M'), 'no agent named: the manager, call and all';
end $$;

\echo '60.2 · A handoff recorded by hand can be given to someone else, its call with it; one logged from a dial cannot'
do $$
declare r jsonb; h bigint; att bigint;
begin
  perform t.as_user('M');
  h := (select id from handoff_ledger where lead_id = t.lead('X'));
  r := public.reassign_handoff(h, t.uid('A'));
  assert r->>'agent_id' = t.uid('A')::text and r ? 'name', format('given to A: %s', r);
  assert (select agent_id from handoff_ledger where id = h) = t.uid('A')
     and (select a.agent_id from attempts a join handoff_ledger l on l.manual_attempt_id = a.id where l.id = h) = t.uid('A'),
    'the handoff and its call both moved';
  assert (select handoffs from public.floor_pace() where agent_id = t.uid('A')) = 1
     and coalesce((select handoffs from public.floor_pace() where agent_id = t.uid('B')), 0) = 0, 'the stats followed';
  perform t.fails(format('select public.reassign_handoff(%s, %L)', h, gen_random_uuid()), 'login does not exist');
  perform t.fails('select public.reassign_handoff(999999, null)', 'does not exist');
  -- a chance given logged on a dial stays with whoever made the call
  att := t.dial('B', 'Z'); perform t.log('B', att, 'chance_website', '{"summary": "on the call", "rating": 4}');
  perform t.as_user('M');
  perform t.fails(format('select public.reassign_handoff(%s, %L)', (select id from handoff_ledger where lead_id = t.lead('Z')), t.uid('A')),
                  'only a handoff recorded by hand');
  perform t.as_user('A');
  perform t.fails(format('select public.reassign_handoff(%s, %L)', h, t.uid('A')), 'manager only');
end $$;

select t.reset() \g /dev/null
