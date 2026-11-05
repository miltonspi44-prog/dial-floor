-- Dial Floor · 0044 teaching the AI floor
--
-- The manager teaches the AI four ways, and each reaches the lead scores,
-- Gemini, or both:
--   1. lessons (ai_lessons): "leads like these are likelier, or less likely, to
--      convert, because ...". A lesson names traits (trade, state, area code,
--      source, website, phone type, tier, reviews, scraper score), all of which a
--      lead must have, each matching any of its values, and multiplies that
--      lead's chance of a win (and, if set, of a pickup) on top of what the data
--      says. Every lesson is checked against the last 90 days of calls, so the
--      page can say whether the floor's own record agrees.
--   2. verdicts on single leads (ai_lead_marks): a good pick doubles that lead's
--      chance of a win, a bad one quarters it.
--   3. corrections (ai_corrections): "this finding is right / wrong, because".
--   4. a conversation (ai_chat): ask Gemini why, or tell it what you know; it
--      answers from the floor's numbers and proposes lessons to save.
-- Gemini reads every lesson, verdict and correction (ai_memory) before each
-- analysis and each reply. Lessons and verdicts reach the scores within a
-- minute: saving one asks for a rescore, and a job looks every minute (and
-- still rescores hourly regardless).
--
-- And where it went wrong: every dial now keeps the score its lead had when it
-- was dialed (attempts.ai_p_win), so the wins it rated low and the hard noes it
-- rated high can be reviewed (ai_review), and a chance given recorded by hand
-- (0042), which has no dial of its own, now counts as a win on the lead's last
-- dial instead of not at all.
-- Applies through the management API as it is.

-- -------------------------------------------------------------------- tables --
create table if not exists public.ai_lessons (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  conditions jsonb not null,           -- {"trade": "roofing,siding", "state": "FL"}: every trait, any of its values
  win_mult numeric not null default 1 check (win_mult between 0.05 and 5),
  answer_mult numeric not null default 1 check (answer_mult between 0.2 and 5),
  note text not null,                  -- the manager's why, in their words: Gemini reads it
  source text not null default 'manual' check (source in ('manual', 'chat', 'brief', 'review')),
  active boolean not null default true,
  removed_at timestamptz,              -- kept, not erased: what was once taught stays on record
  stats jsonb                          -- ai_score_refresh: the leads it touches now and how its leads did
);
create index if not exists ai_lessons_created_by_idx on public.ai_lessons (created_by);

create table if not exists public.ai_lead_marks (
  lead_id bigint primary key references public.leads(id) on delete cascade,
  verdict text check (verdict in ('good', 'bad')),   -- null: cleared
  note text,
  marked_by uuid references public.profiles(id) on delete set null,
  marked_at timestamptz not null default now()
);
create index if not exists ai_lead_marks_marked_by_idx on public.ai_lead_marks (marked_by);

create table if not exists public.ai_corrections (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  brief_id bigint references public.ai_briefs(id) on delete set null,
  item text not null,                  -- the finding as Gemini wrote it
  verdict text not null check (verdict in ('right', 'wrong')),
  note text,
  removed_at timestamptz
);
create index if not exists ai_corrections_created_by_idx on public.ai_corrections (created_by);
create unique index if not exists ai_corrections_item_uq on public.ai_corrections (brief_id, md5(item)) where removed_at is null;

create table if not exists public.ai_chat (
  id bigint generated always as identity primary key,
  thread int not null,
  created_at timestamptz not null default now(),
  role text not null check (role in ('manager', 'ai')),
  author uuid references public.profiles(id) on delete set null,
  text text not null default '',
  proposals jsonb not null default '{}'::jsonb,   -- {"lessons": [...], "lists": [...]}
  model text,
  error text
);
create index if not exists ai_chat_thread_idx on public.ai_chat (thread, id);
create index if not exists ai_chat_author_idx on public.ai_chat (author);

-- the score a lead had when it was dialed: what the AI believed before the outcome
alter table public.attempts add column if not exists ai_p_win numeric, add column if not exists ai_p_answer numeric;

