-- 0042: a chance given off the phone, recorded by hand from a list.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '51.1 · A lead that called back and gave a chance is handed off by hand: ledger, hold on the number, console told, out of every list'
select t.reset() \g /dev/null
set role authenticated;
do $$
declare att bigint; r jsonb; v_list bigint;
begin
  perform set_config('role', 'postgres', true);  -- the bookkeeping reads below are the test's own
  -- A dialed X yesterday and got no answer; D1 and D2 are one business on one number
  att := t.dial('A', 'X'); perform t.log('A', att, 'no_answer');
  perform t.as_user('M');
  v_list := (public.build_list('Roofers', t.uid('A'), '{}', 50)->>'list_id')::bigint;
  perform t.fails(format('select public.record_handoff(%s, ''dance'')', t.lead('X')), 'chance_website or sale_closed');
  r := public.record_handoff(t.lead('X'), 'chance_website', 'called back, wants the site', t.uid('A'));
  assert (select kind from handoff_ledger where id = (r->>'handoff_id')::bigint) = 'chance_website', format('on the ledger: %s', r);
  assert (select agent_id from handoff_ledger where id = (r->>'handoff_id')::bigint) = t.uid('A'), 'credited to A';
  assert (select state from lead_state where lead_id = t.lead('X')) = 'handoff', 'handed off';
  assert (select writeback_status from lead_state where lead_id = t.lead('X')) = 'captured'
     and not (select writeback_done from lead_state where lead_id = t.lead('X')), 'the console will be told it was captured';
  assert exists (select 1 from suppression where phone_norm = (select phone_norm from leads where name = 'X') and reason = 'handoff_website'),
    'the number is held';
  assert public.list_outstanding(v_list) = (select count(*) from list_items where list_id = v_list) - 1, 'the list no longer waits on X';
  assert t.name(t.next('A')) <> 'X', 'A is never served X again';
  perform t.as_user('M');
  perform t.fails(format('select public.record_handoff(%s, ''chance_website'')', t.lead('X')), 'already handed off');
  -- the twin business: the other record leaves the queue too, and the manager is the default credit
  r := public.record_handoff(t.lead('D1'), 'sale_closed');
  assert (select agent_id from handoff_ledger where id = (r->>'handoff_id')::bigint) = t.uid('M'), 'credited to the manager by default';
  assert (select state from lead_state where lead_id = t.lead('D2')) = 'suppressed', 'the twin record is out of the queue';
  assert (select writeback_status from lead_state where lead_id = t.lead('D2')) = 'captured', 'and the console hears about it too';
  perform t.as_user('A');
  perform t.fails(format('select public.record_handoff(%s, ''chance_website'')', t.lead('Y')), 'manager only');
end $$;
reset role;
select t.reset() \g /dev/null
