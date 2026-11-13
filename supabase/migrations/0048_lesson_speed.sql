-- Dial Floor · 0048 lessons matched in one query, not one call a lead
-- 0047's ai_lesson_match runs once per lead per lesson, and each call builds
-- the whole lead row: about 0.2 ms, so 7.5 s to try one lesson on the ~39,000
-- leads in play. The editor's preview waited that long (near the API's 8 s
-- limit), and every lesson would have added as much to each rescore.
-- Now a lesson becomes one SQL condition (ai_lesson_where) and runs as a single
-- query over the leads, or over the 90 days' dials, in tens of milliseconds:
--   · ai_lesson_preview runs two such queries;
--   · ai_score_refresh gathers the leads in play with their calls so far once,
--     finds each active lesson's leads with one query each, and checks each
--     lesson's record with one query over the dials.
-- The values in a condition are quoted literals (a number range is cast to a
-- number first), so nothing a lesson holds can become SQL of its own.
-- ai_lesson_match stays as the one-lead form, and the tests hold the two to the
-- same answers.
-- Applies through the management API as it is.

-- ------------------------------------------------------- conditions as SQL --
-- A number range as SQL over expr, e.g. (expr = 0 or expr >= 5). expr is ours;
-- each bound is cast to a number before it is written in.
create or replace function public.ai_range_sql(expr text, spec text)
returns text language sql immutable set search_path = public as $$
  select '(' || coalesce(string_agg(case
           when r ~ '^[0-9]+(\.[0-9]+)?$' then format('%s = %s', expr, r::numeric)
           when r ~ '^[0-9]+(\.[0-9]+)?\+$' then format('%s >= %s', expr, rtrim(r, '+')::numeric)
           when r ~ '^<[0-9]+(\.[0-9]+)?$' then format('%s < %s', expr, ltrim(r, '<')::numeric)
           when r ~ '^>[0-9]+(\.[0-9]+)?$' then format('%s > %s', expr, ltrim(r, '>')::numeric)
           when r ~ '^[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)?$'
             then format('%s between %s and %s', expr, split_part(r, '-', 1)::numeric, split_part(r, '-', 2)::numeric)
           else 'false' end, ' or '), 'false') || ')'
    from unnest(string_to_array(spec, ',')) r
$$;

-- A lesson's traits as one SQL condition over a lead (l, a row of leads) and its
-- calls (h, with dials, pickups, last_outcome, days and intents): the same test
-- as ai_lesson_match, trait for trait.
create or replace function public.ai_lesson_where(c jsonb)
returns text language plpgsql immutable set search_path = public as $$
declare
  k text; v text;
  vals text[];
  p text;
  parts text[] := '{}';
begin
  for k, v in select e.key, e.value from jsonb_each_text(c) e order by e.key loop
    vals := string_to_array(v, ',');
    p := case k
      when 'trade'   then format($q$string_to_array(coalesce(nullif(replace(l.category_key, ' ', ''), ''), '(none)'), ',') && %L::text[]$q$, vals)
      when 'state'   then format($q$coalesce(nullif(upper(trim(l.addr_state)), ''), '(none)') = any (%L::text[])$q$, vals)
      when 'area'    then format($q$coalesce(nullif(left(l.phone_norm, 3), ''), '(none)') = any (%L::text[])$q$, vals)
      when 'phone'   then format($q$coalesce(nullif(l.phone_type, ''), 'unknown') = any (%L::text[])$q$, vals)
      when 'website' then format($q$coalesce(nullif(l.website_type, ''), 'unknown') = any (%L::text[])$q$, vals)
      when 'source'  then format($q$coalesce(nullif(l.source, ''), 'unknown') = any (%L::text[])$q$, vals)
      when 'tier'    then format($q$coalesce(nullif(upper(l.tier), ''), '(none)') = any (%L::text[])$q$, vals)
      when 'city'    then format($q$lower(trim(l.addr_city)) = any (%L::text[])$q$, vals)
      when 'name_has' then (select '(' || string_agg(format('strpos(lower(l.name), %L) > 0', w), ' or ') || ')' from unnest(vals) w)
      when 'intent'  then format($q$h.intents && %L::text[]$q$, vals)
      when 'reviews' then public.ai_range_sql('coalesce(l.review_count, 0)', v)
      when 'score'   then public.ai_range_sql('l.score', v)
      when 'rating'  then public.ai_range_sql('l.rating', v)
      when 'dials'   then public.ai_range_sql('coalesce(h.dials, 0)', v)
      when 'pickups' then public.ai_range_sql('coalesce(h.pickups, 0)', v)
      when 'days_since' then public.ai_range_sql('h.days', v)
      when 'last_outcome' then format($q$coalesce(h.last_outcome, case when coalesce(h.dials, 0) = 0 then 'none' end) = any (%L::text[])$q$, vals)
    end;
    if p is null then raise exception 'a lesson cannot use the trait "%"', k; end if;
    parts := parts || format('coalesce(%s, false)', p);
  end loop;
  return case when cardinality(parts) = 0 then 'true' else array_to_string(parts, ' and ') end;