alter table public.ai_lessons enable row level security;
alter table public.ai_lead_marks enable row level security;
alter table public.ai_corrections enable row level security;
alter table public.ai_chat enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'ai_lessons' and policyname = 'ai_lessons_read') then
    create policy ai_lessons_read on public.ai_lessons for select to authenticated using (public.is_manager());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'ai_lead_marks' and policyname = 'ai_lead_marks_read') then
    create policy ai_lead_marks_read on public.ai_lead_marks for select to authenticated using (public.is_manager());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'ai_corrections' and policyname = 'ai_corrections_read') then
    create policy ai_corrections_read on public.ai_corrections for select to authenticated using (public.is_manager());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'ai_chat' and policyname = 'ai_chat_read') then
    create policy ai_chat_read on public.ai_chat for select to authenticated using (public.is_manager());
  end if;
end $$;

-- ------------------------------------------------------- the score at a dial --
create or replace function public.ai_stamp_attempt()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select s.p_win, s.p_answer into new.ai_p_win, new.ai_p_answer from lead_scores s where s.lead_id = new.lead_id;
  return new;
end $$;
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'attempts_ai_stamp' and tgrelid = 'public.attempts'::regclass) then
    create trigger attempts_ai_stamp before insert on public.attempts for each row execute function public.ai_stamp_attempt();
  end if;
end $$;

-- ---------------------------------------------------------- lesson matching --
-- Does this lead have every trait the lesson names? The values are those of
-- ai_lead_keys (0043), except trade: a lesson's trade matches any of a lead's
-- trades, not only its first.
create or replace function public.ai_lesson_match(c jsonb, l public.leads)
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
       when 'reviews' then (case when coalesce(l.review_count, 0) = 0 then '0' when l.review_count < 10 then '1-9'
                                 when l.review_count < 50 then '10-49' else '50+' end) = any (string_to_array(e.v, ','))
       when 'score'   then (case when l.score is null then '(none)' when l.score < 40 then '<40' when l.score < 60 then '40-59'
                                 when l.score < 80 then '60-79' else '80+' end) = any (string_to_array(e.v, ','))
     end, false))
$$;

