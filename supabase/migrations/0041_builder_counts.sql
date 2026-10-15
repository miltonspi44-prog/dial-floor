-- Dial Floor · 0041 the list builder's counts follow the rules already picked
-- Pick tier A and the trades offered are the trades tier A actually has, with
-- tier A's counts; pick a trade and the sources narrow the same way. One call
-- gives the trades, the sources and how many leads the rules so far match.
-- The rules are build_list's own (tier, state, area_code, category, source), so
-- what the picker counts is exactly what the build would take.
-- Applies through the management API as it is.
create or replace function public.builder_counts(p_rules jsonb default '{}'::jsonb)
returns jsonb language sql stable set search_path = public as $$
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
$$;
revoke execute on function public.builder_counts(jsonb) from public, anon;
grant execute on function public.builder_counts(jsonb) to authenticated;
