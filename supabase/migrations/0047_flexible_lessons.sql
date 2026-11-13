-- Dial Floor · 0047 lessons that can say what the manager means
-- 0044's lessons knew nine traits, all about the business, and the number ones
-- (reviews, scraper score) only in fixed bands. A manager's lesson is often
-- about the calls: "after three tries with no pickup they never answer",
-- "a soft no from last week is worth one more call". Now a lesson can name:
--   · its calls so far: dials (times called), pickups (times someone answered),
--     last_outcome (how the last call ended, or "none": never called) and
--     days_since (days since the last call);
--   · more of the business: rating (Google stars), city, name_has (words in its
--     name, e.g. llc or roofing), intent (the lead's signals: no website, owner
--     mobile, paying for ads, ...);
--   · every number as any range: 3 (exactly), 2-4, 3+ (at least), <3 or >3,
--     several joined by commas; the old bands (1-9, 50+, <40 ...) are ranges too,
--     so every saved lesson reads as it did.
-- A lesson takes up to eight traits.
-- The call traits are the lead's history as it stands: a lead's score counts
-- its calls so far, and when a lesson is checked against the last 90 days each
-- dial is judged by the lead's history before that dial, so "called 3+ times"
-- is checked on the 4th and later dials, not on the leads' first ones.
-- ai_lesson_preview tells the editor, before saving, how many leads in play a
-- lesson fits and how such dials did, so a lesson that fits nothing shows it.
-- Applies through the management API as it is.

-- ------------------------------------------------------------- number ranges --
-- Is x in any of the ranges? 3 · 2-4 · 3+ · <3 · >3, comma separated.
create or replace function public.ai_in_range(x numeric, spec text)
returns boolean language sql immutable set search_path = public as $$
  select x is not null and exists (
    select 1 from unnest(string_to_array(spec, ',')) r
     where case
       when r ~ '^[0-9]+(\.[0-9]+)?$' then x = r::numeric
       when r ~ '^[0-9]+(\.[0-9]+)?\+$' then x >= rtrim(r, '+')::numeric
       when r ~ '^<[0-9]+(\.[0-9]+)?$' then x < ltrim(r, '<')::numeric
       when r ~ '^>[0-9]+(\.[0-9]+)?$' then x > ltrim(r, '>')::numeric
       when r ~ '^[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)?$'
         then x between split_part(r, '-', 1)::numeric and split_part(r, '-', 2)::numeric
       else false end)
$$;

-- ------------------------------------------------------------- lead history --
-- Each lead's calls so far: dials and pickups as lead_state counts them, the
-- last logged call's outcome and how many days ago it was, and (when asked)
-- its signals.
create or replace function public.ai_lead_history(p_intents boolean default true)
returns table (lead_id bigint, state text, dials int, pickups int, last_outcome text, days int, intents text[])
language sql stable set search_path = public as $$
  select ls.lead_id, ls.state, ls.attempts_total, ls.connects_total, la.disposition,
         floor(extract(epoch from now() - la.clicked_at) / 86400)::int, li.keys
    from lead_state ls
    left join (select distinct on (a.lead_id) a.lead_id, a.disposition, a.clicked_at
                 from attempts a
                where a.disposition is not null and a.disposition <> 'not_placed'
                order by a.lead_id, a.clicked_at desc, a.id desc) la on la.lead_id = ls.lead_id
    left join (select x.lead_id, array_agg(x.intent_key) as keys
                 from lead_intents x where p_intents group by x.lead_id) li on li.lead_id = ls.lead_id
$$;

-- Each dial of the last p_days with the lead's history before it: how many
-- times it had been called and had picked up, how the call before ended, and
-- how many days before.
create or replace function public.ai_dial_history(p_days int)
returns table (attempt_id bigint, dials_before int, pickups_before int, last_before text, days_before int)
language sql stable set search_path = public as $$
  select h.id, h.dials_before, h.pickups_before, h.last_before, h.days_before
    from (select a.id, a.clicked_at,
                 (count(*) over w)::int as dials_before,
                 (count(*) filter (where a.connected) over w)::int as pickups_before,
                 lag(a.disposition) over o as last_before,
                 floor(extract(epoch from a.clicked_at - lag(a.clicked_at) over o) / 86400)::int as days_before
            from attempts a
           where a.disposition is distinct from 'not_placed'
          window w as (partition by a.lead_id order by a.clicked_at, a.id rows between unbounded preceding and 1 preceding),
                 o as (partition by a.lead_id order by a.clicked_at, a.id)) h
   where h.clicked_at >= now() - make_interval(days => p_days)