-- A lesson's traits as the manager or Gemini gave them, checked and tidied:
-- known traits only, each value in the form the lead's own traits take.
create or replace function public.ai_clean_conditions(c jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  out jsonb := '{}'::jsonb;
  k text; v text; x text;
  vals text[];
  pat text;
begin
  if c is null or jsonb_typeof(c) <> 'object' or c = '{}'::jsonb then
    raise exception 'a lesson needs at least one trait';
  end if;
  for k, v in select e.key, e.value from jsonb_each_text(c) e loop
    pat := case k
      when 'trade'   then '^[a-z0-9_]+$'
      when 'state'   then '^[A-Z]{2}$'
      when 'area'    then '^[2-9][0-9]{2}$'
      when 'phone'   then '^(mobile|landline|voip|unknown)$'
      when 'website' then '^(none|social|site|unreachable|unknown)$'
      when 'source'  then '^[a-z0-9_]+$'
      when 'tier'    then '^[A-Z]$'
      when 'reviews' then '^(0|1-9|10-49|50\+)$'
      when 'score'   then '^(<40|40-59|60-79|80\+)$'
    end;
    if pat is null then raise exception 'a lesson cannot use the trait "%"', k; end if;
    vals := array(select distinct case when k in ('state', 'tier') then upper(trim(y)) else lower(trim(y)) end
                    from unnest(string_to_array(coalesce(v, ''), ',')) y where trim(y) <> '');
    if cardinality(vals) = 0 then raise exception 'the trait "%" needs a value', k; end if;
    if cardinality(vals) > 12 then raise exception 'the trait "%" takes at most 12 values', k; end if;
    foreach x in array vals loop
      if x !~ pat then raise exception '"%" is not a % this system knows', x, k; end if;
    end loop;
    out := out || jsonb_build_object(k, array_to_string(array(select y from unnest(vals) y order by y), ','));
  end loop;
  if (select count(*) from jsonb_object_keys(out)) > 6 then raise exception 'a lesson takes at most 6 traits'; end if;
  return out;
end $$;

-- ---------------------------------------------------------- the floor's dials --
-- Every logged dial of the last p_days with what it came to: a conversation, a
-- win, and the points an agent's record counts (0043). A chance given or a sale
-- recorded by hand (0042) has no dial of its own: it counts as a win on the
-- lead's last dial before it.
create or replace function public.ai_dials(p_days int)
returns table (attempt_id bigint, lead_id bigint, agent_id uuid, convo boolean, win boolean, pts numeric)
language sql stable set search_path = public as $$
  with d as (
    select a.id, a.lead_id, a.agent_id, a.clicked_at, a.connected, a.disposition
      from attempts a
     where a.clicked_at >= now() - make_interval(days => p_days)
       and a.disposition is not null and a.disposition not in ('skipped', 'not_placed')
  ),
  late as (
    select distinct on (h.lead_id) d.id
      from handoff_ledger h
      join d on d.lead_id = h.lead_id and d.clicked_at <= h.handed_at
     where not exists (select 1 from attempts w where w.lead_id = h.lead_id and w.disposition in ('chance_website', 'sale_closed'))
     order by h.lead_id, d.clicked_at desc
  )
  select d.id, d.lead_id, d.agent_id,
         public.is_conversation(d.connected, d.disposition),
         d.disposition in ('chance_website', 'sale_closed') or d.id in (select id from late),
         case when d.disposition in ('chance_website', 'sale_closed') or d.id in (select id from late) then 1.0
              when d.disposition in ('callback', 'email_requested') then 0.3 else 0 end
    from d
$$;

-- --------------------------------------------------------- ai_score_refresh --
-- (0043's, learning from ai_dials, with the manager's lessons and verdicts on
--  top of the data, each lesson's record, and one refresh at a time)
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
    join lead_state ls on ls.lead_id = l.id
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
       where s.active and s.removed_at is null and public.ai_lesson_match(s.conditions, l)
    ) t
    cross join lateral (
      select greatest(0.1, least(6, m.al * t.ta)) as fa,
             greatest(0.02, least(10, m.wl * t.tw * case mk.verdict when 'good' then 2 when 'bad' then 0.25 else 1 end)) as fw
    ) f
   where ls.state not in ('suppressed', 'handoff')
  on conflict (lead_id) do update set
    p_answer = excluded.p_answer, p_win = excluded.p_win, answer_lift = excluded.answer_lift,
    win_lift = excluded.win_lift, best_hour = excluded.best_hour, reasons = excluded.reasons,
    scored_at = excluded.scored_at;
  get diagnostics v_scored = row_count;

  -- 4. each lesson against the floor's record: how many leads in play it moves,
  --    and how the leads it describes did on the phone, smoothed like a trait
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
            left join (select d.attempt_id, d.convo, d.win, l as lr
                         from public.ai_dials(v_days) d join leads l on l.id = d.lead_id) x
              on public.ai_lesson_match(s2.conditions, x.lr)
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

-- --------------------------------------------------------- rescore on demand --
-- A lesson or a verdict asks for a rescore; the minute job does it (scoring
-- every lead takes longer than a browser's call may run), and rescores hourly
-- regardless, as the hourly job did.
create or replace function public.ai_rescore_soon()
returns void language sql security definer set search_path = public as $$
  insert into app_settings (key, value) values ('ai_rescore_wanted', jsonb_build_object('at', clock_timestamp()))
    on conflict (key) do update set value = excluded.value, updated_at = now()
$$;

create or replace function public.ai_rescore_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_wanted timestamptz := (public.setting('ai_rescore_wanted')->>'at')::timestamptz;
  v_last timestamptz := (public.setting('ai_model_state')->>'at')::timestamptz;
begin
  if v_last is null or v_last < now() - interval '1 hour' or v_wanted > v_last then
    return public.ai_score_refresh() || '{"ran": true}';
  end if;
  return jsonb_build_object('ran', false);
end $$;

-- ------------------------------------------------------------------- lessons --
create or replace function public.ai_lesson_save(p_id bigint, p_conditions jsonb, p_win numeric,
                                                 p_answer numeric default 1, p_note text default null,
                                                 p_source text default 'manual')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cond jsonb;
  v_note text := trim(coalesce(p_note, ''));
  r ai_lessons%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  v_cond := public.ai_clean_conditions(p_conditions);
  if length(v_note) < 3 then raise exception 'say why: the AI reads your reason along with the lesson'; end if;
  if length(v_note) > 600 then raise exception 'keep the reason under 600 characters'; end if;
  if p_win is null or p_win < 0.05 or p_win > 5 then raise exception 'the effect on a win is between 0.05× and 5×'; end if;
  if coalesce(p_answer, 1) < 0.2 or coalesce(p_answer, 1) > 5 then raise exception 'the effect on a pickup is between 0.2× and 5×'; end if;
  if p_win = 1 and coalesce(p_answer, 1) = 1 then raise exception 'a lesson has to change something: likelier or less likely'; end if;
  if coalesce(p_source, 'manual') not in ('manual', 'chat', 'brief', 'review') then raise exception 'unknown source'; end if;
  if p_id is null then
    insert into ai_lessons (created_by, conditions, win_mult, answer_mult, note, source)
      values (auth.uid(), v_cond, p_win, coalesce(p_answer, 1), v_note, coalesce(p_source, 'manual'))
      returning * into r;
  else
    update ai_lessons set conditions = v_cond, win_mult = p_win, answer_mult = coalesce(p_answer, 1), note = v_note,
                          active = true, updated_at = now()
     where id = p_id and removed_at is null
     returning * into r;
    if not found then raise exception 'that lesson is gone'; end if;
  end if;
  perform public.ai_rescore_soon();
  return to_jsonb(r);
end $$;

-- pause (false), resume (true), or remove (p_remove) a lesson
create or replace function public.ai_lesson_set(p_id bigint, p_active boolean, p_remove boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r ai_lessons%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  update ai_lessons set active = case when p_remove then false else p_active end,
                        removed_at = case when p_remove then now() end, updated_at = now()
   where id = p_id and removed_at is null
   returning * into r;
  if not found then raise exception 'that lesson is gone'; end if;
  perform public.ai_rescore_soon();
  return to_jsonb(r);
end $$;

-- ------------------------------------------------------------ lead verdicts --
-- good doubles a lead's chance of a win, bad quarters it; null clears it. On a
-- lead already won or out of play it changes no score, but Gemini still reads
-- why (a win the AI rated low, explained, is the best lesson there is).
create or replace function public.ai_mark_lead(p_lead bigint, p_verdict text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r ai_lead_marks%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if nullif(p_verdict, '') is not null and p_verdict not in ('good', 'bad') then raise exception 'a verdict is good or bad'; end if;
  if length(coalesce(p_note, '')) > 600 then raise exception 'keep the note under 600 characters'; end if;
  if not exists (select 1 from leads where id = p_lead) then raise exception 'lead not found'; end if;
  insert into ai_lead_marks (lead_id, verdict, note, marked_by, marked_at)
    values (p_lead, nullif(p_verdict, ''), nullif(trim(coalesce(p_note, '')), ''), auth.uid(), now())
    on conflict (lead_id) do update set verdict = excluded.verdict, note = excluded.note,
                                        marked_by = excluded.marked_by, marked_at = excluded.marked_at
    returning * into r;
  perform public.ai_rescore_soon();
  return to_jsonb(r);
end $$;

-- -------------------------------------------------------------- corrections --
create or replace function public.ai_correct(p_brief bigint, p_item text, p_verdict text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r ai_corrections%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_verdict not in ('right', 'wrong') then raise exception 'a correction is right or wrong'; end if;
  if not exists (select 1 from ai_briefs where id = p_brief and ok) then raise exception 'that analysis is gone'; end if;
  if length(trim(coalesce(p_item, ''))) = 0 or length(p_item) > 2000 then raise exception 'which finding?'; end if;
  if length(coalesce(p_note, '')) > 600 then raise exception 'keep the note under 600 characters'; end if;
  insert into ai_corrections (created_by, brief_id, item, verdict, note)
    values (auth.uid(), p_brief, trim(p_item), p_verdict, nullif(trim(coalesce(p_note, '')), ''))
    on conflict (brief_id, md5(item)) where removed_at is null
    do update set verdict = excluded.verdict, note = excluded.note, created_by = excluded.created_by, created_at = now()
    returning * into r;
  return to_jsonb(r);
end $$;

create or replace function public.ai_correction_remove(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  update ai_corrections set removed_at = now() where id = p_id and removed_at is null;
end $$;

-- ------------------------------------------------------------------- review --
-- Where the AI went wrong in the last p_days: every win whose lead it rated at
-- or below the floor's average, and every hard no (not interested, has a
-- provider, do not call) on a lead it rated twice the average or more. The
-- score is the one stamped on the dial; before 0044 there was none, and the
-- lead's own latest score (frozen once it was handed off) stands in.
create or replace function public.ai_review_rows(p_days int)
returns table (kind text, lead_id bigint, at timestamptz, outcome text, agent_id uuid, p_win numeric, at_dial boolean)
language sql stable security definer set search_path = public as $$
  with q as (select coalesce((public.setting('ai_model_state')->>'win_rate')::numeric, 0.01) as q0),
  wins as (
    select distinct on (h.lead_id) h.lead_id, h.handed_at as at, h.kind as outcome, h.agent_id,
           coalesce(a.ai_p_win, sc.p_win) as p_win, a.ai_p_win is not null as at_dial
      from handoff_ledger h
      left join lateral (select a.ai_p_win from attempts a
                          where a.lead_id = h.lead_id and a.clicked_at <= h.handed_at
                          order by a.clicked_at desc limit 1) a on true
      left join lead_scores sc on sc.lead_id = h.lead_id
     where h.handed_at >= now() - make_interval(days => p_days)
     order by h.lead_id, h.handed_at desc
  ),
  noes as (
    select distinct on (a.lead_id) a.lead_id, a.clicked_at as at, a.disposition as outcome, a.agent_id,
           coalesce(a.ai_p_win, sc.p_win) as p_win, a.ai_p_win is not null as at_dial
      from attempts a
      left join lead_scores sc on sc.lead_id = a.lead_id
     where a.clicked_at >= now() - make_interval(days => p_days)
       and a.disposition in ('not_interested_hard', 'has_provider', 'dnc')
     order by a.lead_id, a.clicked_at desc
  )
  select 'underrated', w.lead_id, w.at, w.outcome, w.agent_id, w.p_win, w.at_dial
    from wins w, q where w.p_win is not null and w.p_win <= q.q0
  union all
  select 'overrated', n.lead_id, n.at, n.outcome, n.agent_id, n.p_win, n.at_dial
    from noes n, q where n.p_win >= 2 * q.q0
$$;

create or replace function public.ai_review(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 30), 90));
  q0 numeric := coalesce((public.setting('ai_model_state')->>'win_rate')::numeric, 0.01);
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  return jsonb_build_object(
    'days', v_days,
    'win_rate', q0,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', r.kind, 'lead_id', l.id, 'name', l.name, 'city', l.addr_city, 'state', l.addr_state,
        'trade', coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)'),
        'traits', (select jsonb_object_agg(k.kind, k.value) from public.ai_lead_keys(l) k),
        'at', r.at, 'outcome', r.outcome, 'agent', p.name,
        'p_win', round(r.p_win, 4), 'win_x', round(r.p_win / q0, 2), 'at_dial', r.at_dial,
        'reasons', coalesce(sc.reasons, '[]'::jsonb),
        'mark', case when mk.verdict is not null then jsonb_build_object('verdict', mk.verdict, 'note', mk.note) end)
        order by r.kind desc, case when r.kind = 'underrated' then r.p_win else -r.p_win end, r.at desc)
       from (select * from public.ai_review_rows(v_days) x
              order by x.kind, case when x.kind = 'underrated' then x.p_win else -x.p_win end limit 80) r
       join leads l on l.id = r.lead_id
       left join profiles p on p.id = r.agent_id
       left join lead_scores sc on sc.lead_id = l.id
       left join ai_lead_marks mk on mk.lead_id = l.id), '[]'::jsonb),
    -- calibration: the dials it scored before they happened, by how good it said
    -- they were, against what they came to
    'calibration', coalesce((select jsonb_agg(jsonb_build_object('band', b.band, 'dials', b.dials, 'wins', b.wins,
                                                                'expected', round(b.expected, 1)) order by b.ord)
       from (select case when a.ai_p_win >= 3 * q0 then 1 when a.ai_p_win >= 1.5 * q0 then 2
                         when a.ai_p_win >= 0.75 * q0 then 3 else 4 end as ord,
                    case when a.ai_p_win >= 3 * q0 then '3× the average or more' when a.ai_p_win >= 1.5 * q0 then '1.5–3×'
                         when a.ai_p_win >= 0.75 * q0 then 'about average' else 'below average' end as band,
                    count(*) as dials, count(*) filter (where d.win) as wins, sum(a.ai_p_win) as expected
               from public.ai_dials(v_days) d join attempts a on a.id = d.attempt_id
              where a.ai_p_win is not null
              group by 1, 2) b), '[]'::jsonb),
    'stamped_since', (select min(clicked_at) from attempts where ai_p_win is not null));
