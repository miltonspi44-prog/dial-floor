-- 0038: a list built by area code, the first three digits of the number.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '47.1 · A list built by area code takes only the numbers that start with those three digits'
select t.reset() \g /dev/null
do $$
declare v_id bigint; r jsonb;
begin
  insert into leads (source_id, name, phone_norm, phone_display, addr_state, score, review_count)
    values (947, 'Miami Beach Co', '7865550947', '(786) 555-0947', 'FL', 70, 12) returning id into v_id;
  perform refresh_lead(v_id);
  perform t.as_user('M');
  r := public.build_list('786 only', null, '{"area_code":"786"}', 50);
  assert (r->>'count')::int = 1, format('the one 786 number: %s', r);
  assert (select l.phone_norm from list_items li join leads l on l.id = li.lead_id
           where li.list_id = (r->>'list_id')::bigint) = '7865550947', 'and it is that number';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Miami', null, '{"area_code":" 305, 786 "}', 50);
  assert (r->>'count')::int = (select count(*) from leads l join lead_state ls on ls.lead_id = l.id
                                 where ls.state in ('fresh', 'queued') and left(l.phone_norm, 3) in ('305', '786')),
    format('several area codes, spaces forgiven: %s', r);
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Nothing', null, '{"area_code":"212"}', 50);
  assert (r->>'count')::int = 0, 'no 212 numbers here';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('786 high score', null, '{"area_code":"786","min_score":80}', 50);
  assert (r->>'count')::int = 0, 'the other rules still apply (a score of 70 is under 80)';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  perform t.fails('select public.build_list(''bad'', null, ''{"area_code":"30"}'', 50)', 'three digits');
  perform t.fails('select public.build_list(''bad'', null, ''{"area_code":"305;786"}'', 50)', 'three digits');
  perform t.fails('select public.build_list(''bad'', null, ''{"area_code":"105"}'', 50)', 'three digits');
  delete from lead_intents where lead_id = v_id;
  delete from lead_state where lead_id = v_id;
  delete from leads where id = v_id;
end $$;
select t.reset() \g /dev/null
