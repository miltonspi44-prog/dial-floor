-- Dial Floor · 0044 the builder's counts come back; row security asks once
-- The Trade and Source dropdowns on the Lists tab sat empty, and nothing picked
-- in the builder changed them: builder_counts() (0041) was taking longer than
-- the eight seconds a browser request is allowed ("canceling statement due to
-- statement timeout", dozens an hour in the logs), and the page heard nothing
-- back. Two things made it slow, and both are fixed here, because the second is
-- shared by every report that scans the leads under a login.
--
--  · Every read policy says `using (is_active())`. Postgres checks a policy for
--    each row it reads, and a bare function call in it runs again for each of
--    those rows: 35,000 leads, 35,000 lead states and the suppression list meant
--    some 70,000 lookups of the caller's profile per count before any counting.
--    Written `(select is_active())` the planner runs it once per statement and
--    holds rows against the answer. Same meaning, and the same gain for radar()
--    and everything else that reads the leads as the signed-in user. Every
--    policy in the schema gets the wrap, found through the catalog so none is
--    missed, and group 50 holds the line for policies written later.
--  · builder_counts() was a SQL function, which is planned once without looking
--    at the rules it was called with, and that plan held every lead up against
--    the whole suppression list one row at a time. It is plpgsql now, planned
--    for the rules in hand, and runs as the definer the way build_list does, so
--    the pool it counts is the pool the build takes. Still for active logins
--    only, as the tables it reads always were.
-- Applies through the management API as it is.

-- ------------------------------------------------------------- policies --
do $$
declare
  r record;
  v_using text;
  v_check text;
  -- the call as the catalog spells it, unless it is already inside a (select …)
  pat constant text := '(?<!SELECT )((?:public\.)?is_(?:active|manager)\(\))';
begin
  for r in
    select schemaname, tablename, policyname, qual, with_check
      from pg_policies
     where schemaname = 'public'
       and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~ pat
     order by tablename, policyname
  loop
    v_using := regexp_replace(r.qual, pat, '(select \1)', 'g');
    v_check := regexp_replace(r.with_check, pat, '(select \1)', 'g');
    execute format('alter policy %I on %I.%I %s %s',
      r.policyname, r.schemaname, r.tablename,
      case when v_using is not null then 'using (' || v_using || ')' else '' end,
      case when v_check is not null then 'with check (' || v_check || ')' else '' end);
  end loop;
end $$;

-- -------------------------------------------------------- builder_counts --
-- (0041's counts, same shape: trades narrowed by the sources picked, sources
--  narrowed by the trades picked, and the total under every rule at once)
create or replace function public.builder_counts(p_rules jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer
set search_path = public
-- planned for the rules in hand: a plan made blind to them compares every lead
-- against the whole suppression list one row at a time
set plan_cache_mode = force_custom_plan
as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_active() then raise exception 'your login is not switched on yet'; end if;
  return (
    with pool as (
      select l.id, l.category_key, l.source
        from leads l
        join lead_state ls on ls.lead_id = l.id
       where ls.state in ('fresh', 'queued')
         and (ls.rest_until is null or ls.rest_until <= now())
         and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
         and (p_rules->>'state' is null or l.addr_state = upper(p_rules->>'state'))
         and (p_rules->>'tier' is null or l.tier = upper(p_rules->>'tier'))
         and (p_rules->>'area_code' is null
              or left(l.phone_norm, 3) = any (string_to_array(regexp_replace(p_rules->>'area_code', '\s', '', 'g'), ',')))
    ),
    by_trade as (  -- trades, narrowed by the sources picked
      select k, count(*) as n
        from pool p cross join lateral unnest(string_to_array(p.category_key, ',')) as k
       where k <> ''
         and (p_rules->>'source' is null or p.source = any (string_to_array(p_rules->>'source', ',')))
       group by k
    ),
    by_source as (  -- sources, narrowed by the trades picked
      select p.source as k, count(*) as n
        from pool p
       where p.source is not null and p.source <> ''
         and (p_rules->>'category' is null
              or string_to_array(p.category_key, ',') && string_to_array(p_rules->>'category', ','))
       group by p.source
    )
    select jsonb_build_object(
      'trades', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'n', n) order by n desc, k), '[]'::jsonb) from by_trade),
      'sources', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'n', n) order by n desc, k), '[]'::jsonb) from by_source),
      'total', (select count(*) from pool p
                 where (p_rules->>'source' is null or p.source = any (string_to_array(p_rules->>'source', ',')))
                   and (p_rules->>'category' is null
                        or string_to_array(p.category_key, ',') && string_to_array(p_rules->>'category', ','))))
  );
end $$;
revoke execute on function public.builder_counts(jsonb) from public, anon;
grant execute on function public.builder_counts(jsonb) to authenticated;
