-- Dial Floor · 0013 coaching (Phase 1.5)
--   · D2 digests: each agent's day or week against the floor and the targets,
--     from numbers, taps and notes (Fork 1-A: no transcripts): two things going
--     well and one to work on, their best hour, and the counters that are keeping
--     calls alive for the objections they hear. Agents see their own; managers
--     see everyone's
--   · F2 outcome mining (managers): which objections come up and how those calls
--     end, where calls die by talk time, how conversations end, and the words in
--     notes of calls kept alive vs lost. Calls that ended at the gatekeeper are
--     left out: the floor doesn't try to cross gatekeepers (the F2 note)

-- a conversation: a live person on the line, past the gatekeeper
create or replace function public.is_conversation(p_connected boolean, p_dispo text)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(p_connected, false) and p_dispo is distinct from 'gatekeeper_end'
$$;

-- ---------------------------------------------------------------------- D2 --
create or replace function public.digest(p_agent uuid, p_days int default 7)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 7), 90));
  v_from timestamptz := public.business_day_start() - make_interval(days => v_days - 1);
  v_tz text := public.business_tz();
  me jsonb; fl jsonb; tg jsonb; metrics jsonb; best jsonb; objs jsonb; picks jsonb; v_stats jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_agent is distinct from auth.uid() and not is_manager() then
    raise exception 'agents see their own digest';
  end if;

  -- the same aggregates for the agent (me) and the whole floor (fl)
  with a as (
    select a.*, is_conversation(a.connected, a.disposition) as convo
      from attempts a where a.clicked_at >= v_from
  ), cb as (
    select c.agent_id, c.status from callbacks c
     where c.due_at >= v_from and c.due_at < now() and c.status in ('done', 'missed')
  )
  select
    (select jsonb_build_object(
       'dials', count(*),
       'days_active', count(distinct (clicked_at at time zone v_tz)::date),
       'picked_up', count(*) filter (where call_result = 'answered' or coalesce(connected, false)),
       'conversations', count(*) filter (where convo),
       'kept', count(*) filter (where convo and kept_alive(disposition)),
       'won', count(*) filter (where disposition in ('chance_website', 'sale_closed')),
       'talk_seconds', coalesce(sum(duration_seconds) filter (where convo), 0),
       'noted', count(*) filter (where convo and nullif(btrim(note), '') is not null),
       'tapped', count(*) filter (where convo and exists (select 1 from card_taps t where t.attempt_id = a.id)),
       'cb_done', (select count(*) from cb where cb.agent_id = p_agent and cb.status = 'done'),
       'cb_missed', (select count(*) from cb where cb.agent_id = p_agent and cb.status = 'missed'))
       from a where a.agent_id = p_agent),
    (select jsonb_build_object(
       'dials', count(*),
       'agent_days', (select count(*) from (select distinct agent_id, (clicked_at at time zone v_tz)::date from a) d),
       'picked_up', count(*) filter (where call_result = 'answered' or coalesce(connected, false)),
       'conversations', count(*) filter (where convo),
       'kept', count(*) filter (where convo and kept_alive(disposition)),
       'won', count(*) filter (where disposition in ('chance_website', 'sale_closed')),
       'noted', count(*) filter (where convo and nullif(btrim(note), '') is not null),
       'tapped', count(*) filter (where convo and exists (select 1 from card_taps t where t.attempt_id = a.id)),
       'cb_done', (select count(*) from cb where cb.status = 'done'),
       'cb_missed', (select count(*) from cb where cb.status = 'missed'))
       from a)
    into me, fl;

  select jsonb_build_object(
      'dials', max(target) filter (where metric = 'dials_per_day'),
      'connects', max(target) filter (where metric = 'connects_per_day'),
      'handoffs', max(target) filter (where metric = 'handoffs_per_day'))
    into tg from kpi_targets where scope = 'agent_day';

  -- each metric against its reference (a target where one is set, else the floor);
  -- ok = enough of a sample to say anything
  with m(key, value, reference, ok) as (
    values
      ('pace',
       (me->>'dials')::numeric / nullif((me->>'days_active')::numeric, 0),
       coalesce((tg->>'dials')::numeric, (fl->>'dials')::numeric / nullif((fl->>'agent_days')::numeric, 0)),
       (me->>'days_active')::int >= 1 and (me->>'dials')::int >= 20),
      ('conversation_rate',
       (me->>'conversations')::numeric / nullif((me->>'dials')::numeric, 0),
       (fl->>'conversations')::numeric / nullif((fl->>'dials')::numeric, 0),
       (me->>'dials')::int >= 30),
      ('kept_rate',
       (me->>'kept')::numeric / nullif((me->>'conversations')::numeric, 0),
       (fl->>'kept')::numeric / nullif((fl->>'conversations')::numeric, 0),
       (me->>'conversations')::int >= 5),
      ('handoff_rate',
       (me->>'won')::numeric / nullif((me->>'conversations')::numeric, 0),
       (fl->>'won')::numeric / nullif((fl->>'conversations')::numeric, 0),
       -- handoffs are rare: only judge once the floor's rate would predict 2+
       (me->>'conversations')::numeric * (fl->>'won')::numeric / nullif((fl->>'conversations')::numeric, 0) >= 2),
      ('notes',
       (me->>'noted')::numeric / nullif((me->>'conversations')::numeric, 0),
       greatest((fl->>'noted')::numeric / nullif((fl->>'conversations')::numeric, 0), 0.5),
       (me->>'conversations')::int >= 5),
      ('battlecards',
       (me->>'tapped')::numeric / nullif((me->>'conversations')::numeric, 0),
       (fl->>'tapped')::numeric / nullif((fl->>'conversations')::numeric, 0),
       (me->>'conversations')::int >= 5 and (fl->>'tapped')::int > 0),
      ('callbacks_kept',
       (me->>'cb_done')::numeric / nullif((me->>'cb_done')::numeric + (me->>'cb_missed')::numeric, 0),
       (fl->>'cb_done')::numeric / nullif((fl->>'cb_done')::numeric + (fl->>'cb_missed')::numeric, 0),
       (me->>'cb_done')::int + (me->>'cb_missed')::int >= 2)
  ), scored as (
    select key, value, reference, ok and value is not null and reference > 0 as ok,
           case when reference > 0 then value / reference end as ratio
      from m
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', key, 'value', round(value, 4), 'reference', round(reference, 4),
                                               'ratio', round(ratio, 3), 'ok', ok) order by key), '[]'::jsonb),
         jsonb_build_object(
           'strengths', coalesce((select jsonb_agg(key order by ratio desc)
                                    from (select key, ratio from scored where ok and ratio >= 1.05
                                          order by ratio desc limit 2) s), '[]'::jsonb),
           -- the one thing to work on: the most basic lever that is clearly behind (80% or
           -- less of its reference), activity and outcomes before habits; else the lowest
           'fix', coalesce(
             (select key from scored where ok and ratio <= 0.8
               order by array_position(array['pace', 'conversation_rate', 'kept_rate', 'handoff_rate',
                                             'callbacks_kept', 'battlecards', 'notes'], key)
               limit 1),
             (select key from scored where ok and ratio <= 0.95 order by ratio limit 1)))
    into metrics, picks
    from scored;

  -- the lead-local hour this agent reaches people most often (10+ dials to count)
  select jsonb_build_object('hour', h, 'dials', n, 'rate', round(100.0 * c / n, 1))
    into best
    from (select extract(hour from a.clicked_at at time zone coalesce(l.tz, 'America/New_York'))::int as h,
                 count(*) as n, count(*) filter (where is_conversation(a.connected, a.disposition)) as c
            from attempts a join leads l on l.id = a.lead_id
           where a.agent_id = p_agent and a.clicked_at >= now() - interval '30 days'
           group by 1 having count(*) >= 10) x
   order by c::numeric / n desc, n desc limit 1;

  -- objections this agent heard, how those calls ended, and the counter that is
  -- keeping them alive across the floor (5+ uses, last 90 days)
  v_stats := public.battlecard_stats(90);
  select coalesce(jsonb_agg(jsonb_build_object(
           'objection', b.objection, 'heard', x.heard, 'kept', x.kept,
           'floor_rate', (select round((s->>'kept')::numeric / nullif((s->>'calls')::numeric, 0), 3)
                            from jsonb_array_elements(v_stats) s where (s->>'card_id')::bigint = b.id),
           'try', (select c from jsonb_array_elements(v_stats) s,
                               jsonb_array_elements(s->'counters') c
                    where (s->>'card_id')::bigint = b.id and (c->>'uses')::int >= 5
                    order by (c->>'kept')::numeric / (c->>'uses')::numeric desc limit 1))
         order by x.heard desc), '[]'::jsonb)
    into objs
    from (select t.card_id, count(distinct t.attempt_id) as heard,
                 count(distinct t.attempt_id) filter (where kept_alive(a.disposition)) as kept
            from card_taps t join attempts a on a.id = t.attempt_id
           where a.agent_id = p_agent and a.clicked_at >= v_from and a.disposition is not null
           group by t.card_id) x
    join battlecards b on b.id = x.card_id;

  return jsonb_build_object(
    'agent', (select jsonb_build_object('id', id, 'name', name) from profiles where id = p_agent),
    'from', v_from, 'days', v_days, 'me', me, 'floor', fl, 'targets', tg,
    'metrics', metrics, 'strengths', picks->'strengths', 'fix', picks->'fix',
    'best_hour', best, 'objections', objs);
