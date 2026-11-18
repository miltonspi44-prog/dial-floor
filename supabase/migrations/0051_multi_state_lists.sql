-- Dial Floor · 0051 a list can take leads from several states
-- A list's state rule took one state, so California and Washington leads could
-- not go in one list. Like trades and sources, the rule now takes one state or
-- several separated by commas ("CA,WA"), and a list takes leads in any of them.
-- build_list refuses a rule that is not two-letter codes; a list saved with one
-- state reads exactly as before. The builder's counts take the same rule, and
-- the State menu still shows every state, so a second one can be added.
-- Applies through the management API as it is.

-- (0045's, with the state rule taking several states)
create or replace function public.build_list(p_name text, p_agent uuid, p_rules jsonb, p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_list bigint; v_count int;
  -- one state or several (CA,WA): spaces and case forgiven, an empty rule is no rule
  v_states text[] := string_to_array(nullif(upper(regexp_replace(coalesce(p_rules->>'state', ''), '\s', '', 'g')), ''), ',');
begin
  if not is_manager() then raise exception 'manager only'; end if;
  if v_states is not null and array_to_string(v_states, ',') !~ '^[A-Z]{2}(,[A-Z]{2})*$' then
    raise exception 'state: a two-letter code, or several separated by commas (CA,WA)';
  end if;
  -- the first three digits of the number: one area code, or several separated by
  -- commas (305,786 for Miami); spaces are forgiven, anything else is refused
  if p_rules->>'area_code' is not null
     and regexp_replace(p_rules->>'area_code', '\s', '', 'g') !~ '^[2-9][0-9]{2}(,[2-9][0-9]{2})*$' then
    raise exception 'area code: three digits, or several separated by commas (305,786)';
  end if;
  if p_rules->>'tries' is not null
     and regexp_replace(p_rules->>'tries', '\s', '', 'g') !~ '^(0|1|2|3\+)(,(0|1|2|3\+))*$' then
    raise exception 'tries: 0 (not yet dialed), 1, 2 or 3+ (no pickup), or several separated by commas';
  end if;
  perform wake_rested();
  insert into lists (name, agent_id, rules, created_by)
    values (p_name, p_agent, p_rules, auth.uid()) returning id into v_list;
  insert into list_items (list_id, lead_id, position)
  select v_list, l.id, row_number() over (order by case when coalesce((p_rules->>'ai_order')::boolean, false) then s.p_win end desc nulls last,
                                                    l.score desc nulls last, l.review_count desc nulls last)
    from leads l
    join lead_state ls on ls.lead_id = l.id
    left join lead_scores s on s.lead_id = l.id
    where ls.state in ('fresh','queued')
      and (ls.rest_until is null or ls.rest_until <= now())
      and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
      -- the lead's state, any of the ones picked
      and (v_states is null or l.addr_state = any (v_states))
      and (p_rules->>'tier' is null or l.tier = upper(p_rules->>'tier'))
      and (p_rules->>'min_score' is null or l.score >= (p_rules->>'min_score')::int)
      and (p_rules->>'intent' is null or exists
            (select 1 from lead_intents li where li.lead_id = l.id and li.intent_key = p_rules->>'intent'))
      and (p_rules->>'phone_type' is null or l.phone_type = p_rules->>'phone_type')
      -- radar card rules: trade keys (any of, comma-separated), city, website, first seen
      and (p_rules->>'category' is null
           or string_to_array(l.category_key, ',') && string_to_array(p_rules->>'category', ','))
      and (p_rules->>'city' is null or lower(l.addr_city) = lower(p_rules->>'city'))
      and (p_rules->>'website_type' is null or l.website_type = p_rules->>'website_type')
      and (p_rules->>'fresh_days' is null
           or l.first_seen >= now() - make_interval(days => (p_rules->>'fresh_days')::int))
      -- where the lead came from: the scraper's source (gmaps, registry, angi, ...), any of
      and (p_rules->>'source' is null
           or l.source = any (string_to_array(regexp_replace(p_rules->>'source', '\s', '', 'g'), ',')))
      -- a number here is ten digits with the area code first
      and (p_rules->>'area_code' is null
           or left(l.phone_norm, 3) = any (string_to_array(regexp_replace(p_rules->>'area_code', '\s', '', 'g'), ',')))
      -- not yet dialed, or dialed 1, 2, 3+ times with no pickup, any of
      and (p_rules->>'tries' is null
           or public.pickup_bucket(ls.attempts_total, ls.connects_total)
              = any (string_to_array(regexp_replace(p_rules->>'tries', '\s', '', 'g'), ',')))
      and not exists (select 1 from list_items li2 join lists ld2 on ld2.id = li2.list_id
                      where li2.lead_id = l.id and ld2.status in ('draft', 'active') and li2.served_at is null)
    -- the same order the positions follow, so a list smaller than the match takes the best of it
    order by case when coalesce((p_rules->>'ai_order')::boolean, false) then s.p_win end desc nulls last,
             l.score desc nulls last, l.review_count desc nulls last, l.id
    limit p_limit;
  get diagnostics v_count = row_count;
  return jsonb_build_object('list_id', v_list, 'count', v_count);
end $$;

-- (0050's, with the state rule taking several states)
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
  base as (  -- any of the states picked
    select * from elig
     where nullif(regexp_replace(coalesce(p_rules->>'state', ''), '\s', '', 'g'), '') is null
        or addr_state = any (string_to_array(upper(regexp_replace(p_rules->>'state', '\s', '', 'g')), ','))
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
  by_state as (  -- every state with leads, under the trades, sources and pickups picked (not the states)
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