end $$;

-- --------------------------------------------------------- ai_score_refresh --
-- (0047's, with each lesson's leads and record found by one query each)
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
  -- a lead's signals are gathered only when some lesson asks for them
  v_intents boolean := exists (select 1 from ai_lessons where removed_at is null and conditions ? 'intent');
  les record;
  rd int; rc int; rw int;
  st jsonb;
begin
  -- the minute job, the morning radar and the hourly refresh can all ask at once
  if not pg_try_advisory_xact_lock(hashtext('dial-floor ai_score_refresh')) then
    return jsonb_build_object('busy', true);
  end if;

  select count(*), count(*) filter (where d.convo), count(*) filter (where d.win),
         coalesce(sum(d.pts) filter (where d.convo), 0)
    into n0, c0, w0, pts0
    from public.ai_dials(v_days) d;
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
    from (select l as lr, d.convo, d.win from public.ai_dials(v_days) d join leads l on l.id = d.lead_id) x
    cross join lateral public.ai_lead_keys(x.lr) k
   group by k.kind, k.value
  on conflict (kind, value) do update set
    dials = excluded.dials, convos = excluded.convos, wins = excluded.wins,
    answer_lift = excluded.answer_lift, win_lift = excluded.win_lift, refreshed_at = excluded.refreshed_at;

  -- 2. each agent's record per conversation, overall and by trade and by state
  insert into ai_agent_fit (agent_id, kind, value, convos, points, lift, refreshed_at)
  with c as (
    select d.agent_id, l as lr, d.pts
      from public.ai_dials(v_days) d join leads l on l.id = d.lead_id
     where d.convo
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

  -- 3. the leads in play with their calls so far, and each active lesson's
  --    leads among them, one query a lesson
  create temp table if not exists ai_hist (lead_id bigint primary key, state text, dials int, pickups int,
                                           last_outcome text, days int, intents text[]) on commit drop;
  truncate pg_temp.ai_hist;
  insert into pg_temp.ai_hist
    select * from public.ai_lead_history(v_intents) x where x.state not in ('suppressed', 'handoff');
  create temp table if not exists ai_lesson_hits (lesson_id bigint not null, lead_id bigint not null) on commit drop;
  truncate pg_temp.ai_lesson_hits;
  for les in select s.id, s.conditions from ai_lessons s where s.active and s.removed_at is null order by s.id loop
    execute format('insert into pg_temp.ai_lesson_hits select %s, l.id from pg_temp.ai_hist h join leads l on l.id = h.lead_id where %s',
                   les.id, public.ai_lesson_where(les.conditions));
  end loop;
  create index if not exists ai_lesson_hits_lead_idx on pg_temp.ai_lesson_hits (lead_id);
  analyze pg_temp.ai_lesson_hits;

  -- 4. every lead still in play, scored: the data's lifts, times every lesson the
  --    lead fits, times the manager's verdict on it; the teaching first among its
  --    reasons, then the three traits that move it most
  insert into lead_scores (lead_id, p_answer, p_win, answer_lift, win_lift, best_hour, reasons, scored_at)
  select l.id,
         least(0.95, p0 * f.fa), least(0.5, q0 * f.fw), f.fa, f.fw,
         (select bt.hour from best_time_cells bt
           where bt.trade = coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)')
             and bt.hour >= 0 and bt.reliable
           order by bt.lift desc, bt.hour limit 1),
         t.taught
           || case when mk.verdict is null then '[]'::jsonb
                   else jsonb_build_array(jsonb_build_object('kind', 'mark', 'value', mk.verdict, 'note', left(coalesce(mk.note, ''), 160),
                                                             'win', case mk.verdict when 'good' then 2 else 0.25 end)) end
           || coalesce((select jsonb_agg(e order by i) from jsonb_array_elements(m.why) with ordinality w(e, i) where i <= 3), '[]'::jsonb),
         v_at
    from leads l
    join pg_temp.ai_hist h on h.lead_id = l.id
    left join ai_lead_marks mk on mk.lead_id = l.id and mk.verdict is not null
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
    cross join lateral (
      select coalesce(exp(sum(ln(s.win_mult))), 1) as tw,
             coalesce(exp(sum(ln(s.answer_mult))), 1) as ta,
             coalesce(jsonb_agg(jsonb_build_object('kind', 'lesson', 'id', s.id, 'value', left(s.note, 160),
                                                   'win', s.win_mult, 'answer', s.answer_mult)
                                order by abs(ln(s.win_mult)) desc, s.id), '[]'::jsonb) as taught
        from pg_temp.ai_lesson_hits hh join ai_lessons s on s.id = hh.lesson_id
       where hh.lead_id = l.id
    ) t
    cross join lateral (
      select greatest(0.1, least(6, m.al * t.ta)) as fa,
             greatest(0.02, least(10, m.wl * t.tw * case mk.verdict when 'good' then 2 when 'bad' then 0.25 else 1 end)) as fw
    ) f
  on conflict (lead_id) do update set
    p_answer = excluded.p_answer, p_win = excluded.p_win, answer_lift = excluded.answer_lift,
    win_lift = excluded.win_lift, best_hour = excluded.best_hour, reasons = excluded.reasons,
    scored_at = excluded.scored_at;
  get diagnostics v_scored = row_count;

  -- 5. each lesson against the floor's record: how many leads in play it moves,
  --    and how the dials it describes did (each judged by the lead's history
  --    before it), smoothed like a trait; one query a lesson
  create temp table if not exists ai_dial_h (attempt_id bigint, lead_id bigint, convo boolean, win boolean, dials int,
                                             pickups int, last_outcome text, days int, intents text[]) on commit drop;
  truncate pg_temp.ai_dial_h;
  insert into pg_temp.ai_dial_h
    select d.attempt_id, d.lead_id, d.convo, d.win, hb.dials_before, hb.pickups_before, hb.last_before, hb.days_before,
           case when v_intents then array(select li.intent_key from lead_intents li where li.lead_id = d.lead_id) end
      from public.ai_dials(v_days) d join public.ai_dial_history(v_days) hb on hb.attempt_id = d.attempt_id;
  for les in select s.id, s.conditions, s.active from ai_lessons s where s.removed_at is null order by s.id loop
    execute format('select count(*), count(*) filter (where h.convo), count(*) filter (where h.win)
                      from pg_temp.ai_dial_h h join leads l on l.id = h.lead_id where %s', public.ai_lesson_where(les.conditions))
      into rd, rc, rw;
    update ai_lessons set stats = jsonb_build_object(
        'at', v_at,
        'leads', case when les.active then (select count(*) from pg_temp.ai_lesson_hits hh where hh.lesson_id = les.id) else 0 end,
        'dials', rd, 'convos', rc, 'wins', rw,
        'answer_lift', round(((rc + ka * p0) / (rd + ka)) / p0, 2),
        'win_lift', round(((rw + kw * q0) / (rd + kw)) / q0, 2))
     where id = les.id;
  end loop;

  st := jsonb_build_object('at', v_at, 'days', v_days, 'dials', n0, 'convos', c0, 'wins', w0,
                           'answer_rate', round(p0, 4), 'win_rate', round(q0, 5), 'points_rate', round(r0, 4),
                           'scored', v_scored,
                           'lessons', (select count(*) from ai_lessons where active and removed_at is null),
                           'marks', (select count(*) from ai_lead_marks where verdict is not null),
                           'secs', round(extract(epoch from clock_timestamp() - v_at)::numeric, 1));
  insert into app_settings (key, value) values ('ai_model_state', st)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return st;
end $$;

-- ------------------------------------------------------------------ preview --
-- (0047's, as two queries)
create or replace function public.ai_lesson_preview(p_conditions jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_cond jsonb;
  v_where text;
  v_int boolean;
  v_leads int; d int; c int; w int;
  p0 numeric := coalesce((public.setting('ai_model_state')->>'answer_rate')::numeric, 0.2);
  q0 numeric := coalesce((public.setting('ai_model_state')->>'win_rate')::numeric, 0.005);
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  v_cond := public.ai_clean_conditions(p_conditions);
  v_where := public.ai_lesson_where(v_cond);
  v_int := v_cond ? 'intent';
  execute format('select count(*) from public.ai_lead_history(%L) h join leads l on l.id = h.lead_id
                   where h.state not in (''suppressed'', ''handoff'') and %s', v_int, v_where)
    into v_leads;
  execute format('select count(*), count(*) filter (where h.convo), count(*) filter (where h.win)
                    from (select x.lead_id, x.convo, x.win, hb.dials_before as dials, hb.pickups_before as pickups,
                                 hb.last_before as last_outcome, hb.days_before as days, %s as intents
                            from public.ai_dials(90) x join public.ai_dial_history(90) hb on hb.attempt_id = x.attempt_id) h
                    join leads l on l.id = h.lead_id where %s',
                 case when v_int then 'array(select li.intent_key from lead_intents li where li.lead_id = x.lead_id)' else 'null::text[]' end,
                 v_where)
    into d, c, w;
  return jsonb_build_object('conditions', v_cond, 'leads', v_leads, 'dials', d, 'convos', c, 'wins', w,
                            'answer_lift', round(((c + 30 * p0) / (d + 30)) / p0, 2),
                            'win_lift', round(((w + 400 * q0) / (d + 400)) / q0, 2));
end $$;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.ai_range_sql(text, text), public.ai_lesson_where(jsonb) from public, anon, authenticated;
