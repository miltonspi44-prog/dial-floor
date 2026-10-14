-- Dial Floor · 0012 radar (Phase 1.5)
--   · C4 missed-call detector: a business that hasn't picked up on 4+ tries during
--     its own business hours, and never had a live conversation, gets the
--     never_answers intent (the AI-receptionist list), with those tries as the
--     agent's proof ("I tried you four times this week during work hours")
--   · C3 radar v1: once per business day the pool is ranked (intent strength
--     weighted by what is converting this month, freshness, the scraper's score,
--     attempt history) and each active agent is dealt their best N as a "Radar"
--     list; seasonal windows (the lead-scraping plan, section 7) tag in-season
--     leads; the manager's Radar tab shows callbacks due, fresh no-website
--     clusters, the never-answers list, seasons and what is converting

insert into public.app_settings (key, value) values
  ('missed_call_threshold', '4'),
  ('business_hours',        '{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}'),
  ('radar_deal_per_agent',  '100'),
  ('seasons', '[
    {"label":"Decks, fencing, concrete & paving","keys":["decks_fencing","concrete_masonry","pressure_washing"],"months":[2,3,4,5]},
    {"label":"Roofing & siding (storm season)","keys":["roofing","siding"],"months":[5,6,7,8,9]},
    {"label":"Interior trades before winter","keys":["remodeling","flooring","drywall_paint","tiling"],"months":[9,10,11]},
    {"label":"Snow removal (northern states)","keys":["snow_removal"],"months":[9,10,11],
     "states":["WI","MI","IL","IN","NY","MA","NH","ME","CT","RI","PA","OH","NJ","WA"]},
    {"label":"Holiday lighting","keys":["christmas_lights"],"months":[9,10]}
  ]')
on conflict (key) do nothing;

alter table public.lists add column if not exists kind text not null default 'manual'
  check (kind in ('manual', 'radar'));

-- ------------------------------------------------------------------- C4 --
-- the tries that count: rang out or went to voicemail (never a live conversation),
-- placed inside the lead's business hours on its own clock
create or replace function public.missed_tries(p_lead_id bigint)
returns table (clicked_at timestamptz)
language sql stable set search_path = public as $$
  with h as (
    select coalesce(public.setting('business_hours'),
                    '{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}'::jsonb) as v
  )
  select a.clicked_at
    from attempts a
    join leads l on l.id = a.lead_id
    cross join h
   where a.lead_id = p_lead_id
     and not coalesce(a.connected, false)
     and (a.disposition in ('no_answer', 'voicemail')
          or (a.disposition is null and a.call_result = 'not_answered'))
     and extract(isodow from a.clicked_at at time zone coalesce(l.tz, 'America/New_York'))::int
           in (select jsonb_array_elements_text(h.v->'days')::int)
     and (a.clicked_at at time zone coalesce(l.tz, 'America/New_York'))::time
           between (h.v->>'start')::time and (h.v->>'end')::time
$$;

