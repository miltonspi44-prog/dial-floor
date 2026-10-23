-- Dial Floor · 0043 the AI floor: who answers, who converts, and who should call them
--
-- Three layers, each useful without the next:
--   1. lead_scores — every lead that can still be dialed gets a chance of reaching
--      a live conversation on a dial and a chance of ending in a chance given or
--      a sale, learned from the floor's own last 90 days of calls by the lead's
--      trade, state, area code, phone type, website, source, tier, reviews and
--      scraper score. Each trait's effect is smoothed toward the floor average
--      (a trait seen on 12 dials moves the score far less than one seen on 400),
--      and the effects are combined with a damping exponent, so traits that move
--      together are not counted twice. Refreshed hourly and before each morning radar.
--   2. ai_agent_fit — each agent's record per conversation (a win counts 1, a
--      callback or email 0.3), overall and by trade and state, smoothed the same
--      way. The morning radar deals each agent the leads they are likeliest to
--      convert: every lead × agent pair is valued at the lead's chance of a win
--      times the agent's fit for it, and handed out best pair first.
--   3. ai_briefs — the floor-ai edge function hands the aggregated numbers (no
--      lead names, numbers or notes) to Gemini and stores the analysis it writes.
--      Without a GEMINI_API_KEY the first two still run.
-- Applies through the management API as it is.

insert into public.app_settings (key, value) values ('ai', '{"model": "", "match": true}')
on conflict (key) do nothing;

-- -------------------------------------------------------------------- tables --
create table if not exists public.ai_features (
  kind text not null,          -- trade, state, area, phone, website, source, tier, reviews, score
  value text not null,
  dials int not null,
  convos int not null,
  wins int not null,
  answer_lift numeric not null, -- smoothed conversation rate against the floor's (1 = average)
  win_lift numeric not null,    -- smoothed win rate against the floor's
  refreshed_at timestamptz not null,
  primary key (kind, value)
);
create table if not exists public.ai_agent_fit (
  agent_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,          -- all, trade, state
  value text not null,
  convos int not null,
  points numeric not null,
  lift numeric not null,        -- all: against the floor; trade/state: against the agent's own rate
  refreshed_at timestamptz not null,
  primary key (agent_id, kind, value)
);
create table if not exists public.lead_scores (
  lead_id bigint primary key references public.leads(id) on delete cascade,
  p_answer numeric not null,    -- chance one dial reaches a live conversation
  p_win numeric not null,       -- chance one dial ends in a chance given or a sale
  answer_lift numeric not null,
  win_lift numeric not null,
  best_hour int,                -- the lead's own clock: its trade's best pickup hour, once reliable
  reasons jsonb not null default '[]'::jsonb,
  scored_at timestamptz not null
);
create index if not exists lead_scores_win_idx on public.lead_scores (p_win desc);
create table if not exists public.ai_briefs (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  source text not null default 'manual' check (source in ('manual', 'cron')),
  requested_by uuid references public.profiles(id) on delete set null,
  ok boolean not null,
  model text,
  brief jsonb,
  error text
);
create index if not exists ai_briefs_created_idx on public.ai_briefs (created_at desc);
create index if not exists ai_briefs_requested_by_idx on public.ai_briefs (requested_by);

alter table public.ai_features enable row level security;
alter table public.ai_agent_fit enable row level security;
alter table public.lead_scores enable row level security;
alter table public.ai_briefs enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'ai_features' and policyname = 'ai_features_read') then
    create policy ai_features_read on public.ai_features for select to authenticated using (public.is_manager());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'ai_agent_fit' and policyname = 'ai_agent_fit_read') then
    create policy ai_agent_fit_read on public.ai_agent_fit for select to authenticated using (public.is_manager());
  end if;
  -- an agent sees the score of the lead on their screen
  if not exists (select 1 from pg_policies where tablename = 'lead_scores' and policyname = 'lead_scores_read') then
    create policy lead_scores_read on public.lead_scores for select to authenticated using (public.is_active());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'ai_briefs' and policyname = 'ai_briefs_read') then
    create policy ai_briefs_read on public.ai_briefs for select to authenticated using (public.is_manager());
  end if;
end $$;