end $$;

-- ------------------------------------------------------------------- memory --
-- What Gemini reads before every analysis and every reply: the lessons (with
-- each one's record), the verdicts on single leads (traits only, never a name
-- or a number), the corrections, and where the scores went wrong lately.
create or replace function public.ai_memory()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'effects', 'a lesson multiplies the chance of a win by win_x and of a pickup by pickup_x for every lead with all its traits',
    'lessons', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'traits', s.conditions, 'win_x', s.win_mult, 'pickup_x', s.answer_mult, 'why', s.note,
        'active', s.active, 'taught', s.created_at::date, 'from', s.source,
        'leads_it_moves_now', s.stats->'leads',
        'record_90d', jsonb_build_object('dials', s.stats->'dials', 'convos', s.stats->'convos', 'wins', s.stats->'wins',
                                         'win_lift', s.stats->'win_lift', 'answer_lift', s.stats->'answer_lift')) order by s.id)
       from ai_lessons s where s.removed_at is null), '[]'::jsonb),
    'lead_verdicts', coalesce((select jsonb_agg(jsonb_build_object(
        'verdict', mk.verdict, 'why', mk.note, 'marked', mk.marked_at::date,
        'traits', (select jsonb_object_agg(k.kind, k.value) from public.ai_lead_keys(l) k),
        'last_outcome', (select a.disposition from attempts a where a.lead_id = l.id and a.disposition is not null
                          order by a.clicked_at desc limit 1),
        'won', exists (select 1 from handoff_ledger h where h.lead_id = l.id)) order by mk.marked_at desc)
       from (select * from ai_lead_marks where verdict is not null order by marked_at desc limit 40) mk
       join leads l on l.id = mk.lead_id), '[]'::jsonb),
    'corrections', coalesce((select jsonb_agg(jsonb_build_object('about', c.item, 'verdict', c.verdict, 'why', c.note,
                                                                 'on', c.created_at::date) order by c.id desc)
       from (select * from ai_corrections where removed_at is null order by id desc limit 30) c), '[]'::jsonb),
    'misses_30d', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', r.kind, 'outcome', r.outcome, 'rated_x', round(r.p_win / greatest(coalesce((public.setting('ai_model_state')->>'win_rate')::numeric, 0.01), 0.0001), 2),
        'traits', (select jsonb_object_agg(k.kind, k.value) from public.ai_lead_keys(l) k)))
       from (select * from public.ai_review_rows(30) x
              order by x.kind, case when x.kind = 'underrated' then x.p_win else -x.p_win end limit 30) r
       join leads l on l.id = r.lead_id), '[]'::jsonb))