$$;

-- ---------------------------------------------------------- lesson matching --
-- Does this lead, with this history, have every trait the lesson names?
create or replace function public.ai_lesson_match(c jsonb, l public.leads, h_dials int, h_pickups int,
                                                 h_last text, h_days int, h_intents text[])
returns boolean language sql stable set search_path = public as $$
  select not exists (
    select 1 from jsonb_each_text(c) e(k, v)
     where not coalesce(case e.k
       when 'trade'   then string_to_array(coalesce(nullif(replace(l.category_key, ' ', ''), ''), '(none)'), ',')
                           && string_to_array(e.v, ',')
       when 'state'   then coalesce(nullif(upper(trim(l.addr_state)), ''), '(none)') = any (string_to_array(e.v, ','))
       when 'area'    then coalesce(nullif(left(l.phone_norm, 3), ''), '(none)') = any (string_to_array(e.v, ','))
       when 'phone'   then coalesce(nullif(l.phone_type, ''), 'unknown') = any (string_to_array(e.v, ','))
       when 'website' then coalesce(nullif(l.website_type, ''), 'unknown') = any (string_to_array(e.v, ','))
       when 'source'  then coalesce(nullif(l.source, ''), 'unknown') = any (string_to_array(e.v, ','))
       when 'tier'    then coalesce(nullif(upper(l.tier), ''), '(none)') = any (string_to_array(e.v, ','))
       when 'city'    then lower(trim(l.addr_city)) = any (string_to_array(e.v, ','))
       when 'name_has' then exists (select 1 from unnest(string_to_array(e.v, ',')) w where strpos(lower(l.name), w) > 0)
       when 'intent'  then h_intents && string_to_array(e.v, ',')
       when 'reviews' then public.ai_in_range(coalesce(l.review_count, 0), e.v)
       when 'score'   then public.ai_in_range(l.score, e.v)
       when 'rating'  then public.ai_in_range(l.rating, e.v)
       when 'dials'   then public.ai_in_range(coalesce(h_dials, 0), e.v)
       when 'pickups' then public.ai_in_range(coalesce(h_pickups, 0), e.v)
       when 'days_since' then public.ai_in_range(h_days, e.v)
       when 'last_outcome' then coalesce(h_last, case when coalesce(h_dials, 0) = 0 then 'none' end) = any (string_to_array(e.v, ','))
     end, false))
$$;

-- 0044's two-argument form, now with the lead's history as it stands
create or replace function public.ai_lesson_match(c jsonb, l public.leads)
returns boolean language sql stable set search_path = public as $$
  select public.ai_lesson_match(c, l, h.dials, h.pickups, h.last_outcome, h.days, h.intents)
    from public.ai_lead_history(c ? 'intent') h where h.lead_id = l.id
$$;

-- A lesson's traits as the manager or Gemini gave them, checked and tidied:
-- known traits only, each value in the form the lead's own traits take, each
-- number as a range (>=3 becomes 3+, <=2 becomes 0-2, "3 to 5" becomes 3-5).
create or replace function public.ai_clean_conditions(c jsonb)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  out jsonb := '{}'::jsonb;
  k text; v text; x text; a text; b text;
  vals text[];
  pat text;
  num text;   -- the number form a range trait takes: whole, or with decimals
  label text;