-- ------------------------------------------------------------- ai_lead_keys --
-- The traits a lead is scored on, one row each, the same way for learning and scoring.
create or replace function public.ai_lead_keys(l public.leads)
returns table (kind text, value text) language sql stable set search_path = public as $$
  select v.kind, v.value from (values
    ('trade',   coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)')),
    ('state',   coalesce(nullif(upper(trim(l.addr_state)), ''), '(none)')),
    ('area',    coalesce(nullif(left(l.phone_norm, 3), ''), '(none)')),
    ('phone',   coalesce(nullif(l.phone_type, ''), 'unknown')),
    ('website', coalesce(nullif(l.website_type, ''), 'unknown')),
    ('source',  coalesce(nullif(l.source, ''), 'unknown')),
    ('tier',    coalesce(nullif(upper(l.tier), ''), '(none)')),
    ('reviews', case when coalesce(l.review_count, 0) = 0 then '0' when l.review_count < 10 then '1-9'
                     when l.review_count < 50 then '10-49' else '50+' end),
    ('score',   case when l.score is null then '(none)' when l.score < 40 then '<40' when l.score < 60 then '40-59'
                     when l.score < 80 then '60-79' else '80+' end)
  ) as v(kind, value)
$$;

-- --------------------------------------------------------- ai_score_refresh --
create or replace function public.ai_score_refresh()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_days int := 90;
  ka numeric := 30;    -- a trait needs about this many dials before its answer rate counts for half
  kw numeric := 400;   -- wins are rare: a trait needs far more dials before its win rate moves
  kf numeric := 40;    -- an agent's record, in conversations
  damp numeric := 0.5; -- traits move together (state and area code, source and tier); count each half
  v_at timestamptz := clock_timestamp();
  n0 int; c0 int; w0 int; pts0 numeric;
  p0 numeric; q0 numeric; r0 numeric;
  v_scored int;
  st jsonb;
begin
  select count(*), count(*) filter (where public.is_conversation(a.connected, a.disposition)),
         count(*) filter (where a.disposition in ('chance_website', 'sale_closed')),
         coalesce(sum(case when a.disposition in ('chance_website', 'sale_closed') then 1.0
                           when a.disposition in ('callback', 'email_requested') then 0.3 else 0 end)
                  filter (where public.is_conversation(a.connected, a.disposition)), 0)
    into n0, c0, w0, pts0
    from attempts a
   where a.clicked_at >= now() - make_interval(days => v_days)
     and a.disposition is not null and a.disposition not in ('skipped', 'not_placed');
  -- the floor's own rates, with a whisker of prior so an empty floor still divides
  p0 := (c0 + 1.0) / (n0 + 5);
  q0 := (w0 + 0.5) / (n0 + 50);
  r0 := (pts0 + 1.0) / (c0 + 10);

  -- 1. what each trait does to the chance of a conversation and of a win
  insert into ai_features (kind, value, dials, convos, wins, answer_lift, win_lift, refreshed_at)
  select k.kind, k.value, count(*),
         count(*) filter (where x.convo), count(*) filter (where x.win),
         ((count(*) filter (where x.convo) + ka * p0) / (count(*) + ka)) / p0,
         ((count(*) filter (where x.win) + kw * q0) / (count(*) + kw)) / q0,
         v_at
    from (select l as lr,
                 public.is_conversation(a.connected, a.disposition) as convo,
                 a.disposition in ('chance_website', 'sale_closed') as win
            from attempts a join leads l on l.id = a.lead_id
           where a.clicked_at >= now() - make_interval(days => v_days)
             and a.disposition is not null and a.disposition not in ('skipped', 'not_placed')) x
    cross join lateral public.ai_lead_keys(x.lr) k
   group by k.kind, k.value
  on conflict (kind, value) do update set
    dials = excluded.dials, convos = excluded.convos, wins = excluded.wins,
    answer_lift = excluded.answer_lift, win_lift = excluded.win_lift, refreshed_at = excluded.refreshed_at;

  -- 2. each agent's record per conversation, overall and by trade and by state
  insert into ai_agent_fit (agent_id, kind, value, convos, points, lift, refreshed_at)
  with c as (
    select a.agent_id, l as lr,
           case when a.disposition in ('chance_website', 'sale_closed') then 1.0
                when a.disposition in ('callback', 'email_requested') then 0.3 else 0 end as pts
      from attempts a join leads l on l.id = a.lead_id
     where a.clicked_at >= now() - make_interval(days => v_days)
       and public.is_conversation(a.connected, a.disposition)
  ),
  ag as (
    select agent_id, count(*) as n, sum(pts) as p, (sum(pts) + kf * r0) / (count(*) + kf) as rate
      from c group by agent_id
  )
  select agent_id, 'all', '*', n, p, rate / r0, v_at from ag
  union all
  select c.agent_id, k.kind, k.value, count(*), sum(c.pts),
         ((sum(c.pts) + kf * ag.rate) / (count(*) + kf)) / ag.rate, v_at
    from c join ag using (agent_id)
    cross join lateral public.ai_lead_keys(c.lr) k
   where k.kind in ('trade', 'state')
   group by c.agent_id, k.kind, k.value, ag.rate
  on conflict (agent_id, kind, value) do update set
    convos = excluded.convos, points = excluded.points, lift = excluded.lift, refreshed_at = excluded.refreshed_at;

  -- 3. every lead still in play, scored; the three traits that move it most kept as its reasons
  insert into lead_scores (lead_id, p_answer, p_win, answer_lift, win_lift, best_hour, reasons, scored_at)
  select l.id,
         least(0.95, p0 * m.al), least(0.5, q0 * m.wl), m.al, m.wl,
         (select bt.hour from best_time_cells bt
           where bt.trade = coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)')
             and bt.hour >= 0 and bt.reliable
           order by bt.lift desc, bt.hour limit 1),
         coalesce((select jsonb_agg(e order by i) from jsonb_array_elements(m.why) with ordinality t(e, i) where i <= 3), '[]'::jsonb),
         v_at
    from leads l
    join lead_state ls on ls.lead_id = l.id
    cross join lateral (
      select greatest(0.25, least(4, exp(damp * sum(ln(coalesce(f.answer_lift, 1)))))) as al,
             greatest(0.25, least(4, exp(damp * sum(ln(coalesce(f.win_lift, 1)))))) as wl,
             coalesce(jsonb_agg(jsonb_build_object('kind', k.kind, 'value', k.value, 'dials', f.dials,
                                                   'answer', round(f.answer_lift, 2), 'win', round(f.win_lift, 2))
                                order by abs(ln(f.win_lift)) + 0.5 * abs(ln(f.answer_lift)) desc)
                        filter (where f.dials >= 20
                                  and abs(ln(f.win_lift)) + 0.5 * abs(ln(f.answer_lift)) >= 0.05), '[]'::jsonb) as why
        from public.ai_lead_keys(l) k
        left join ai_features f on f.kind = k.kind and f.value = k.value and f.refreshed_at = v_at
    ) m
   where ls.state not in ('suppressed', 'handoff')
  on conflict (lead_id) do update set
    p_answer = excluded.p_answer, p_win = excluded.p_win, answer_lift = excluded.answer_lift,
    win_lift = excluded.win_lift, best_hour = excluded.best_hour, reasons = excluded.reasons,
    scored_at = excluded.scored_at;
  get diagnostics v_scored = row_count;

  st := jsonb_build_object('at', v_at, 'days', v_days, 'dials', n0, 'convos', c0, 'wins', w0,
                           'answer_rate', round(p0, 4), 'win_rate', round(q0, 5), 'points_rate', round(r0, 4),
                           'scored', v_scored, 'secs', round(extract(epoch from clock_timestamp() - v_at)::numeric, 1));
  insert into app_settings (key, value) values ('ai_model_state', st)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return st;