$$;

-- --------------------------------------------------------------------- chat --
create or replace function public.ai_chat_send(p_text text, p_new boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_text text := trim(coalesce(p_text, ''));
  v_thread int;
  v_last ai_chat%rowtype;
  v_id bigint;
  v_req bigint;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  if length(v_text) = 0 then raise exception 'say something first'; end if;
  if length(v_text) > 2000 then raise exception 'keep a message under 2,000 characters'; end if;
  v_thread := coalesce((select max(thread) from ai_chat), 0);
  if coalesce(p_new, false) or v_thread = 0 then v_thread := v_thread + 1; end if;
  select * into v_last from ai_chat where thread = v_thread order by id desc limit 1;
  if found and v_last.role = 'manager' and v_last.created_at > now() - interval '3 minutes' then
    return jsonb_build_object('ok', false, 'thread', v_thread, 'why', 'Gemini is still answering your last message.');
  end if;
  insert into ai_chat (thread, role, author, text) values (v_thread, 'manager', v_uid, v_text) returning id into v_id;
  begin
    execute format($q$
      select net.http_post(
        url := 'https://fevjrcxmktjwbaozbngo.supabase.co/functions/v1/floor-ai',
        headers := jsonb_build_object('content-type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_cron_secret')),
        body := %L::jsonb,
        timeout_milliseconds := 150000) $q$,
      jsonb_build_object('task', 'chat', 'thread', v_thread, 'requested_by', v_uid)::text)
      into v_req;
  exception when undefined_function or undefined_table or invalid_schema_name or insufficient_privilege then
    insert into ai_chat (thread, role, text, error)
      values (v_thread, 'ai', '', 'There is no scheduler on this database to carry the message to Gemini.');
    return jsonb_build_object('ok', false, 'thread', v_thread, 'id', v_id, 'why', 'no scheduler on this database');
  end;
  return jsonb_build_object('ok', true, 'thread', v_thread, 'id', v_id, 'request_id', v_req);
