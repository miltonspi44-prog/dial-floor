-- Dial Floor · 0050 the list builder offers every state the scraper has leads in
-- The builder's State menu was a fixed list of 27 states, written when the
-- scraper covered the East Coast and a few others. It now has leads in 49 states
-- and DC (Oregon 607, Oklahoma 471, Mississippi, Louisiana, Idaho, Missouri ...),
-- and none of the others could be picked. Like the Trade and Source menus (0041),
-- the State menu now comes from the leads: builder_counts returns 'states', each
-- state with eligible leads counted under every other rule picked (tier, area
-- code, trades, sources, pickups), so a state the scraper starts on appears by
-- itself.
-- DC gets its own row in state_tz (America/New_York). Its leads already had that
-- timezone, from the 202 area code; now the state says so too.
-- Applies through the management API as it is.

insert into public.state_tz (state, tz) values ('DC', 'America/New_York') on conflict (state) do nothing;

-- (0045's, with 'states')
create or replace function public.builder_counts(p_rules jsonb default '{}'::jsonb)
returns jsonb language sql stable set search_path = public as $$
  with elig as (  -- in play, and every rule picked but state, trades, sources and pickups
    select l.id, l.category_key, l.source, l.addr_state, public.pickup_bucket(ls.attempts_total, ls.connects_total) as tries
      from leads l
      join lead_state ls on ls.lead_id = l.id
     where ls.state in ('fresh', 'queued')
       and (ls.rest_until is null or ls.rest_until <= now())
       and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
       and (p_rules->>'tier' is null or l.tier = upper(p_rules->>'tier'))
       and (p_rules->>'area_code' is null
            or left(l.phone_norm, 3) = any (string_to_array(regexp_replace(p_rules->>'area_code', '\s', '', 'g'), ',')))
  ),
  base as (
    select * from elig
     where p_rules->>'state' is null or addr_state = upper(p_rules->>'state')
  ),
  pool as (
    select * from base
     where p_rules->>'tries' is null
        or tries = any (string_to_array(regexp_replace(p_rules->>'tries', '\s', '', 'g'), ','))
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
  ),
  by_tries as (  -- the four pickup options, under the trades and sources picked
    select b.tries as k, count(*) as n
      from base b
     where b.tries is not null
       and (p_rules->>'source' is null or b.source = any (string_to_array(p_rules->>'source', ',')))
       and (p_rules->>'category' is null
            or string_to_array(b.category_key, ',') && string_to_array(p_rules->>'category', ','))
     group by b.tries
  ),
  by_state as (  -- every state with leads, under the trades, sources and pickups picked
    select e.addr_state as k, count(*) as n
      from elig e
     where e.addr_state is not null and e.addr_state <> ''
       and (p_rules->>'tries' is null
            or e.tries = any (string_to_array(regexp_replace(p_rules->>'tries', '\s', '', 'g'), ',')))
       and (p_rules->>'source' is null or e.source = any (string_to_array(p_rules->>'source', ',')))
       and (p_rules->>'category' is null
            or string_to_array(e.category_key, ',') && string_to_array(p_rules->>'category', ','))
     group by e.addr_state
  )
  select jsonb_build_object(
    'trades', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'n', n) order by n desc, k), '[]'::jsonb) from by_trade),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'n', n) order by n desc, k), '[]'::jsonb) from by_source),
    'tries', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'n', n) order by k), '[]'::jsonb) from by_tries),
    'states', (select coalesce(jsonb_agg(jsonb_build_object('key', k, 'n', n) order by k), '[]'::jsonb) from by_state),
    'total', (select count(*) from pool p
               where (p_rules->>'source' is null or p.source = any (string_to_array(p_rules->>'source', ',')))
                 and (p_rules->>'category' is null
                      or string_to_array(p.category_key, ',') && string_to_array(p_rules->>'category', ','))))
$$;