end $$;

-- ------------------------------------------------------------ ai_agent_mult --
-- How much likelier this agent is than average to turn this lead into a win:
-- their overall record, times their record in its trade, times the square root
-- of their record in its state. Bounded, because a hot week is not a talent.
create or replace function public.ai_agent_mult(p_agent uuid, p_trade text, p_state text)
returns numeric language sql stable set search_path = public as $$
  with cur as (select max(refreshed_at) as at from ai_agent_fit)
  select greatest(0.6, least(1.6,
           coalesce((select f.lift from ai_agent_fit f, cur where f.agent_id = p_agent and f.kind = 'all' and f.value = '*' and f.refreshed_at = cur.at), 1)
         * coalesce((select f.lift from ai_agent_fit f, cur where f.agent_id = p_agent and f.kind = 'trade' and f.value = p_trade and f.refreshed_at = cur.at), 1)
         * sqrt(coalesce((select f.lift from ai_agent_fit f, cur where f.agent_id = p_agent and f.kind = 'state' and f.value = p_state and f.refreshed_at = cur.at), 1))))
$$;

-- -------------------------------------------------------------- build_list --
-- (0040's, with the AI order: ai_order true puts the likeliest wins first, and
--  the list takes the top of its order rather than whatever rows came first)
create or replace function public.build_list(p_name text, p_agent uuid, p_rules jsonb, p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_list bigint; v_count int;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  -- the first three digits of the number: one area code, or several separated by
  -- commas (305,786 for Miami); spaces are forgiven, anything else is refused
  if p_rules->>'area_code' is not null
     and regexp_replace(p_rules->>'area_code', '\s', '', 'g') !~ '^[2-9][0-9]{2}(,[2-9][0-9]{2})*$' then
    raise exception 'area code: three digits, or several separated by commas (305,786)';
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
      -- where the lead came from: the scraper's source (gmaps, registry, angi, ...), any of
      and (p_rules->>'source' is null
           or l.source = any (string_to_array(regexp_replace(p_rules->>'source', '\s', '', 'g'), ',')))
      -- a number here is ten digits with the area code first
      and (p_rules->>'area_code' is null
           or left(l.phone_norm, 3) = any (string_to_array(regexp_replace(p_rules->>'area_code', '\s', '', 'g'), ',')))
      and not exists (select 1 from list_items li2 join lists ld2 on ld2.id = li2.list_id
                      where li2.lead_id = l.id and ld2.status in ('draft', 'active') and li2.served_at is null)
    -- the same order the positions follow, so a list smaller than the match takes the best of it
    order by case when coalesce((p_rules->>'ai_order')::boolean, false) then s.p_win end desc nulls last,
             l.score desc nulls last, l.review_count desc nulls last, l.id
    limit p_limit;
  get diagnostics v_count = row_count;
  return jsonb_build_object('list_id', v_list, 'count', v_count);
end $$;

-- ---------------------------------------------------------------- radar_deal --
-- (0037's, with the deal matched.) The candidates are the ranked pool's likeliest
-- wins, three lists' worth per free agent; every candidate × agent pair is valued
-- at the lead's chance of a win times that agent's fit for it, and the pairs are
-- handed out best first, each agent up to a full list. With ai.match off, or no
-- scores yet, the deal is 0037's round-robin down the radar's ranking.
create or replace function public.radar_deal()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_n int := coalesce((public.setting('radar_deal_per_agent'))::int, 100);
  v_today date := public.business_date();
  v_ai boolean := coalesce((public.setting('ai')->>'match')::boolean, true);
  v_q0 numeric := coalesce((public.setting('ai_model_state')->>'win_rate')::numeric, 0.01);
  v_agents uuid[];
  v_picks bigint[];
  v_lists bigint[] := '{}';
  v_fill int[];
  v_left int;
  v_list bigint;
  v_closed int;
  k int;
  r record;
  res jsonb;
begin
  update lists set status = 'done'
   where kind = 'radar' and status = 'active' and public.list_outstanding(id) = 0;
  get diagnostics v_closed = row_count;
  if v_n <= 0 then
    return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n, 'closed', v_closed);
  end if;

  -- only an agent with no radar list waiting for approval and none still being dialed
  select array_agg(p.id order by lower(p.name), p.id) into v_agents
    from profiles p
   where p.active and p.role = 'agent'
     and not exists (select 1 from lists ld
                      where ld.kind = 'radar' and ld.agent_id = p.id and ld.status in ('draft', 'active'));
  k := coalesce(array_length(v_agents, 1), 0);
  if k = 0 then
    return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n, 'closed', v_closed);
  end if;

  v_ai := v_ai and exists (select 1 from lead_scores);
  if v_ai then
    select array_agg(c.lead_id order by c.pw desc, c.rank desc, c.lead_id) into v_picks
      from (select rr.lead_id, rr.rank, coalesce(s.p_win, v_q0) as pw
              from radar_rank() rr left join lead_scores s on s.lead_id = rr.lead_id
             order by coalesce(s.p_win, v_q0) desc, rr.rank desc, rr.lead_id
             limit v_n * k * 3) c;
  else
    select array_agg(x.lead_id order by x.rn) into v_picks
      from (select rr.lead_id, row_number() over (order by rr.rank desc, rr.lead_id) as rn
              from radar_rank() rr) x
     where x.rn <= v_n * k;
  end if;
  if coalesce(array_length(v_picks, 1), 0) = 0 then
    return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n, 'closed', v_closed);
  end if;

  for i in 1..k loop
    insert into lists (name, agent_id, rules, list_date, kind, status)
      values ('Radar · ' || to_char(v_today, 'Dy Mon FMDD'), v_agents[i],
              jsonb_build_object('radar', true, 'ai', v_ai), v_today, 'radar', 'draft')
      returning id into v_list;
    v_lists := v_lists || v_list;
  end loop;

  if v_ai then
    v_fill := array_fill(0, array[k]);
    v_left := least(v_n * k, array_length(v_picks, 1));
    for r in
      select c.lead_id, g.idx::int as idx
        from unnest(v_picks) as c(lead_id)
        join leads l on l.id = c.lead_id
        left join lead_scores s on s.lead_id = c.lead_id
        cross join unnest(v_agents) with ordinality as g(agent_id, idx)
       order by coalesce(s.p_win, v_q0)
                * public.ai_agent_mult(g.agent_id,
                    coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)'),
                    coalesce(nullif(upper(trim(l.addr_state)), ''), '(none)')) desc,
                c.lead_id, g.idx
    loop
      exit when v_left <= 0;
      continue when v_fill[r.idx] >= v_n;
      continue when exists (select 1 from list_items li where li.lead_id = r.lead_id and li.list_id = any (v_lists));
      v_fill[r.idx] := v_fill[r.idx] + 1;
      insert into list_items (list_id, lead_id, position) values (v_lists[r.idx], r.lead_id, v_fill[r.idx]);
      v_left := v_left - 1;
    end loop;
  else
    -- round-robin down the ranking, so every agent gets a fair share of the best leads
    insert into list_items (list_id, lead_id, position)
    select v_lists[1 + ((u.rn - 1) % k)::int], u.lead_id, ((u.rn - 1) / k + 1)::int
      from unnest(v_picks) with ordinality as u(lead_id, rn);
  end if;

  select jsonb_agg(jsonb_build_object('agent_id', ld.agent_id, 'list_id', ld.id, 'status', ld.status,
           'count', (select count(*) from list_items li where li.list_id = ld.id)) order by ld.id)
    into res from lists ld where ld.id = any (v_lists);
  return jsonb_build_object('dealt', coalesce(res, '[]'::jsonb), 'per_agent', v_n, 'closed', v_closed, 'matched', v_ai);
