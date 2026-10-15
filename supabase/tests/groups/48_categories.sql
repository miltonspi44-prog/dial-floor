-- 0039: the trades a list can be built from, and a lead taken out of a list by hand.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '48.1 · The builder knows every trade and how many leads each holds; a lead counts under each of its trades'
select t.reset() \g /dev/null
update leads set category_key = 'roofing,siding' where name = 'X';
update leads set category_key = 'roofing' where name = 'Y';
update leads set category_key = null where name not in ('X', 'Y');
do $$
declare c jsonb; r jsonb;
begin
  c := public.lead_categories();
  assert (select (x->>'n')::int from jsonb_array_elements(c) x where x->>'key' = 'roofing') = 2, format('two roofers: %s', c);
  assert (select (x->>'n')::int from jsonb_array_elements(c) x where x->>'key' = 'siding') = 1, format('one of them does siding: %s', c);
  assert jsonb_array_length(c) = 2, format('and nothing else: %s', c);
  perform t.as_user('M');
  r := public.build_list('Siding', null, '{"category":"siding"}', 50);
  assert (r->>'count')::int = 1, 'a list by one trade';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Roof or siding', null, '{"category":"roofing,siding"}', 50);
  assert (r->>'count')::int = 2, 'or by several, any of them';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
end $$;

\echo '48.2 · A manager marks a lead do-not-call from a list: it leaves every queue and the list no longer waits on it'
do $$
declare r jsonb; v_list bigint; s jsonb;
begin
  perform t.as_user('M');
  r := public.build_list('Roofers', t.uid('A'), '{"category":"roofing"}', 50);
  v_list := (r->>'list_id')::bigint;
  assert public.list_outstanding(v_list) = 2, 'two to dial';
  s := public.add_suppression((select phone_display from leads where name = 'X'), 'dnc');
  assert (s->>'leads_suppressed')::int = 1, format('X is suppressed: %s', s);
  assert (select state from lead_state where lead_id = t.lead('X')) = 'suppressed';
  assert public.list_outstanding(v_list) = 1, 'the list no longer waits on X';
  assert (select lead_state from jsonb_to_recordset(public.list_leads(v_list)) as x(lead_id bigint, lead_state text) where lead_id = t.lead('X')) = 'suppressed',
    'and the list view says so';
  assert t.name(t.next('A')) <> 'X', 'A is never served X again';
end $$;
select t.reset() \g /dev/null
update leads set category_key = null;