end $$;

-- ---------------------------------------------------------------------- F2 --
create or replace function public.insights(p_days int default 30)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 30), 366));
  v_from timestamptz := public.business_day_start() - make_interval(days => v_days - 1);
  r jsonb; v_stats jsonb;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  v_stats := public.battlecard_stats(v_days);
  with c as (  -- conversations past the gatekeeper, logged
    select a.id, a.disposition, a.note, a.matched, a.duration_seconds, kept_alive(a.disposition) as kept,
           a.disposition in ('chance_website', 'sale_closed') as won
      from attempts a
     where a.clicked_at >= v_from and a.disposition is not null and is_conversation(a.connected, a.disposition)
  ),
  heard as (
    select t.card_id, c.id, bool_or(c.kept) as kept, bool_or(c.won) as won
      from card_taps t join c on c.id = t.attempt_id group by t.card_id, c.id
  ),
  words as (  -- words of 4+ letters in notes, stop words out; counted once per note
    select c.kept, w, count(distinct c.id) as notes
      from c, regexp_split_to_table(lower(c.note), '[^a-z'']+') w
     where nullif(btrim(c.note), '') is not null and length(w) >= 4 and ts_lexize('english_stem', w) <> '{}'
     group by c.kept, w
  )
  select jsonb_build_object(
    'from', v_from, 'days', v_days,
    'conversations', (select count(*) from c),
    'kept', (select count(*) from c where kept),
    'objections', (select coalesce(jsonb_agg(jsonb_build_object(
          'objection', b.objection, 'heard', h.n, 'kept', h.kept, 'won', h.won,
          'best_counter', (select cc from jsonb_array_elements(v_stats) s,
                                          jsonb_array_elements(s->'counters') cc
                            where (s->>'card_id')::bigint = b.id and (cc->>'uses')::int >= 3
                            order by (cc->>'kept')::numeric / (cc->>'uses')::numeric desc, (cc->>'uses')::int desc limit 1))
        order by h.n desc), '[]'::jsonb)
       from (select card_id, count(*) as n, count(*) filter (where kept) as kept, count(*) filter (where won) as won
               from heard group by card_id) h
       join battlecards b on b.id = h.card_id),
    'no_objection', (select jsonb_build_object('calls', count(*), 'kept', count(*) filter (where kept))
                       from c where not exists (select 1 from card_taps t where t.attempt_id = c.id)),
    'talk', (select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket, 'calls', n, 'kept', k, 'won', w) order by ord), '[]'::jsonb)
       from (select case when not coalesce(matched, false) or duration_seconds is null then 6
                         when duration_seconds < 30 then 1 when duration_seconds < 60 then 2
                         when duration_seconds < 180 then 3 when duration_seconds < 600 then 4 else 5 end as ord,
                    count(*) as n, count(*) filter (where kept) as k, count(*) filter (where won) as w
               from c group by 1) x
       cross join lateral (select (array['under 30 s', '30 s – 1 min', '1 – 3 min', '3 – 10 min', '10 min +', 'not matched to Zoom'])[x.ord] as bucket) lbl),
    'outcomes', (select coalesce(jsonb_agg(jsonb_build_object('disposition', disposition, 'calls', n) order by n desc), '[]'::jsonb)
       from (select disposition, count(*) as n from c group by disposition) o),
    'words', jsonb_build_object(
       'kept', (select coalesce(jsonb_agg(jsonb_build_object('word', w, 'notes', notes) order by notes desc, w), '[]'::jsonb)
                  from (select w, notes from words where kept and notes >= 2 order by notes desc, w limit 12) k),
       'lost', (select coalesce(jsonb_agg(jsonb_build_object('word', w, 'notes', notes) order by notes desc, w), '[]'::jsonb)
                  from (select w, notes from words where not kept and notes >= 2 order by notes desc, w limit 12) l))
  ) into r;
  return r;
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.is_conversation(boolean, text), public.digest(uuid, int), public.insights(int)
  from public, anon;
grant execute on function public.is_conversation(boolean, text), public.digest(uuid, int), public.insights(int)
  to authenticated;