-- ------------------------------------------------------------ refresh_lead --
-- (0005's, with the C4 rule for never_answers)
create or replace function public.refresh_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  l leads%rowtype;
  st lead_state%rowtype;
begin
  select * into l from leads where id = p_lead_id;
  if not found then return; end if;

  update leads set tz = derive_tz(l.phone_norm, l.addr_state) where id = l.id;

  insert into lead_state (lead_id, state)
  values (l.id, 'queued')
  on conflict (lead_id) do nothing;
  select * into st from lead_state where lead_id = l.id;

  -- suppression wins over everything, forever (a handoff keeps its own state)
  if exists (select 1 from suppression s where s.phone_norm = l.phone_norm) then
    update lead_state set state = 'suppressed', owner_agent = null, reserved_by = null,
        reserved_until = null, updated_at = now()
      where lead_id = l.id and state not in ('suppressed', 'handoff');
    update callbacks set status = 'missed' where lead_id = l.id and status = 'scheduled';
    return;
  end if;

  delete from lead_intents where lead_id = l.id and source = 'auto';
  insert into lead_intents (lead_id, intent_key, confidence, source)
  select l.id, k, c, 'auto' from (values
    ('no_website',      case when l.website_type = 'none' then 1.0 end),
    ('social_only',     case when l.website_type = 'social' then 1.0 end),
    ('free_subdomain',  case when l.platform_detail like 'free-subdomain%' then 1.0 end),
    ('cheap_builder',   case when l.platform in ('wix','godaddy','weebly','duda') then 0.9 end),
    ('broken_site',     case when l.platform = 'unreachable' or l.website_type = 'unreachable' then 0.9 end),
    ('fresh_listing',   case when l.first_seen > now() - interval '30 days' then 0.8 end),
    ('review_rich',     case when l.review_count between 20 and 150 and coalesce(l.rating, 0) >= 4 then 0.9 end),
    ('reputation_risk', case when l.review_count >= 10 and l.rating < 3.8 then 0.8 end),
    ('owner_mobile',    case when l.phone_type = 'mobile' then 0.9 end),
    ('multi_trade',     case when coalesce(array_length(l.categories, 1), 0) >= 3 then 0.7 end),
    ('ad_spend',        case when (l.extras->>'sponsored') in ('true','1') then 0.8 end),
    ('badge_holder',    case when (l.extras->>'guaranteed') in ('true','1') then 0.7 end),
    -- C4: no pickup on N+ tries during their own business hours, and never a live conversation
    ('never_answers',   case when st.connects_total = 0
                              and (select count(*) from missed_tries(l.id))
                                  >= coalesce((public.setting('missed_call_threshold'))::int, 4) then 0.9 end)
  ) v(k, c)
  where c is not null
  on conflict (lead_id, intent_key) do update set confidence = excluded.confidence, computed_at = now();
end $$;

-- -------------------------------------------------------------- build_list --
-- (0006's, with the rules the radar cards build lists from)
create or replace function public.build_list(p_name text, p_agent uuid, p_rules jsonb, p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_list bigint; v_count int;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  perform wake_rested();
  insert into lists (name, agent_id, rules, created_by)
    values (p_name, p_agent, p_rules, auth.uid()) returning id into v_list;
  insert into list_items (list_id, lead_id, position)
  select v_list, l.id, row_number() over (order by l.score desc nulls last, l.review_count desc nulls last)
    from leads l
    join lead_state ls on ls.lead_id = l.id
    where ls.state in ('fresh','queued')
      and (ls.rest_until is null or ls.rest_until <= now())
      and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
      and (p_rules->>'state' is null or l.addr_state = upper(p_rules->>'state'))
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
      and not exists (select 1 from list_items li2 join lists ld2 on ld2.id = li2.list_id
                      where li2.lead_id = l.id and ld2.status = 'active' and li2.served_at is null)
    limit p_limit;
  get diagnostics v_count = row_count;
  return jsonb_build_object('list_id', v_list, 'count', v_count);
end $$;

-- ---------------------------------------------------------- build_workspace --
-- (0011's, with the C4 proof)
create or replace function public.build_workspace(p_lead_id bigint, p_reason text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l jsonb; st jsonb; ints jsonb; hist jsonb; ab jsonb; missed jsonb;
begin
  select to_jsonb(x) into l from (select * from leads where id = p_lead_id) x;
  select to_jsonb(x) into st from (select * from lead_state where lead_id = p_lead_id) x;
  select coalesce(jsonb_agg(jsonb_build_object('key', li.intent_key, 'label', ic.label, 'confidence', li.confidence) order by ic.priority), '[]')
    into ints
    from lead_intents li join intents_catalog ic on ic.key = li.intent_key
    where li.lead_id = p_lead_id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'at', a.clicked_at, 'agent', p.name, 'disposition', a.disposition,
      'duration', a.duration_seconds, 'note', a.note,
      'ai_summary', a.ai_summary->>'summary', 'next_steps', a.ai_summary->>'next_steps',
      'taps', (select coalesce(jsonb_agg(jsonb_build_object('objection', x.objection, 'counters', x.counters)
                                         order by x.objection), '[]'::jsonb)
                 from (select b.objection,
                              coalesce(jsonb_agg(distinct ct.counter) filter (where ct.counter is not null), '[]'::jsonb) as counters
                         from card_taps ct join battlecards b on b.id = ct.card_id
                        where ct.attempt_id = a.id
                        group by b.objection) x)) order by a.clicked_at desc), '[]')
    into hist
    from (select * from attempts where lead_id = p_lead_id order by clicked_at desc limit 5) a
    join profiles p on p.id = a.agent_id;
  ab := ab_opener(p_lead_id);
  -- C4 proof: the tries they didn't pick up, on their clock (latest first)
  if exists (select 1 from lead_intents where lead_id = p_lead_id and intent_key = 'never_answers') then
    select jsonb_build_object('count', (select count(*) from missed_tries(p_lead_id)),
                              'times', coalesce(jsonb_agg(m.clicked_at order by m.clicked_at desc), '[]'::jsonb))
      into missed
      from (select clicked_at from missed_tries(p_lead_id) order by clicked_at desc limit 6) m;
  end if;
  return jsonb_build_object('reason', p_reason, 'lead', l, 'state', st, 'intents', ints, 'history', hist)
      || case when ab is null then '{}'::jsonb else jsonb_build_object('ab', ab) end
      || case when missed is null then '{}'::jsonb else jsonb_build_object('missed', missed) end;
end $$;

-- ------------------------------------------------------------------- C3 --
-- does a season (from app_settings.seasons) cover this trade and state?
create or replace function public.season_has(s jsonb, p_category_key text, p_state text)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(string_to_array(p_category_key, ',') && array(select jsonb_array_elements_text(s->'keys')), false)
     and (s->'states' is null or coalesce(p_state in (select jsonb_array_elements_text(s->'states')), false))
$$;

-- the pool, ranked: dialable now, not already waiting on a list
create or replace function public.radar_rank()
returns table (lead_id bigint, rank numeric)
language sql stable set search_path = public as $$
  with recent as (
    select a.lead_id, coalesce(a.connected, false) as connected
      from attempts a where a.clicked_at >= now() - interval '30 days'
  ),
  floor_rate as (
    select count(*) filter (where connected)::numeric / nullif(count(*), 0) as rate from recent
  ),
  boost as (  -- intents connecting above the floor this month weigh more (20+ dials to count)
    select li.intent_key,
           case when count(*) >= 20 and (select rate from floor_rate) > 0
                then greatest(0.8, least(1.3, (count(*) filter (where r.connected)::numeric / count(*))
                                               / (select rate from floor_rate)))
                else 1 end as b
      from recent r join lead_intents li on li.lead_id = r.lead_id
     group by li.intent_key
  )
  select l.id,
         coalesce((select sum(li.confidence * (120 - ic.priority) / 100.0 * coalesce(bo.b, 1))
                     from lead_intents li
                     join intents_catalog ic on ic.key = li.intent_key
                     left join boost bo on bo.intent_key = li.intent_key
                    where li.lead_id = l.id and li.intent_key <> 'callback_due'), 0)
         + coalesce(l.score, 0) / 100.0
         + case when l.first_seen > now() - interval '7 days' then 0.3
                when l.first_seen > now() - interval '30 days' then 0.15 else 0 end
         + case when ls.attempts_total = 0 then 0.2 else -0.1 * least(ls.attempts_total, 5) end
    from leads l
    join lead_state ls on ls.lead_id = l.id
   where ls.state in ('fresh', 'queued')
     and (ls.rest_until is null or ls.rest_until <= now())
     and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
     and not exists (select 1 from list_items li2 join lists ld2 on ld2.id = li2.list_id
                      where li2.lead_id = l.id and ld2.status = 'active' and li2.served_at is null)
$$;

-- deal today's radar lists to active agents that don't have one yet; earlier
-- days' radar lists are closed so their unserved leads get re-ranked
create or replace function public.radar_deal()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_n int := coalesce((public.setting('radar_deal_per_agent'))::int, 100);
  v_today date := public.business_date();
  v_agents uuid[];
  v_lists bigint[] := '{}';
  v_list bigint;
  k int;
  r jsonb;
begin
  update lists set status = 'done' where kind = 'radar' and status = 'active' and list_date < v_today;
  if v_n <= 0 then return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n); end if;

  select array_agg(p.id order by lower(p.name), p.id) into v_agents
    from profiles p
   where p.active and p.role = 'agent'
     and not exists (select 1 from lists ld
                      where ld.kind = 'radar' and ld.agent_id = p.id and ld.list_date = v_today);
  k := coalesce(array_length(v_agents, 1), 0);
  if k = 0 then return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n); end if;

  for i in 1..k loop
    insert into lists (name, agent_id, rules, list_date, kind)
      values ('Radar · ' || to_char(v_today, 'Dy Mon FMDD'), v_agents[i], '{"radar": true}', v_today, 'radar')
      returning id into v_list;
    v_lists := v_lists || v_list;
  end loop;

  -- round-robin down the ranking, so every agent gets a fair share of the best leads
  insert into list_items (list_id, lead_id, position)
  select v_lists[1 + ((rn - 1) % k)::int], x.lead_id, ((rn - 1) / k + 1)::int
    from (select rr.lead_id, row_number() over (order by rr.rank desc, rr.lead_id) as rn from radar_rank() rr) x
   where rn <= v_n * k;

  select jsonb_agg(jsonb_build_object('agent_id', ld.agent_id, 'list_id', ld.id,
           'count', (select count(*) from list_items li where li.list_id = ld.id)) order by ld.id)
    into r from lists ld where ld.id = any (v_lists);
  return jsonb_build_object('dealt', coalesce(r, '[]'::jsonb), 'per_agent', v_n);