begin
  if c is null or jsonb_typeof(c) <> 'object' or c = '{}'::jsonb then
    raise exception 'a lesson needs at least one trait';
  end if;
  for k, v in select e.key, e.value from jsonb_each_text(c) e loop
    k := case lower(trim(k)) when 'attempts' then 'dials' when 'calls' then 'dials' when 'connects' then 'pickups'
                             when 'last_disposition' then 'last_outcome' else lower(trim(k)) end;
    label := replace(k, '_', ' ');
    num := case when k = 'rating' then '[0-9]+(\.[0-9]+)?'
                when k in ('dials', 'pickups', 'days_since', 'reviews', 'score') then '[0-9]+' end;
    pat := case k
      when 'trade'   then '^[a-z0-9_]+$'
      when 'state'   then '^[A-Z]{2}$'
      when 'area'    then '^[2-9][0-9]{2}$'
      when 'phone'   then '^(mobile|landline|voip|unknown)$'
      when 'website' then '^(none|social|site|unreachable|unknown)$'
      when 'source'  then '^[a-z0-9_]+$'
      when 'tier'    then '^[A-Z]$'
      when 'city'    then '^[a-z][a-z .''-]{0,39}$'
      when 'name_has' then '^[a-z0-9&'' .-]{2,40}$'
      when 'intent'  then '^[a-z_]+$'
      when 'last_outcome' then '^(none|no_answer|voicemail|busy_failed|disconnected|wrong_number|gatekeeper_end|not_interested_soft|'
                               'not_interested_hard|has_provider|dm_not_in|callback|email_requested|dnc|chance_website|sale_closed|language_barrier)$'
    end;
    if num is not null then pat := format('^(%1$s|%1$s\+|<%1$s|>%1$s|%1$s-%1$s)$', num); end if;
    if pat is null then raise exception 'a lesson cannot use the trait "%"', k; end if;
    if out ? k then raise exception 'the trait "%" is given twice', label; end if;

    vals := array(select distinct
                    case when k in ('state', 'tier') then upper(trim(y))
                         when num is not null then lower(regexp_replace(y, '\s', '', 'g'))
                         else lower(trim(regexp_replace(y, '\s+', ' ', 'g'))) end
                    from unnest(string_to_array(coalesce(v, ''), ',')) y where trim(y) <> '');
    if num is not null then
      vals := array(select distinct
                      regexp_replace(regexp_replace(regexp_replace(regexp_replace(y,
                        '^(>=|=>)(.+)$', '\2+'), '^(<=|=<)(.+)$', '0-\2'), '^(.+?)(to|–|—)(.+)$', '\1-\3'),
                        '^(.+?)(ormore|orabove|andup|andabove|plus)$', '\1+')
                      from unnest(vals) y);
    end if;
    if cardinality(vals) = 0 then raise exception 'the trait "%" needs a value', label; end if;
    if cardinality(vals) > 12 then raise exception 'the trait "%" takes at most 12 values', label; end if;
    foreach x in array vals loop
      if x !~ pat then
        if num is not null then
          raise exception '"%" is not a range for %: write a number (3), a range (2-4), at least (3+) or under (<3)', x, label;
        end if;
        raise exception '"%" is not a % this system knows', x, label;
      end if;
      if k = 'intent' and not exists (select 1 from intents_catalog ic where ic.key = x) then
        raise exception '"%" is not a lead signal this system knows', x;
      end if;
      if num is not null and x ~ '^[0-9.]+-[0-9.]+$' then
        a := split_part(x, '-', 1); b := split_part(x, '-', 2);
        if a::numeric > b::numeric then raise exception 'the range "%" for % runs backwards: write %-%', x, label, b, a; end if;
      end if;
    end loop;
    out := out || jsonb_build_object(k, array_to_string(array(select y from unnest(vals) y order by y), ','));
  end loop;
  if (select count(*) from jsonb_object_keys(out)) > 8 then raise exception 'a lesson takes at most 8 traits'; end if;
  return out;
end $$;

