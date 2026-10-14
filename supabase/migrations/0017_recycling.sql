-- Dial Floor · 0017 recycling (Phase 2 · B7)
--   Resting leads already rejoin the queue on their own when the rest is over
--   (0006). This brings back what the queue has parked, when the manager says so:
--   · provider: "already has a provider" leads, parked for good until now, come
--     back for a win-back call, tagged with the provider win-back intent
--   · resting: "not interested" and language-barrier leads, before their rest ends
--   · season: resting leads whose trade's season is open now
--   The manager picks the pool and how long ago the leads were parked, sees how
--   many and who, and recycles them, as a shared list if wanted so they're served
--   first. Bringing "has a provider" leads back automatically after N days is an
--   option (recycle_provider_days), off by default: the timing is the manager's.

insert into public.intents_catalog (key, label, description, priority) values
  ('provider_winback', 'Provider win-back', 'Had a provider when we last called: ask how it is going (renewal angle)', 38)
on conflict (key) do nothing;

insert into public.app_settings (key, value) values ('recycle_provider_days', '0')
on conflict (key) do nothing;

-- recycled leads can come back as a shared list; referral leads get one per agent (0021)
alter table public.lists drop constraint if exists lists_kind_check;
alter table public.lists add constraint lists_kind_check check (kind in ('manual', 'radar', 'recycle', 'referrals'));

-- ------------------------------------------------------------------ pools --
-- the leads in a pool, with when (and how) the queue parked them
create or replace function public.recycle_candidates(p_pool text)
returns table (lead_id bigint, parked_at timestamptz, outcome text)
language sql stable security invoker set search_path = public as $$
  select ls.lead_id, coalesce(x.at, ls.updated_at), x.disposition
    from lead_state ls
    join leads l on l.id = ls.lead_id
    left join lateral (
      select coalesce(a.disposed_at, a.clicked_at) as at, a.disposition
        from attempts a
       where a.lead_id = ls.lead_id
         and a.disposition = any (case when p_pool = 'provider' then array['has_provider']
                                       else array['not_interested_soft', 'not_interested_hard', 'language_barrier'] end)
       order by a.clicked_at desc limit 1) x on true
   where p_pool in ('provider', 'resting', 'season')
     and ls.state = case when p_pool = 'provider' then 'provider_list' else 'resting' end
     and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
     and (p_pool <> 'season' or exists (
           select 1 from jsonb_array_elements(coalesce(public.setting('seasons'), '[]'::jsonb)) s
            where extract(month from public.business_date())::int in (select jsonb_array_elements_text(s->'months')::int)
              and public.season_has(s, l.category_key, l.addr_state)))
$$;

-- back in the queue (the rest waived); win-back leads carry the intent
create or replace function public.recycle_leads(p_ids bigint[], p_pool text)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  with u as (
    update lead_state set state = 'queued', rest_until = null, owner_agent = null, updated_at = now()
     where lead_id = any (p_ids) and state in ('provider_list', 'resting')
    returning lead_id
  ), tagged as (
    insert into lead_intents (lead_id, intent_key, confidence, source)
    select u.lead_id, 'provider_winback', 0.9, 'recycle' from u where p_pool = 'provider'
    on conflict (lead_id, intent_key) do update set confidence = excluded.confidence, source = 'recycle', computed_at = now()
    returning 1
  )
  select count(*) into v_n from u;
  return v_n;
end $$;

-- the automatic option rides the same wake-up that ends rests (every next_lead)
create or replace function public.wake_rested()
returns void language plpgsql security definer set search_path = public as $$
declare v_days int := coalesce((public.setting('recycle_provider_days'))::int, 0);
begin
  update lead_state set state = 'queued', updated_at = now()
   where lead_id in (select lead_id from lead_state
                      where state = 'resting' and (rest_until is null or rest_until <= now())
                      for update skip locked);
  if v_days > 0 then
    perform public.recycle_leads(array(select rc.lead_id from public.recycle_candidates('provider') rc
                                        where rc.parked_at <= now() - make_interval(days => v_days)), 'provider');
  end if;
end $$;