end $$;

-- -------------------------------------------------------- ai_floor_snapshot --
-- Everything the analysis reads, aggregated: no lead names, numbers or notes.
-- For the floor-ai function (service role) and, through ai_floor(), managers.
create or replace function public.ai_floor_snapshot()
returns jsonb language sql stable security definer set search_path = public as $$
  with cur as (select max(refreshed_at) as at from ai_features),
  fit_at as (select max(refreshed_at) as at from ai_agent_fit),
  seg as (
    select f.kind,
           jsonb_agg(jsonb_build_object('value', f.value, 'dials', f.dials, 'convos', f.convos, 'wins', f.wins,
                     'answer_lift', round(f.answer_lift, 2), 'win_lift', round(f.win_lift, 2)) order by f.dials desc) as rows
      from (select f.*, row_number() over (partition by f.kind order by f.dials desc) as rn
              from ai_features f, cur where f.refreshed_at = cur.at and f.dials >= 15) f
     where f.rn <= 15
     group by f.kind
  ),
  pool as (
    select l.id, s.p_answer, s.p_win,
           coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)') as trade,
           coalesce(nullif(upper(trim(l.addr_state)), ''), '(none)') as state
      from lead_state ls join leads l on l.id = ls.lead_id
      left join lead_scores s on s.lead_id = l.id
     where ls.state in ('fresh', 'queued') and (ls.rest_until is null or ls.rest_until <= now())
  ),
  cells as (
    select trade, state, count(*) as leads, round(avg(p_answer), 3) as answer, round(avg(p_win), 4) as win
      from pool group by trade, state having count(*) >= 15
  )
  select jsonb_build_object(
    'model', coalesce(public.setting('ai_model_state'), '{}'::jsonb),
    'segments', coalesce((select jsonb_object_agg(kind, rows) from seg), '{}'::jsonb),
    'outcomes_90d', coalesce((select jsonb_object_agg(d, n) from (
        select coalesce(disposition, '(open)') as d, count(*) as n from attempts
         where clicked_at >= now() - interval '90 days' group by 1) o), '{}'::jsonb),
    'floor_hours', coalesce((select jsonb_agg(jsonb_build_object('hour', hour, 'dials', dials, 'pickup', round(rate, 3), 'lift', round(lift, 2)) order by hour)
                               from best_time_cells where trade = '*' and hour >= 0 and dials >= 20), '[]'::jsonb),
    'trade_hours', coalesce((select jsonb_agg(jsonb_build_object('trade', t.trade, 'dials', t.dials, 'best_hours', t.best) order by t.dials desc)
                               from (select a.trade, a.dials,
                                            (select jsonb_agg(jsonb_build_object('hour', b.hour, 'lift', round(b.lift, 2)) order by b.lift desc)
                                               from (select * from best_time_cells b where b.trade = a.trade and b.hour >= 0 and b.reliable
                                                      order by b.lift desc limit 3) b) as best
                                       from best_time_cells a where a.hour = -1 and a.trade <> '*' and a.dials >= 30
                                      order by a.dials desc limit 10) t), '[]'::jsonb),
    'agents', coalesce((select jsonb_agg(x.j order by x.fit desc nulls last) from (
        select coalesce(fa.lift, 1) as fit, jsonb_build_object(
                 'agent', p.name,
                 'dials_90d', (select count(*) from attempts a where a.agent_id = p.id and a.clicked_at >= now() - interval '90 days'
                                and a.disposition is not null and a.disposition not in ('skipped', 'not_placed')),
                 'conversations', coalesce(fa.convos, 0),
                 'wins', (select count(*) from attempts a where a.agent_id = p.id and a.clicked_at >= now() - interval '90 days'
                           and a.disposition in ('chance_website', 'sale_closed')),
                 'kept_alive', (select count(*) from attempts a where a.agent_id = p.id and a.clicked_at >= now() - interval '90 days'
                                 and public.kept_alive(a.disposition)),
                 'fit', round(coalesce(fa.lift, 1), 2),
                 'strong', coalesce((select jsonb_agg(jsonb_build_object('kind', f.kind, 'value', f.value, 'convos', f.convos, 'lift', round(f.lift, 2)) order by f.lift desc)
                                       from (select * from ai_agent_fit f, fit_at where f.agent_id = p.id and f.refreshed_at = fit_at.at
                                               and f.kind in ('trade', 'state') and f.convos >= 8 and f.lift >= 1.08
                                             order by f.lift desc limit 4) f), '[]'::jsonb),
                 'weak', coalesce((select jsonb_agg(jsonb_build_object('kind', f.kind, 'value', f.value, 'convos', f.convos, 'lift', round(f.lift, 2)) order by f.lift)
                                     from (select * from ai_agent_fit f, fit_at where f.agent_id = p.id and f.refreshed_at = fit_at.at
                                             and f.kind in ('trade', 'state') and f.convos >= 8 and f.lift <= 0.93
                                           order by f.lift limit 3) f), '[]'::jsonb)) as j
          from profiles p
          left join ai_agent_fit fa on fa.agent_id = p.id and fa.kind = 'all' and fa.value = '*'
                                    and fa.refreshed_at = (select at from fit_at)
         where p.active and p.role = 'agent') x), '[]'::jsonb),
    'pool', jsonb_build_object(
        'dialable', (select count(*) from pool),
        'bands', coalesce((select jsonb_object_agg(b, n) from (
            select case when p_win is null then 'unscored'
                        when p_win >= 3 * (public.setting('ai_model_state')->>'win_rate')::numeric then 'high (3x+ average)'
                        when p_win >= 1.5 * (public.setting('ai_model_state')->>'win_rate')::numeric then 'good (1.5-3x)'
                        when p_win >= 0.75 * (public.setting('ai_model_state')->>'win_rate')::numeric then 'average'
                        else 'low' end as b, count(*) as n
              from pool group by 1) bb), '{}'::jsonb),
        'best_cells', coalesce((select jsonb_agg(jsonb_build_object('trade', trade, 'state', state, 'leads', leads, 'answer', answer, 'win', win) order by win desc)
                                  from (select * from cells order by win desc limit 15) c), '[]'::jsonb)),
    'radar', jsonb_build_object(
        'matched', coalesce((public.setting('ai')->>'match')::boolean, true),
        'per_agent', coalesce((public.setting('radar_deal_per_agent'))::int, 100),
        'waiting_approval', (select count(*) from lists where kind = 'radar' and status = 'draft'),
        'being_dialed', (select count(*) from lists where kind = 'radar' and status = 'active')),
    'outside_calls_7d', (select count(*) from webhook_events where received_at >= now() - interval '7 days'
                          and payload->>'dial_floor_outcome' like 'no dial of ours matched%'))
