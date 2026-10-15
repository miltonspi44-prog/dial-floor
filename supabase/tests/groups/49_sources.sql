-- 0040: a list built by where the lead came from.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '49.1 · The builder knows every source and how many leads each holds, and takes any of them as a rule'
select t.reset() \g /dev/null
update leads set source = 'gmaps';
update leads set source = 'registry' where name in ('X', 'Y');
update leads set source = 'angi' where name = 'Z';
do $$
declare c jsonb; r jsonb;
begin
  c := public.lead_sources();
  assert (select (x->>'n')::int from jsonb_array_elements(c) x where x->>'key' = 'registry') = 2, format('two from the registry: %s', c);
  assert (select (x->>'n')::int from jsonb_array_elements(c) x where x->>'key' = 'angi') = 1, format('one from Angi: %s', c);
  perform t.as_user('M');
  r := public.build_list('Registry', null, '{"source":"registry"}', 50);
  assert (r->>'count')::int = 2, format('a list by one source: %s', r);
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Registry or Angi', null, '{"source":" registry, angi "}', 50);
  assert (r->>'count')::int = 3, format('or several, spaces forgiven: %s', r);
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Yelp', null, '{"source":"yelp"}', 50);
  assert (r->>'count')::int = 0, 'nothing from Yelp here';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Registry 305', null, '{"source":"registry","area_code":"305"}', 50);
  assert (r->>'count')::int = 2, 'combined with the other rules';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
end $$;
select t.reset() \g /dev/null
update leads set source = null;
