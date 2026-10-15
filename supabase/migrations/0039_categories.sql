-- Dial Floor · 0039 the list builder groups by trade
-- The builder already takes a category rule (any of a lead's trade keys); what
-- it lacked was a way to see which trades exist and how many leads each holds.
-- lead_categories() lists every trade key with its dialable count, a lead
-- counting under each of its trades. Applies through the management API as it is.
create or replace function public.lead_categories()
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', x.k, 'n', x.n) order by x.n desc, x.k), '[]'::jsonb)
    from (select k, count(*) as n
            from leads l
            join lead_state ls on ls.lead_id = l.id
            cross join lateral unnest(string_to_array(l.category_key, ',')) as k
           where ls.state in ('fresh', 'queued') and k <> ''
           group by k) x
$$;
revoke execute on function public.lead_categories() from public, anon;
grant execute on function public.lead_categories() to authenticated;