$$;

-- ------------------------------------------------------------------ ai_floor --
-- The AI page: the snapshot, the likeliest leads to call right now, and the
-- latest analysis Gemini wrote (with the latest attempt, if that one failed).
create or replace function public.ai_floor()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  return public.ai_floor_snapshot() || jsonb_build_object(
    'settings', coalesce(public.setting('ai'), '{}'::jsonb),
    'top_leads', coalesce((select jsonb_agg(t.j order by t.pw desc) from (
        select s.p_win as pw, jsonb_build_object(
                 'lead_id', l.id, 'name', l.name, 'phone', l.phone_display, 'city', l.addr_city, 'state', l.addr_state,
                 'trade', coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)'), 'tz', l.tz,
                 'p_answer', round(s.p_answer, 3), 'p_win', round(s.p_win, 4),
                 'answer_lift', round(s.answer_lift, 2), 'win_lift', round(s.win_lift, 2),
                 'best_hour', s.best_hour, 'reasons', s.reasons, 'callable_now', public.local_ok(l.tz)) as j
          from lead_scores s
          join leads l on l.id = s.lead_id
          join lead_state ls on ls.lead_id = l.id
         where ls.state in ('fresh', 'queued') and (ls.rest_until is null or ls.rest_until <= now())
         order by s.p_win desc, s.p_answer desc
         limit 40) t), '[]'::jsonb),
    'brief', (select to_jsonb(b) from (select id, created_at, source, model, brief from ai_briefs where ok order by id desc limit 1) b),
    'last_attempt', (select to_jsonb(b) from (select id, created_at, source, ok, model, error from ai_briefs order by id desc limit 1) b),
    'requested', public.setting('ai_brief_requested'));