end $$;

-- a conversation (the latest when p_thread is null), and whether a reply is due
create or replace function public.ai_chat_thread(p_thread int default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_thread int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  v_thread := coalesce(p_thread, (select max(thread) from ai_chat), 1);
  return jsonb_build_object(
    'thread', v_thread,
    'threads', coalesce((select max(thread) from ai_chat), 0),
    'messages', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'at', c.created_at, 'role', c.role, 'author', p.name, 'text', c.text,
        'proposals', c.proposals, 'model', c.model, 'error', c.error) order by c.id)
       from (select * from ai_chat where thread = v_thread order by id desc limit 60) c
       left join profiles p on p.id = c.author), '[]'::jsonb),
    'waiting', coalesce((select c.role = 'manager' and c.created_at > now() - interval '3 minutes'
                           from ai_chat c where c.thread = v_thread order by c.id desc limit 1), false));
end $$;

-- ---------------------------------------------------------- the teach panel --
create or replace function public.ai_teach()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_manager() then raise exception 'manager only'; end if;
  return jsonb_build_object(
    'lessons', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'conditions', s.conditions, 'win_mult', s.win_mult, 'answer_mult', s.answer_mult, 'note', s.note,
        'source', s.source, 'active', s.active, 'created_at', s.created_at, 'updated_at', s.updated_at,
        'author', p.name, 'stats', s.stats,
        'pending', s.stats is null or (s.stats->>'at')::timestamptz < s.updated_at) order by s.active desc, s.id desc)
       from ai_lessons s left join profiles p on p.id = s.created_by
      where s.removed_at is null), '[]'::jsonb),
    'marks', coalesce((select jsonb_agg(jsonb_build_object(
        'lead_id', l.id, 'name', l.name, 'city', l.addr_city, 'state', l.addr_state,
        'trade', coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)'),
        'verdict', mk.verdict, 'note', mk.note, 'at', mk.marked_at, 'author', p.name,
        'won', exists (select 1 from handoff_ledger h where h.lead_id = l.id)) order by mk.marked_at desc)
       from (select * from ai_lead_marks where verdict is not null order by marked_at desc limit 100) mk
       join leads l on l.id = mk.lead_id
       left join profiles p on p.id = mk.marked_by), '[]'::jsonb),
    'corrections', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'brief_id', c.brief_id, 'item', c.item, 'verdict', c.verdict, 'note', c.note,
        'at', c.created_at, 'author', p.name) order by c.id desc)
       from ai_corrections c left join profiles p on p.id = c.created_by
      where c.removed_at is null), '[]'::jsonb),
    'rescore', jsonb_build_object('wanted', public.setting('ai_rescore_wanted')->'at',
                                  'scored', public.setting('ai_model_state')->'at'));