-- ------------------------------------------------------------ manager API --
create or replace function public.recycle_pools()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare r jsonb;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  with pools(ord, pool) as (values (1, 'provider'), (2, 'resting'), (3, 'season')),
  c as (select p.pool, rc.parked_at, rc.outcome
          from pools p cross join lateral public.recycle_candidates(p.pool) rc)
  select jsonb_build_object(
    'auto_provider_days', coalesce((public.setting('recycle_provider_days'))::int, 0),
    'pools', jsonb_agg(jsonb_build_object(
      'pool', p.pool,
      'total', (select count(*) from c where c.pool = p.pool),
      -- parked at least this long ago
      'ages', jsonb_build_object(
        '30', (select count(*) from c where c.pool = p.pool and c.parked_at <= now() - interval '30 days'),
        '90', (select count(*) from c where c.pool = p.pool and c.parked_at <= now() - interval '90 days'),
        '180', (select count(*) from c where c.pool = p.pool and c.parked_at <= now() - interval '180 days'),
        '365', (select count(*) from c where c.pool = p.pool and c.parked_at <= now() - interval '365 days')),
      'outcomes', (select coalesce(jsonb_object_agg(o, n), '{}'::jsonb)
                     from (select coalesce(c.outcome, 'unknown') as o, count(*) as n
                             from c where c.pool = p.pool group by 1) x)) order by p.ord))
    into r
    from pools p;
  return r;
end $$;

create or replace function public.recycle_preview(p_pool text, p_min_days int default 0)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare r jsonb;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  with c as (
    select rc.* from public.recycle_candidates(p_pool) rc
     where rc.parked_at <= now() - make_interval(days => greatest(0, coalesce(p_min_days, 0))))
  select jsonb_build_object(
    'count', (select count(*) from c),
    'sample', (select coalesce(jsonb_agg(jsonb_build_object(
                  'lead_id', l.id, 'name', l.name, 'trade', l.category, 'city', l.addr_city, 'state', l.addr_state,
                  'outcome', c.outcome, 'parked_at', c.parked_at) order by c.parked_at), '[]'::jsonb)
                 from (select * from c order by parked_at limit 8) c join leads l on l.id = c.lead_id))
    into r;
  return r;
end $$;

create or replace function public.recycle(p_pool text, p_min_days int default 0, p_as_list boolean default false,
                                          p_limit int default 500)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ids bigint[];
  v_n int;
  v_list bigint;
  v_listed int := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_pool is null or p_pool not in ('provider', 'resting', 'season') then raise exception 'unknown pool'; end if;
  v_ids := array(select rc.lead_id from public.recycle_candidates(p_pool) rc
                  where rc.parked_at <= now() - make_interval(days => greatest(0, coalesce(p_min_days, 0)))
                  order by rc.parked_at
                  limit greatest(1, least(coalesce(p_limit, 500), 2000)));
  v_n := public.recycle_leads(v_ids, p_pool);

  if p_as_list and v_n > 0 then
    insert into lists (name, agent_id, rules, created_by, kind, list_date)
      values (case p_pool when 'provider' then 'Win-back' when 'season' then 'In season, recycled' else 'Recycled' end
                || ' · ' || to_char(public.business_date(), 'Dy Mon FMDD'),
              null, jsonb_build_object('recycle', p_pool, 'min_days', p_min_days), auth.uid(), 'recycle', public.business_date())
      returning id into v_list;
    insert into list_items (list_id, lead_id, position)
    select v_list, x.id, x.ord
      from unnest(v_ids) with ordinality x(id, ord)
      join lead_state ls on ls.lead_id = x.id and ls.state = 'queued'
     where not exists (select 1 from list_items li join lists ld on ld.id = li.list_id
                        where li.lead_id = x.id and ld.status = 'active' and li.served_at is null);
    get diagnostics v_listed = row_count;
  end if;
  return jsonb_build_object('recycled', v_n, 'list_id', v_list, 'listed', v_listed);
end $$;

-- ---------------------------------------------------------------- API surface --
-- recycle_candidates only reads what every signed-in user can read; the write stays internal
revoke execute on function public.recycle_leads(bigint[], text) from public, anon, authenticated;
revoke execute on function public.recycle_candidates(text), public.recycle_pools(), public.recycle_preview(text, int),
  public.recycle(text, int, boolean, int) from public, anon;
grant execute on function public.recycle_candidates(text), public.recycle_pools(), public.recycle_preview(text, int),
  public.recycle(text, int, boolean, int) to authenticated;