end $$;

-- ---------------------------------------------------------- ai_brief_request --
-- Asks the floor-ai function for a fresh analysis, the way sync_request asks for
-- a pull: pg_net posts with the shared cron secret. A manager may ask once every
-- two minutes; the morning job (no login) always may.
create or replace function public.ai_brief_request()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_last timestamptz;
  v_req bigint;
begin
  if v_uid is not null and not public.is_manager() then raise exception 'manager only'; end if;
  if v_uid is not null then
    v_last := (public.setting('ai_brief_requested')->>'at')::timestamptz;
    if v_last > now() - interval '2 minutes' then
      return jsonb_build_object('ok', false, 'why', 'An analysis was asked for under two minutes ago and is still being written.');
    end if;
  end if;
  insert into app_settings (key, value) values ('ai_brief_requested', jsonb_build_object('at', now(), 'by', v_uid))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  begin
    execute format($q$
      select net.http_post(
        url := 'https://fevjrcxmktjwbaozbngo.supabase.co/functions/v1/floor-ai',
        headers := jsonb_build_object('content-type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_cron_secret')),
        body := %L::jsonb,
        timeout_milliseconds := 150000) $q$,
      jsonb_build_object('source', case when v_uid is null then 'cron' else 'manual' end, 'requested_by', v_uid)::text)
      into v_req;
  exception when undefined_function or undefined_table or invalid_schema_name or insufficient_privilege then
    return jsonb_build_object('ok', false, 'why', 'no scheduler on this database');
  end;
  return jsonb_build_object('ok', true, 'request_id', v_req);
