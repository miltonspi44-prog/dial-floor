\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '40.1 · The area code speaks first, the state second, and unknown means unknown (item 21)'
do $$
begin
  assert public.derive_tz('3055550001', 'FL') = 'America/New_York', 'Miami is Eastern';
  assert public.derive_tz('8505550001', 'FL') = 'America/Chicago', 'the panhandle overrides its state';
  assert public.derive_tz('2085551234', null) = 'America/Denver', 'the code alone is enough';
  assert public.derive_tz('6025551234', 'AZ') = 'America/Phoenix', 'Arizona keeps its own clock';
  assert public.derive_tz('0005550000', 'CA') = 'America/Los_Angeles', 'an unknown code leans on the state';
  assert public.derive_tz('0005550000', null) is null, 'nothing known means no answer';
  assert public.derive_tz('0005550000', 'ZZ') is null, 'a made-up state is not an answer either';
  assert not public.local_ok(null), 'and no answer means no lawful hour';
end $$;

\echo '40.2 · A lead whose clock nobody knows is never served and never dialed'
select t.reset() \g /dev/null
do $$
declare v_id bigint; n jsonb;
begin
  insert into leads (source_id, name, phone_norm, phone_display, addr_state, score)
    values (990, 'NOWHERE', '0005550000', '(000) 555-0000', null, 99) returning id into v_id;
  perform refresh_lead(v_id);
  assert (select tz is null from leads where id = v_id), 'its timezone stays unknown';
  -- make it the only lead standing
  update lead_state set rest_until = now() + interval '1 hour' where lead_id <> v_id;
  n := t.next('A');
  assert (n->>'empty')::boolean is true, format('the queue has nothing to serve, got %s', t.name(n));
  perform t.as_user('A');
  perform t.fails(format('select public.start_attempt(%s)', v_id), 'calling window');
  update lead_state set rest_until = null where lead_id <> v_id;
  -- the console sends a state: the lead is callable the moment the clock is known
  update leads set addr_state = 'MA' where id = v_id;
  perform refresh_lead(v_id);
  assert (select tz = 'America/New_York' from leads where id = v_id), 'a usable state brings it back';
  delete from lead_state where lead_id = v_id;
  delete from leads where id = v_id;
end $$;

\echo '40.3 · Every fixture lead got its clock re-read under the new table'
do $$
begin
  assert not exists (select 1 from leads where phone_norm like '305%' and tz <> 'America/New_York'),
    'the 305 leads are Eastern by their code';
end $$;
\echo 'timezone tests passed'