end $$;

-- the morning job: tag in-season leads, deal the lists, remember the run
create or replace function public.radar_run()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_today date := public.business_date();
  v_month int := extract(month from public.business_date())::int;
  v_seasonal int;
  v_deal jsonb;
  v_run jsonb;
begin
  delete from lead_intents where intent_key = 'seasonal_window' and source = 'radar';
  insert into lead_intents (lead_id, intent_key, confidence, source)
  select distinct l.id, 'seasonal_window', 0.8, 'radar'
    from leads l
    cross join jsonb_array_elements(coalesce(public.setting('seasons'), '[]'::jsonb)) s
   where v_month in (select jsonb_array_elements_text(s->'months')::int)
     and season_has(s, l.category_key, l.addr_state)
  on conflict (lead_id, intent_key) do update
    set confidence = excluded.confidence, source = 'radar', computed_at = now();
  get diagnostics v_seasonal = row_count;

  v_deal := radar_deal();
  v_run := jsonb_build_object('date', v_today, 'at', now(), 'seasonal', v_seasonal,
                              'lists', jsonb_array_length(v_deal->'dealt'));
  insert into app_settings (key, value) values ('radar_last_run', v_run)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return v_run || jsonb_build_object('dealt', v_deal->'dealt');
end $$;

-- once per business day, triggered by the first Dial or Radar page of the day
-- (no scheduler needed); anyone signed in may trigger it, it only runs once
create or replace function public.radar_daily()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_last jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  v_last := public.setting('radar_last_run');
  if v_last->>'date' = public.business_date()::text then return v_last || '{"ran": false}'; end if;
  if not pg_try_advisory_xact_lock(hashtext('dial-floor radar_daily')) then
    return jsonb_build_object('ran', false, 'busy', true);
  end if;
  v_last := public.setting('radar_last_run');  -- another session may have just finished
  if v_last->>'date' = public.business_date()::text then return v_last || '{"ran": false}'; end if;
  return radar_run() || '{"ran": true}';