end $$;

-- ------------------------------------------------------------------ ai_floor --
-- (0043's, with each top lead's traits and the manager's verdict on it)
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
                 'best_hour', s.best_hour, 'reasons', s.reasons, 'callable_now', public.local_ok(l.tz),
                 'traits', (select jsonb_object_agg(k.kind, k.value) from public.ai_lead_keys(l) k),
                 'mark', case when mk.verdict is not null then jsonb_build_object('verdict', mk.verdict, 'note', mk.note) end) as j
          from lead_scores s
          join leads l on l.id = s.lead_id
          join lead_state ls on ls.lead_id = l.id
          left join ai_lead_marks mk on mk.lead_id = l.id
         where ls.state in ('fresh', 'queued') and (ls.rest_until is null or ls.rest_until <= now())
         order by s.p_win desc, s.p_answer desc
         limit 40) t), '[]'::jsonb),
    'brief', (select to_jsonb(b) from (select id, created_at, source, model, brief from ai_briefs where ok order by id desc limit 1) b),
    'last_attempt', (select to_jsonb(b) from (select id, created_at, source, ok, model, error from ai_briefs order by id desc limit 1) b),
    'requested', public.setting('ai_brief_requested'));
end $$;

-- ----------------------------------------------------------------- schedules --
-- The hourly scoring job becomes a minute job that rescores when a lesson or a
-- verdict asks, or when the last rescore is an hour old.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'ai: pg_cron is not installed here, so no jobs were changed.';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname in ('dial-floor ai scores', 'dial-floor ai rescore');
  perform cron.schedule('dial-floor ai rescore', '* * * * *', 'select public.ai_rescore_tick()');
end $$;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.ai_stamp_attempt(), public.ai_lesson_match(jsonb, public.leads),
  public.ai_clean_conditions(jsonb), public.ai_dials(int), public.ai_rescore_soon(), public.ai_rescore_tick(),
  public.ai_review_rows(int), public.ai_memory() from public, anon, authenticated;
revoke execute on function public.ai_lesson_save(bigint, jsonb, numeric, numeric, text, text),
  public.ai_lesson_set(bigint, boolean, boolean), public.ai_mark_lead(bigint, text, text),
  public.ai_correct(bigint, text, text, text), public.ai_correction_remove(bigint), public.ai_review(int),
  public.ai_chat_send(text, boolean), public.ai_chat_thread(int), public.ai_teach() from public, anon;
grant execute on function public.ai_lesson_save(bigint, jsonb, numeric, numeric, text, text),
  public.ai_lesson_set(bigint, boolean, boolean), public.ai_mark_lead(bigint, text, text),
  public.ai_correct(bigint, text, text, text), public.ai_correction_remove(bigint), public.ai_review(int),
  public.ai_chat_send(text, boolean), public.ai_chat_thread(int), public.ai_teach() to authenticated;

-- the first rescore with the late wins counted (run on its own when applying live)
select public.ai_score_refresh();