-- --------------------------------------------------------- ai_score_refresh --
-- (0044's, matching lessons with each lead's history: its calls so far for its
--  score, the history before each dial for a lesson's record)
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

  -- 3. every lead still in play, scored: the data's lifts, times every lesson the
  --    lead fits (with its calls so far), times the manager's verdict on it; the
  --    teaching first among its reasons, then the three traits that move it most
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
    join public.ai_lead_history(v_intents) h on h.lead_id = l.id
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
        from ai_lessons s
       where s.active and s.removed_at is null
         and public.ai_lesson_match(s.conditions, l, h.dials, h.pickups, h.last_outcome, h.days, h.intents)
    ) t
    cross join lateral (
      select greatest(0.1, least(6, m.al * t.ta)) as fa,
             greatest(0.02, least(10, m.wl * t.tw * case mk.verdict when 'good' then 2 when 'bad' then 0.25 else 1 end)) as fw
    ) f
   where h.state not in ('suppressed', 'handoff')
  on conflict (lead_id) do update set
    p_answer = excluded.p_answer, p_win = excluded.p_win, answer_lift = excluded.answer_lift,
    win_lift = excluded.win_lift, best_hour = excluded.best_hour, reasons = excluded.reasons,
    scored_at = excluded.scored_at;
  get diagnostics v_scored = row_count;

  -- 4. each lesson against the floor's record: how many leads in play it moves,
  --    and how the dials it describes did (each judged by the lead's history
  --    before it), smoothed like a trait
  update ai_lessons s set stats = jsonb_build_object(
      'at', v_at,
      'leads', case when s.active then (select count(*) from lead_scores sc
                                         where sc.scored_at = v_at
                                           and sc.reasons @> jsonb_build_array(jsonb_build_object('kind', 'lesson', 'id', s.id))) else 0 end,
      'dials', r.dials, 'convos', r.convos, 'wins', r.wins,
      'answer_lift', round(((r.convos + ka * p0) / (r.dials + ka)) / p0, 2),
      'win_lift', round(((r.wins + kw * q0) / (r.dials + kw)) / q0, 2))
    from (select s2.id, count(x.attempt_id) as dials,
                 count(*) filter (where x.convo) as convos, count(*) filter (where x.win) as wins
            from ai_lessons s2
            left join (select d.attempt_id, d.convo, d.win, l as lr,
                              hb.dials_before, hb.pickups_before, hb.last_before, hb.days_before,
                              case when v_intents then array(select li.intent_key from lead_intents li where li.lead_id = l.id) end as intents
                         from public.ai_dials(v_days) d
                         join leads l on l.id = d.lead_id
                         join public.ai_dial_history(v_days) hb on hb.attempt_id = d.attempt_id) x
              on public.ai_lesson_match(s2.conditions, x.lr, x.dials_before, x.pickups_before, x.last_before, x.days_before, x.intents)
           where s2.removed_at is null
           group by s2.id) r
   where r.id = s.id;

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
-- Before a lesson is saved: the traits as they will be kept, how many leads in
-- play it fits now, and how the dials it describes did in the last 90 days.
create or replace function public.ai_lesson_preview(p_conditions jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_cond jsonb;
  v_int boolean;
  v_leads int; d int; c int; w int;
  p0 numeric := coalesce((public.setting('ai_model_state')->>'answer_rate')::numeric, 0.2);
  q0 numeric := coalesce((public.setting('ai_model_state')->>'win_rate')::numeric, 0.005);
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  v_cond := public.ai_clean_conditions(p_conditions);
  v_int := v_cond ? 'intent';
  select count(*) into v_leads
    from leads l join public.ai_lead_history(v_int) h on h.lead_id = l.id
   where h.state not in ('suppressed', 'handoff')
     and public.ai_lesson_match(v_cond, l, h.dials, h.pickups, h.last_outcome, h.days, h.intents);
  select count(*), count(*) filter (where x.convo), count(*) filter (where x.win) into d, c, w
    from public.ai_dials(90) x
    join leads l on l.id = x.lead_id
    join public.ai_dial_history(90) hb on hb.attempt_id = x.attempt_id
   where public.ai_lesson_match(v_cond, l, hb.dials_before, hb.pickups_before, hb.last_before, hb.days_before,
                                case when v_int then array(select li.intent_key from lead_intents li where li.lead_id = l.id) end);
  return jsonb_build_object('conditions', v_cond, 'leads', v_leads, 'dials', d, 'convos', c, 'wins', w,
                            'answer_lift', round(((c + 30 * p0) / (d + 30)) / p0, 2),
                            'win_lift', round(((w + 400 * q0) / (d + 400)) / q0, 2));
end $$;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.ai_in_range(numeric, text), public.ai_lead_history(boolean), public.ai_dial_history(int),
  public.ai_lesson_match(jsonb, public.leads, int, int, text, int, text[]), public.ai_lesson_match(jsonb, public.leads),
  public.ai_clean_conditions(jsonb), public.ai_score_refresh() from public, anon, authenticated;
revoke execute on function public.ai_lesson_preview(jsonb) from public, anon;
grant execute on function public.ai_lesson_preview(jsonb) to authenticated;