end $$;

-- a manager dealing mid-day (a new agent, a list closed early): agents that
-- already have today's radar list keep it
create or replace function public.radar_deal_now()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  return radar_deal();
end $$;

-- the manager's cards
create or replace function public.radar()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_today date := public.business_date();
  v_start timestamptz := public.business_day_start();
  v_threshold int := coalesce((public.setting('missed_call_threshold'))::int, 4);
  v_month int := extract(month from public.business_date())::int;
  v_next int := extract(month from public.business_date())::int % 12 + 1;
  r jsonb;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  select jsonb_build_object(
    'date', v_today,
    'last_run', public.setting('radar_last_run'),
    'per_agent', coalesce((public.setting('radar_deal_per_agent'))::int, 100),
    'threshold', v_threshold,
    'callbacks', (select jsonb_build_object(
        'due_today', count(*) filter (where c.due_at >= v_start and c.due_at < v_start + interval '1 day'),
        'overdue', count(*) filter (where c.due_at < now() - interval '15 minutes'),
        'by_agent', coalesce((select jsonb_agg(jsonb_build_object('name', p.name, 'due', x.n) order by x.n desc, p.name)
                                from (select c2.agent_id, count(*) as n from callbacks c2
                                       where c2.status = 'scheduled' and c2.due_at < v_start + interval '1 day'
                                       group by c2.agent_id) x
                                join profiles p on p.id = x.agent_id), '[]'::jsonb))
       from callbacks c where c.status = 'scheduled'),
    'fresh_no_site', (select coalesce(jsonb_agg(x order by (x->>'count')::int desc, x->>'city'), '[]'::jsonb) from (
        select jsonb_build_object('category_key', split_part(l.category_key, ',', 1), 'label', min(l.category),
                                  'city', l.addr_city, 'state', l.addr_state, 'count', count(*)) as x
          from leads l join lead_state ls on ls.lead_id = l.id
         where l.website_type = 'none' and l.first_seen >= now() - interval '7 days'
           and ls.state in ('fresh', 'queued') and l.category_key is not null and l.addr_city is not null
         group by split_part(l.category_key, ',', 1), l.addr_city, l.addr_state
        having count(*) >= 3
         order by count(*) desc
         limit 6) s),
    'never_answers', (select jsonb_build_object(
        'total', count(*),
        'dialable', count(*) filter (where ls.state in ('fresh', 'queued')),
        'new_this_week', count(*) filter (where (select m.clicked_at from missed_tries(li.lead_id) m
                                                  order by m.clicked_at offset v_threshold - 1 limit 1)
                                                 >= now() - interval '7 days'))
       from lead_intents li join lead_state ls on ls.lead_id = li.lead_id
      where li.intent_key = 'never_answers'),
    'seasons', (select coalesce(jsonb_agg(jsonb_build_object(
          'label', s->>'label', 'keys', s->'keys',
          'open', v_month in (select jsonb_array_elements_text(s->'months')::int),
          'opens_next_month', v_month not in (select jsonb_array_elements_text(s->'months')::int)
                              and v_next in (select jsonb_array_elements_text(s->'months')::int),
          'dialable', (select count(*) from leads l join lead_state ls on ls.lead_id = l.id
                        where season_has(s, l.category_key, l.addr_state) and ls.state in ('fresh', 'queued')),
          'resting', (select count(*) from leads l join lead_state ls on ls.lead_id = l.id
                       where season_has(s, l.category_key, l.addr_state) and ls.state = 'resting'))), '[]'::jsonb)
       from jsonb_array_elements(coalesce(public.setting('seasons'), '[]'::jsonb)) s),
    'converting', (select coalesce(jsonb_agg(x order by (x->>'ratio')::numeric desc), '[]'::jsonb) from (
        select jsonb_build_object('kind', g.kind, 'label', g.label, 'dials', count(*),
                 'rate', round(100.0 * count(*) filter (where g.connected) / count(*), 1),
                 'floor', round(100 * f.rate, 1),
                 'ratio', round((count(*) filter (where g.connected)::numeric / count(*)) / f.rate, 2)) as x
          from (select 'intent' as kind, ic.label, coalesce(a.connected, false) as connected
                  from attempts a
                  join lead_intents li on li.lead_id = a.lead_id
                  join intents_catalog ic on ic.key = li.intent_key
                 where a.clicked_at >= now() - interval '30 days'
                union all
                select 'trade', split_part(l.category_key, ',', 1), coalesce(a.connected, false)
                  from attempts a join leads l on l.id = a.lead_id
                 where a.clicked_at >= now() - interval '30 days' and l.category_key is not null) g,
               (select count(*) filter (where connected)::numeric / nullif(count(*), 0) as rate
                  from attempts where clicked_at >= now() - interval '30 days') f
         where f.rate > 0
         group by g.kind, g.label, f.rate
        having count(*) >= 20 and count(*) filter (where g.connected)::numeric / count(*) >= 1.5 * f.rate
         order by (count(*) filter (where g.connected)::numeric / count(*)) / f.rate desc
         limit 6) s),
    'lists', (select coalesce(jsonb_agg(jsonb_build_object(
          'list_id', ld.id, 'agent', p.name, 'name', ld.name, 'status', ld.status,
          'total', (select count(*) from list_items li where li.list_id = ld.id),
          'served', (select count(*) from list_items li where li.list_id = ld.id and li.served_at is not null))
        order by p.name), '[]'::jsonb)
       from lists ld left join profiles p on p.id = ld.agent_id
      where ld.kind = 'radar' and ld.list_date = v_today)
  ) into r;
  return r;
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.missed_tries(bigint), public.season_has(jsonb, text, text),
  public.radar(), public.radar_daily(), public.radar_deal_now() from public, anon;
grant execute on function public.missed_tries(bigint), public.season_has(jsonb, text, text),
  public.radar(), public.radar_daily(), public.radar_deal_now() to authenticated;
revoke execute on function public.radar_rank(), public.radar_deal(), public.radar_run()
  from public, anon, authenticated;

-- C4 for the calls already made
select count(public.refresh_lead(lead_id)) from public.lead_state where attempts_total > 0;