end $$;

-- ---------------------------------------------------------------- radar_cron --
-- (0033's, scoring the leads before the morning deal)
create or replace function public.radar_cron()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_last jsonb;
begin
  v_last := public.setting('radar_last_run');
  if v_last->>'date' = public.business_date()::text then return v_last || '{"ran": false}'; end if;
  if not pg_try_advisory_xact_lock(hashtext('dial-floor radar_daily')) then
    return jsonb_build_object('ran', false, 'busy', true);
  end if;
  v_last := public.setting('radar_last_run');
  if v_last->>'date' = public.business_date()::text then return v_last || '{"ran": false}'; end if;
  perform public.streaks_refresh();  -- the day's streaks land with the day's lists
  perform public.ai_score_refresh();  -- the day's deal reads this morning's scores
  return radar_run() || '{"ran": true}';
end $$;

-- ------------------------------------------------------- settings registry --
-- (0037's, with the AI settings)
create or replace function public.settings_registry()
returns jsonb language sql immutable set search_path = public as $$
select jsonb_build_array(
  jsonb_build_object('key','call_window','kind','window','grp','Calling window','label','Calling hours (lead''s local time)','help','No lead is served or dialed outside these hours on its own clock.','def','{"start":"08:00","end":"20:30"}'::jsonb),
  jsonb_build_object('key','business_hours','kind','window_days','grp','Calling window','label','Business hours (for never-answers proof)','help','The hours and days that count as "they should have picked up".','def','{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}'::jsonb),
  jsonb_build_object('key','business_tz','kind','tz','grp','Calling window','label','Business timezone','help','The clock the floor''s day, streaks and reports run on.','def',to_jsonb('America/Los_Angeles'::text)),
  jsonb_build_object('key','max_attempts_per_day','kind','int','grp','Queue','label','Calls per business per day','min',1,'max',6,'def',to_jsonb(2)),
  jsonb_build_object('key','min_redial_minutes','kind','int','grp','Queue','label','Redial gap (minutes)','min',15,'max',720,'def',to_jsonb(120)),
  jsonb_build_object('key','reserve_minutes','kind','int','grp','Queue','label','Lead held on screen (minutes)','min',3,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','reclaim_minutes','kind','int','grp','Queue','label','Abandoned call reclaimed after (minutes)','min',10,'max',120,'def',to_jsonb(30)),
  jsonb_build_object('key','skip_rest_minutes','kind','int','grp','Queue','label','Rest after a skip (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','reclaim_sweep_max','kind','int','grp','Queue','label','Stranded calls finished per check','min',5,'max',100,'def',to_jsonb(25)),
  jsonb_build_object('key','allow_general_pool','kind','bool','grp','Queue','label','Serve from the general pool','help','Off = agents only dial callbacks and lists.','def',to_jsonb(true)),
  jsonb_build_object('key','callback_retry_minutes','kind','int','grp','Callbacks','label','Unanswered callback retried after (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','callback_max_tries','kind','int','grp','Callbacks','label','Tries before a callback is unreached','min',1,'max',6,'def',to_jsonb(3)),
  jsonb_build_object('key','callback_missed_hours','kind','int','grp','Callbacks','label','Overdue hours before a callback is missed','min',4,'max',72,'def',to_jsonb(24)),
  jsonb_build_object('key','rest_soft_days','kind','int','grp','Rests','label','"Not interested — soft" rest (days)','min',1,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','rest_hard_days','kind','int','grp','Rests','label','"Not interested — hard" rest (days)','min',1,'max',120,'def',to_jsonb(20)),
  jsonb_build_object('key','recycle_provider_days','kind','int','grp','Rests','label','"Has provider" auto-return (days, 0 = off)','min',0,'max',365,'def',to_jsonb(0)),
  jsonb_build_object('key','shift_hours','kind','num','grp','Pace','label','Shift length (hours)','min',1,'max',16,'def',to_jsonb(8)),
  jsonb_build_object('key','wrapup_seconds','kind','int','grp','Pace','label','Wrap-up countdown (seconds, 0 = off)','min',0,'max',300,'def',to_jsonb(20)),
  jsonb_build_object('key','alerts','kind','json','grp','Alerts','label','Alert thresholds','help','idle_minutes, long_call_minutes, pace_pct, callback_overdue_minutes, celebrate, spam, sync_quiet_minutes, console_quiet_days, outside_calls, radar_approvals.','def','{}'::jsonb),
  jsonb_build_object('key','spam_alert_drop_pts','kind','num','grp','Alerts','label','Spam alert: connect-rate drop (points)','min',1,'max',50,'def',to_jsonb(10)),
  jsonb_build_object('key','radar_deal_per_agent','kind','int','grp','Radar','label','Radar leads per proposed list','help','The radar proposes one list per agent and waits for a manager to approve it; the next is proposed once that one is dialed through. 0 turns the radar lists off.','min',0,'max',500,'def',to_jsonb(100)),
  jsonb_build_object('key','missed_call_threshold','kind','int','grp','Radar','label','Missed tries before "never answers"','min',2,'max',10,'def',to_jsonb(4)),
  jsonb_build_object('key','seasons','kind','json','grp','Radar','label','Seasonal windows','help','A list of {label, keys, months, states}.','def','[]'::jsonb),
  jsonb_build_object('key','best_time','kind','json','grp','Model','label','Best-time-to-call model','help','use_in_queue, days, min_dials, min_total, prior.','def','{}'::jsonb),
  jsonb_build_object('key','ai_summaries_enabled','kind','bool','grp','Model','label','Fetch Zoom AI call summaries','def',to_jsonb(false)),
  jsonb_build_object('key','ai','kind','json','grp','AI','label','AI floor analysis','help','model: the Gemini model to use (blank = the newest Gemini Flash your key can reach); match: true deals radar lists by who is likeliest to convert each lead, false deals them round-robin.','def','{"model":"","match":true}'::jsonb)
)
$$;

-- ----------------------------------------------------------------- schedules --
-- Scores every hour (seven past), and the analysis each morning before the
-- radar deals (12:35 UTC; the radar runs at 13:00). Guarded like 0034: no
-- pg_cron here (the local test stub) means nothing installs.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'ai: pg_cron is not installed here, so no jobs were installed.';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname in ('dial-floor ai scores', 'dial-floor ai brief');
  perform cron.schedule('dial-floor ai scores', '7 * * * *', 'select public.ai_score_refresh()');
  perform cron.schedule('dial-floor ai brief', '35 12 * * *', 'select public.ai_brief_request()');
end $$;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.ai_lead_keys(public.leads), public.ai_score_refresh(),
  public.ai_agent_mult(uuid, text, text), public.ai_floor_snapshot() from public, anon, authenticated;
revoke execute on function public.ai_floor(), public.ai_brief_request() from public, anon;
grant execute on function public.ai_floor(), public.ai_brief_request() to authenticated;

-- the first scores, now
select public.ai_score_refresh();
