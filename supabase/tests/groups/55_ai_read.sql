-- 0046: the AI reads everything on the floor, writes nothing, and reaches no secret.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  att := t.att('A', 'X', 'not_interested_soft', true, 60);
  update attempts set note = 'Owner says his nephew builds sites' where id = att;
end $$;

\echo '55.1 · It reads leads, calls and notes by name, past row security'
do $$
declare r jsonb;
begin
  r := public.ai_sql($q$
    select l.name, l.phone_display, a.disposition, a.note
      from attempts a join leads l on l.id = a.lead_id
     order by a.id desc limit 5;$q$);
  assert (r->>'count')::int = 1 and r->'rows'->0->>'name' = 'X' and r->'rows'->0->>'note' like '%nephew%',
    format('the lead, the call and the agent''s note: %s', r);
  assert not (r->>'truncated')::boolean, 'not cut short';
  r := public.ai_sql('select n from generate_series(1, 500) n');
  assert (r->>'count')::int = 200 and (r->>'truncated')::boolean and jsonb_array_length(r->'rows') = 200, 'at most 200 rows, and it says so';
  r := public.ai_sql('with s as (select count(*) as n from leads) select n from s');
  assert (r->'rows'->0->>'n')::int = (select count(*) from leads), 'WITH queries too';
end $$;

\echo '55.2 · It cannot write: not a statement, not a write tucked in a WITH, not a function that writes'
-- a function anyone may call that writes, run with its owner's rights: only the
-- read-only transaction stands between it and the table
create function t.writer() returns int language sql security definer as $$
  update public.leads set name = 'hacked' where name = 'X' returning 1 $$;
grant execute on function t.writer() to public;
do $$
begin
  perform t.fails($q$select public.ai_sql('update leads set name = ''hacked''')$q$, 'starting with SELECT or WITH');
  perform t.fails($q$select public.ai_sql('with x as (update leads set name = ''hacked'' returning id) select * from x')$q$, 'data-modifying');
  perform t.fails($q$select public.ai_sql('select t.writer()')$q$, 'read-only transaction');
  assert not exists (select 1 from leads where name = 'hacked'), 'nothing changed';
end $$;
drop function t.writer();

\echo '55.3 · Logins and secrets are out of reach'
do $$
begin
  perform t.fails($q$select public.ai_sql('select * from auth.users')$q$, 'permission denied');
end $$;
do $$
declare s text := public.ai_schema();
begin
  assert s like '%leads(%name text%' and s like '%attempts(%note text%', format('its map of the floor: %s', left(s, 300));
  assert s not like '%auth.%' and s not like '%users(%', 'and nothing outside it';
end $$;

\echo '55.4 · Only the server calls it'
set role authenticated;
do $$
begin
  perform t.as_user('M');
  perform t.fails($q$select public.ai_sql('select 1')$q$, 'permission denied');
  perform t.fails('select public.ai_schema()', 'permission denied');
end $$;
reset role;
set role service_role;
select (public.ai_sql('select 1 as one')->'rows'->0->>'one')::int = 1 as service_role_reads \gset
reset role;
\if :service_role_reads
\else
  \echo 'service_role could not read'
  select 1/0;
\endif

select t.reset() \g /dev/null
