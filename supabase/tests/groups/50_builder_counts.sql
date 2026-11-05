-- 0041: the builder's counts follow the rules picked so far.
-- 0044: they come back inside the request's time, and row security asks the
-- login question once a statement.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '50.1 · Pick a tier and the trades offered are that tier''s, with that tier''s counts; the sources narrow by trade'
select t.reset() \g /dev/null
update leads set tier = 'B', category_key = null, source = 'gmaps';
update leads set tier = 'A', category_key = 'roofing,siding', source = 'registry' where name = 'X';
update leads set tier = 'A', category_key = 'roofing' where name = 'Y';
update leads set tier = 'B', category_key = 'roofing' where name = 'Z';
do $$
declare c jsonb;
begin
  perform t.as_user('M');
  c := public.builder_counts('{}');
  assert (select (x->>'n')::int from jsonb_array_elements(c->'trades') x where x->>'key' = 'roofing') = 3, format('three roofers in all: %s', c);
  assert (c->>'total')::int = (select count(*) from leads), 'no rules, the whole pool';
  c := public.builder_counts('{"tier":"A"}');
  assert (select (x->>'n')::int from jsonb_array_elements(c->'trades') x where x->>'key' = 'roofing') = 2, format('two of them are tier A: %s', c);
  assert (select (x->>'n')::int from jsonb_array_elements(c->'trades') x where x->>'key' = 'siding') = 1, 'one of those does siding';
  assert (c->>'total')::int = 2, 'tier A alone is two leads';
  c := public.builder_counts('{"tier":"A","category":"siding"}');
  assert (c->>'total')::int = 1 and (select (x->>'n')::int from jsonb_array_elements(c->'sources') x where x->>'key' = 'registry') = 1
     and not exists (select 1 from jsonb_array_elements(c->'sources') x where x->>'key' = 'gmaps'),
    format('tier A siding is one lead, from the registry, so gmaps is no longer offered: %s', c);
  c := public.builder_counts('{"source":"gmaps"}');
  assert (select (x->>'n')::int from jsonb_array_elements(c->'trades') x where x->>'key' = 'roofing') = 2, 'and the trades narrow by source the same way';
  assert (public.build_list('Check', null, '{"tier":"A","category":"siding"}', 50)->>'count')::int = (public.builder_counts('{"tier":"A","category":"siding"}')->>'total')::int,
    'the count promised is the count built';
end $$;
select t.reset() \g /dev/null
update leads set tier = null, category_key = null, source = null;

\echo '50.2 · The counts are for active logins, agents included: the same door the tables themselves have'
select t.as_user(null) \g /dev/null
do $$
begin
  perform t.fails('select public.builder_counts(''{}'')', 'not signed in');
  perform t.as_user('A');
  assert (public.builder_counts('{}')->>'total')::int = (select count(*) from leads), 'an agent can see the pool';
  update profiles set active = false where id = t.uid('A');
  perform t.fails('select public.builder_counts(''{}'')', 'not switched on');
  update profiles set active = true where id = t.uid('A');
end $$;

\echo '50.3 · Row security asks the login question once a statement, not once a row'
do $$
declare bad text;
begin
  -- a bare is_active() or is_manager() in a policy runs again for every row the
  -- statement reads; written (select is_active()) it runs once. The catalog
  -- spells the wrapped form "( SELECT is_active() AS is_active)".
  select string_agg(tablename || '.' || policyname, ', ' order by tablename, policyname) into bad
    from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~ '(?<!SELECT )(public\.)?is_(active|manager)\(\)';
  assert bad is null, format('these policies ask per row; write the check as (select is_active()): %s', bad);
  assert (select count(*) from pg_policies where schemaname = 'public' and qual ~ 'SELECT is_active\(\)') > 10,
    'the wrapped form is what the catalog shows';
end $$;
