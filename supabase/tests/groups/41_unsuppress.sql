\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '41.1 · A record suppressed for a bad number comes back when the console fixes the number (item 22)'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  perform t.next('A');
  att := t.dial('A', 'X');
  perform t.log('A', att, 'wrong_number');
  assert (select state = 'suppressed' from lead_state where lead_id = t.lead('X')), 'dead, as logged';
  -- the console's next pull carries a corrected number (the sync upserts, then refreshes)
  update leads set phone_norm = '3055550077', phone_display = '(305) 555-0077' where id = t.lead('X');
  perform refresh_lead(t.lead('X'));
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')),
    format('a fixed number is callable again, got %s', (select state from lead_state where lead_id = t.lead('X')));
  assert (select writeback_done and writeback_status is null from lead_state where lead_id = t.lead('X')),
    'and the stale "wrong number" is not pushed at the fixed record';
  update leads set phone_norm = '3055550001', phone_display = '(305) 555-0001' where id = t.lead('X');
  perform refresh_lead(t.lead('X'));
  assert (select state = 'suppressed' from lead_state where lead_id = t.lead('X')),
    'while the old number comes straight back off the shelf if it returns';
end $$;

\echo '41.2 · Do-not-call travels with the number, and a sale is for ever'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  perform t.next('A');
  att := t.dial('A', 'Y');
  perform t.log('A', att, 'dnc');
  perform refresh_lead(t.lead('Y'));
  assert (select state = 'suppressed' from lead_state where lead_id = t.lead('Y')),
    'the number unchanged, the do-not-call holds';
  -- the number really changed: the person who asked is not at the new number
  update leads set phone_norm = '3055550088', phone_display = '(305) 555-0088' where id = t.lead('Y');
  perform refresh_lead(t.lead('Y'));
  assert (select state = 'queued' from lead_state where lead_id = t.lead('Y')),
    'a different number is a different phone';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  perform t.next('A');
  att := t.dial('A', 'Z');
  perform t.log('A', att, 'sale_closed', '{"summary":"sold","rating":5}');
  update leads set phone_norm = '3055550066', phone_display = '(305) 555-0066' where id = t.lead('Z');
  perform refresh_lead(t.lead('Z'));
  assert (select state = 'handoff' from lead_state where lead_id = t.lead('Z')),
    format('sold stays sold whatever the number does, got %s', (select state from lead_state where lead_id = t.lead('Z')));
end $$;
\echo 'unsuppress tests passed'
