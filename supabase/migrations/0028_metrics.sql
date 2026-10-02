-- Dial Floor · 0028 one meaning per word
-- The reports from the focus list (items 15, 16, 24), reproduced first in
-- supabase/tests/groups/39_metrics.sql. Before this, the same word counted
-- different things on different screens:
--   · "conversation" was a live person past the gatekeeper on Coaching, the
--     leaderboard, sprints and scorecards — but on the Funnel and the floor
--     tiles it was any connected outcome, gatekeepers and wrong numbers in.
--     One definition now (is_conversation), used everywhere, and the daily
--     target is a conversations target under one label.
--   · talk time was Zoom's duration of every pickup (voicemails included) on
--     the Funnel, pace and scorecards, but conversations only on Coaching.
--     One helper now: talk_seconds, conversations only.
--   · a dial Zoom never placed (0027's not_placed) is out of every count.
--   · the small counting errors: "by intent" counted a lead with three intents
--     three times, "never answers" counted misses from all time and only on the
--     one record, the radar's "converting above average" was pickup rate, the
--     sprint picked an arbitrary winner on a tie, rolling windows slipped an
--     hour at daylight-saving changes, and the scorecard's "ended in a no"
--     review listed wrong numbers and "decision maker not in".

-- ----------------------------------------------------------------- helpers --
-- The one meaning of talk time: Zoom's measured seconds, on conversations.
-- A voicemail's 40 seconds is not talking to anyone, and an unmatched call has
-- no measured seconds to count.
create or replace function public.talk_seconds(p_connected boolean, p_dispo text, p_duration int)
returns int language sql immutable set search_path = public as $$
  select case when public.is_conversation(p_connected, p_dispo) then coalesce(p_duration, 0) else 0 end
$$;

-- "The last N days" counted in calendar days on the business clock. Subtracting
-- an interval from a timestamptz slips an hour across a daylight-saving change,
-- so a 30-day window read 11pm-to-11pm half the year and silently moved dials
-- across day boundaries.
create or replace function public.business_days_ago(p_days int)
returns timestamptz language sql stable set search_path = public as $$
  select (public.business_date() - greatest(0, coalesce(p_days, 0)))::timestamp
           at time zone public.business_tz()
$$;

-- The one daily target the floor compares people against is conversations, and
-- it is called that everywhere now (it was saved as connects_per_day and
-- labelled Conversations on one page, Connects on another).
update public.kpi_targets set metric = 'conversations_per_day'
 where metric = 'connects_per_day' and scope = 'agent_day'
   and not exists (select 1 from public.kpi_targets k2
                    where k2.metric = 'conversations_per_day' and k2.scope = 'agent_day');

-- ------------------------------------------------------------------ funnel --
-- answered      = Zoom says the far end picked up (person, voicemail or machine),
--                 or the agent logged a person (Zoom may not have matched the call)
-- connects      = the agent logged any live person (gatekeepers and wrong numbers in)
-- conversations = is_conversation: a live person past the gatekeeper
-- handoffs      = the W / S exits (chance given, sale closed)
-- Every stage is a subset of the one before; dials leave out not_placed.
create or replace function public.funnel(p_days int default 1)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 1), 366));
  v_from timestamptz := public.business_days_ago(v_days - 1);
  r jsonb;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  with a as (
    select a.agent_id, a.lead_id, a.clicked_at, a.source, a.list_id, a.disposition, l.tz,
           coalesce(a.call_result = 'answered', false) or coalesce(a.connected, false) as answered,
           coalesce(a.connected, false) as connect,
           public.is_conversation(a.connected, a.disposition) as convo,
           coalesce(a.disposition in ('chance_website', 'sale_closed'), false) as handoff,
           public.talk_seconds(a.connected, a.disposition, a.duration_seconds) as talk
      from attempts a join leads l on l.id = a.lead_id
     where a.clicked_at >= v_from
       and a.disposition is distinct from 'not_placed'
  )
  select jsonb_build_object(
    'from', v_from, 'days', v_days,
    'totals', (select jsonb_build_object(
        'dials', count(*), 'answered', count(*) filter (where answered),
        'connects', count(*) filter (where connect),
        'conversations', count(*) filter (where convo), 'handoffs', count(*) filter (where handoff),
        'callbacks', count(*) filter (where disposition = 'callback'),
        'emails', count(*) filter (where disposition = 'email_requested'),
        'talk_seconds', coalesce(sum(talk), 0)) from a),
    'by_agent', (select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
        select jsonb_build_object('agent_id', p.id, 'name', p.name,
          'days', count(distinct (a.clicked_at at time zone public.business_tz())::date),
          'dials', count(*), 'answered', count(*) filter (where a.answered),
          'conversations', count(*) filter (where a.convo), 'handoffs', count(*) filter (where a.handoff),
          'talk_seconds', coalesce(sum(a.talk), 0)) as x
        from a join profiles p on p.id = a.agent_id
        group by p.id, p.name) s),
    'by_source', (select coalesce(jsonb_agg(x order by (x->>'dials')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('source', coalesce(a.source, 'untracked'), 'list', ld.name,
          'dials', count(*), 'answered', count(*) filter (where a.answered),
          'conversations', count(*) filter (where a.convo), 'handoffs', count(*) filter (where a.handoff)) as x
        from a left join lists ld on ld.id = a.list_id
        group by coalesce(a.source, 'untracked'), ld.id, ld.name) s),
    -- Each dial under its lead's strongest intent, so the rows are a partition:
    -- a lead with three intents used to land in three rows and the column summed
    -- to three times the dials.
    'by_intent', (select coalesce(jsonb_agg(x order by (x->>'dials')::int desc, x->>'label'), '[]'::jsonb) from (
        select jsonb_build_object('intent', t.key, 'label', t.label,
          'dials', count(*), 'answered', count(*) filter (where t.answered),
          'conversations', count(*) filter (where t.convo), 'handoffs', count(*) filter (where t.handoff)) as x
        from (select a.*, top.key, top.label
                from a
                cross join lateral (
                  select ic.key, ic.label
                    from lead_intents li join intents_catalog ic on ic.key = li.intent_key
                   where li.lead_id = a.lead_id
                   order by li.confidence desc, ic.priority, ic.key limit 1) top) t
        group by t.key, t.label) s),
    'by_hour', (select coalesce(jsonb_agg(x order by (x->>'hour')::int), '[]'::jsonb) from (
        select jsonb_build_object('hour', h,
          'dials', count(*), 'answered', count(*) filter (where answered),
          'conversations', count(*) filter (where convo), 'handoffs', count(*) filter (where handoff)) as x
        from (select *, extract(hour from clicked_at at time zone coalesce(tz, 'America/New_York'))::int as h from a) t
        group by h) s)
  ) into r;
  return r;
end $$;

-- ------------------------------------------------------------ floor board --
-- The tiles: conversations alongside connects, dials without the not-placed.
create or replace view public.v_floor_today with (security_invoker = true) as
select
  p.id as agent_id, p.name, p.role,
  case when s.status is null or s.updated_at < now() - interval '5 minutes' then 'offline'
       else s.status end as status,
  case when s.updated_at < now() - interval '5 minutes' then null else s.lead_name end as lead_name,
  case when s.updated_at < now() - interval '5 minutes' then null else s.phone_display end as phone_display,
  s.since,
  count(a.id) filter (where a.disposition is distinct from 'not_placed') as dials_today,
  count(a.id) filter (where a.connected) as connects_today,
  count(a.id) filter (where a.disposition in ('chance_website','sale_closed')) as handoffs_today,
  count(a.id) filter (where a.disposition = 'email_requested') as emails_today,
  s.updated_at as last_seen,
  -- last, because "create or replace view" may only add columns at the end
  count(a.id) filter (where public.is_conversation(a.connected, a.disposition)) as conversations_today
from profiles p
left join agent_status s on s.agent_id = p.id
left join attempts a on a.agent_id = p.id and a.clicked_at >= public.business_day_start()
where p.active
group by p.id, p.name, p.role, s.status, s.lead_name, s.phone_display, s.since, s.updated_at;

-- -------------------------------------------------------------------- pace --
-- (0024's, with dials leaving out the not-placed and talk time on the one helper)
create or replace function public.floor_pace()
returns table (agent_id uuid, dials bigint, connects bigint, conversations bigint, handoffs bigint,
               talk_seconds bigint, first_dial timestamptz, paused_seconds numeric, active_seconds numeric,
               dials_per_hour numeric, talk_minutes_per_hour numeric,
               on_break boolean, break_reason text, break_note text, break_since timestamptz)
language sql stable security invoker set search_path = public as $$
  with t as (select public.business_day_start() as t0)
  select p.id, a.dials, a.connects, a.conversations, a.handoffs, a.talk_seconds, a.first_dial,
         coalesce(pz.s, 0), act.s,
         case when act.s >= 900 then round(a.dials / (act.s / 3600), 1) end,
         case when act.s >= 900 then round(a.talk_seconds / 60.0 / (act.s / 3600), 1) end,
         ob.id is not null, ob.reason, ob.note, ob.started_at
    from profiles p
    cross join t
    left join agent_status s on s.agent_id = p.id
    left join agent_breaks ob on ob.agent_id = p.id and ob.ended_at is null
    cross join lateral (
      select count(*) filter (where x.disposition is distinct from 'not_placed') as dials,
             count(*) filter (where x.connected) as connects,
             count(*) filter (where public.is_conversation(x.connected, x.disposition)) as conversations,
             count(*) filter (where x.disposition in ('chance_website', 'sale_closed')) as handoffs,
             coalesce(sum(public.talk_seconds(x.connected, x.disposition, x.duration_seconds)), 0)::bigint as talk_seconds,
             min(x.clicked_at) filter (where x.disposition is distinct from 'not_placed') as first_dial,
             max(x.clicked_at) filter (where x.disposition is distinct from 'not_placed') as last_dial
        from attempts x where x.agent_id = p.id and x.clicked_at >= t.t0) a
    cross join lateral (  -- the last sign of life: a dial, a browser still saying hello, or a pause still running
      select least(now(), greatest(a.last_dial, s.updated_at,
                                  case when ob.id is not null then now() end)) as ended_at) fin
    left join lateral (  -- paused since the first dial, and never past the end of the day's work
      select sum(greatest(0, extract(epoch from least(coalesce(b.ended_at, now()), fin.ended_at)
                                              - greatest(b.started_at, a.first_dial)))) as s
        from agent_breaks b
       where b.agent_id = p.id and a.first_dial is not null and coalesce(b.ended_at, now()) > a.first_dial) pz on true
    cross join lateral (
      select case when a.first_dial is null then 0::numeric
                  else greatest(0, extract(epoch from fin.ended_at - a.first_dial) - coalesce(pz.s, 0)) end as s) act
   where p.active
$$;

-- ---------------------------------------------------------------------- D2 --
-- (0013's digest, with the window on calendar days, dials without the
--  not-placed, talk time on the one helper, and the target under its one name)
create or replace function public.digest(p_agent uuid, p_days int default 7)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 7), 90));
  v_from timestamptz := public.business_days_ago(v_days - 1);
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
      from attempts a
     where a.clicked_at >= v_from and a.disposition is distinct from 'not_placed'
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
       'talk_seconds', coalesce(sum(public.talk_seconds(connected, disposition, duration_seconds)), 0),
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
      'conversations', max(target) filter (where metric = 'conversations_per_day'),
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
             and a.disposition is distinct from 'not_placed'
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
-- (0013's insights, with the window on calendar days; its conversations already
--  exclude the not-placed, which are never conversations)
create or replace function public.insights(p_days int default 30)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 30), 366));
  v_from timestamptz := public.business_days_ago(v_days - 1);
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

-- --------------------------------------------------------------- scorecard --
-- (0023's, with dials leaving out the not-placed, talk time on the one helper,
--  and the "ended in a no" review keeping to real noes: a wrong number is not a
--  conversation that went wrong, and "decision maker not in" is a retry, not a no)
create or replace function public.scorecard(p_agent uuid, p_weeks int default 4)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_weeks int := greatest(1, least(coalesce(p_weeks, 4), 12));
  v_tz text := public.business_tz();
  v_this date := date_trunc('week', public.business_date()::timestamp)::date;
  v_from timestamptz := (v_this - 7 * (v_weeks - 1))::timestamp at time zone v_tz;
  v_week timestamptz := v_this::timestamp at time zone v_tz;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  -- Row-level security used to be what kept a login nobody has switched on from
  -- seeing the floor's numbers here. This function now runs as its owner, so
  -- policies no longer apply to it and the question has to be asked out loud.
  if not public.is_active() then raise exception 'your login is not switched on yet'; end if;
  if p_agent is distinct from auth.uid() and not is_manager() then
    raise exception 'agents see their own scorecard';
  end if;

  with a as (
    select x.*, date_trunc('week', x.clicked_at at time zone v_tz)::date as wk,
           public.is_conversation(x.connected, x.disposition) as convo
      from attempts x
     where x.clicked_at >= v_from and x.disposition is distinct from 'not_placed'
  ),
  per as (  -- each agent's week
    select a.agent_id, a.wk,
           count(*) as dials,
           count(distinct (a.clicked_at at time zone v_tz)::date) as days,
           count(*) filter (where a.call_result = 'answered' or coalesce(a.connected, false)) as picked_up,
           count(*) filter (where a.convo) as conversations,
           count(*) filter (where a.convo and public.kept_alive(a.disposition)) as kept,
           count(*) filter (where a.disposition in ('chance_website', 'sale_closed')) as won,
           coalesce(sum(public.talk_seconds(a.connected, a.disposition, a.duration_seconds)), 0) as talk_seconds,
           count(*) filter (where a.disposition = 'callback') as callbacks_set
      from a group by a.agent_id, a.wk
  ),
  cb as (  -- promised callbacks that came due that week: kept or missed
    select c.agent_id, date_trunc('week', c.due_at at time zone v_tz)::date as wk,
           count(*) filter (where c.status = 'done') as done, count(*) filter (where c.status = 'missed') as missed
      from callbacks c
     where c.due_at >= v_from and c.due_at < now() and c.status in ('done', 'missed')
     group by 1, 2
  ),
  weeks as (select (v_this - 7 * g)::date as wk from generate_series(0, v_weeks - 1) g)
  select jsonb_build_object(
    'agent', (select jsonb_build_object('id', p.id, 'name', p.name) from profiles p where p.id = p_agent),
    'this_week', v_this,
    'weeks', (select jsonb_agg(jsonb_build_object(
        'week', w.wk,
        'me', jsonb_build_object(
           'dials', coalesce(m.dials, 0), 'days', coalesce(m.days, 0), 'picked_up', coalesce(m.picked_up, 0),
           'conversations', coalesce(m.conversations, 0), 'kept', coalesce(m.kept, 0), 'won', coalesce(m.won, 0),
           'talk_seconds', coalesce(m.talk_seconds, 0), 'callbacks_set', coalesce(m.callbacks_set, 0),
           'cb_done', coalesce(mc.done, 0), 'cb_missed', coalesce(mc.missed, 0)),
        -- the floor's totals and headcount: averages and pooled rates are taken from these
        'floor', (select jsonb_build_object(
           'agents', count(*), 'dials', coalesce(sum(f.dials), 0), 'days', coalesce(sum(f.days), 0),
           'picked_up', coalesce(sum(f.picked_up), 0), 'conversations', coalesce(sum(f.conversations), 0),
           'kept', coalesce(sum(f.kept), 0), 'won', coalesce(sum(f.won), 0),
           'talk_seconds', coalesce(sum(f.talk_seconds), 0), 'callbacks_set', coalesce(sum(f.callbacks_set), 0),
           'cb_done', (select coalesce(sum(done), 0) from cb where cb.wk = w.wk),
           'cb_missed', (select coalesce(sum(missed), 0) from cb where cb.wk = w.wk))
           from per f where f.wk = w.wk))
        order by w.wk)
      from weeks w
      left join per m on m.wk = w.wk and m.agent_id = p_agent
      left join cb mc on mc.wk = w.wk and mc.agent_id = p_agent),
    'handoffs', (select coalesce(jsonb_agg(jsonb_build_object(
                    'at', h.handed_at, 'lead', h.lead_snapshot->>'name', 'kind', h.kind, 'summary', h.summary,
                    'rating', h.rating, 'outcome', h.outcome) order by h.handed_at), '[]'::jsonb)
                   from handoff_ledger h where h.agent_id = p_agent and h.handed_at >= v_week),
    'review', (select coalesce(jsonb_agg(jsonb_build_object(
                  'attempt_id', x.id, 'at', x.clicked_at, 'lead', l.name, 'disposition', x.disposition,
                  'duration', x.duration_seconds, 'note', x.note,
                  'objections', (select coalesce(jsonb_agg(distinct b.objection), '[]'::jsonb)
                                   from card_taps t join battlecards b on b.id = t.card_id where t.attempt_id = x.id))
                  order by x.duration_seconds desc), '[]'::jsonb)
                 from (select * from attempts y
                        where y.agent_id = p_agent and y.clicked_at >= v_week
                          and public.is_conversation(y.connected, y.disposition) and not public.kept_alive(y.disposition)
                          -- worth talking through means a real no: a wrong number is
                          -- not the pitch failing, and "not in" is a retry
                          and y.disposition not in ('wrong_number', 'dm_not_in')
                          and y.duration_seconds >= 120
                        order by y.duration_seconds desc limit 3) x
                 join leads l on l.id = x.lead_id),
    -- Saved calls are the manager's, like the Playbook page they live on. The
    -- library's own manager-only policy used to be what kept agents out of this
    -- list; running as the owner skips that policy, so the rule is written here.
    'saved', (select coalesce(jsonb_agg(jsonb_build_object('id', li.id, 'title', li.title, 'scenario', li.scenario,
                                                           'at', li.created_at) order by li.created_at), '[]'::jsonb)
                from library_items li join attempts y on y.id = li.attempt_id
               where y.agent_id = p_agent and y.clicked_at >= v_week and public.is_manager()))
    into r;
  return r;
end $$;

-- ------------------------------------------------------------- leaderboard --
-- (0019's, with dials leaving out the not-placed)
create or replace function public.leaderboard(p_period text default 'today')
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_tz text := public.business_tz();
  v_from timestamptz := case when p_period = 'week'
                             then date_trunc('week', public.business_date()::timestamp) at time zone v_tz
                             else public.business_day_start() end;
  v_today date := public.business_date();
  r jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  with a as (
    select x.agent_id, count(*) as dials,
           count(*) filter (where public.is_conversation(x.connected, x.disposition)) as conversations
      from attempts x
     where x.clicked_at >= v_from and x.disposition is distinct from 'not_placed'
     group by x.agent_id
  ),
  votes as (
    select v.attempt_id, count(*) as n from call_votes v where v.vote_date = v_today group by v.attempt_id
  )
  select jsonb_build_object(
    'period', case when p_period = 'week' then 'week' else 'today' end,
    'from', v_from,
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                'agent_id', p.id, 'name', p.name, 'dials', coalesce(a.dials, 0),
                'conversations', coalesce(a.conversations, 0), 'streak', coalesce(s.streak, 0))
              order by coalesce(a.conversations, 0) desc, coalesce(a.dials, 0) desc, lower(p.name)), '[]'::jsonb)
               from profiles p
               left join a on a.agent_id = p.id
               left join public.streaks() s on s.agent_id = p.id
              where p.active and (p.role = 'agent' or a.dials > 0)),
    'votes', (select coalesce(jsonb_object_agg(v.attempt_id, v.n), '{}'::jsonb) from votes v),
    'my_vote', (select v.attempt_id from call_votes v where v.vote_date = v_today and v.voter = auth.uid()),
    'call_of_the_day', (select jsonb_build_object(
                           'attempt_id', x.id, 'votes', v.n, 'agent', p.name, 'lead', l.name,
                           'disposition', x.disposition, 'duration', x.duration_seconds, 'note', x.note)
                          from votes v join attempts x on x.id = v.attempt_id
                          join profiles p on p.id = x.agent_id join leads l on l.id = x.lead_id
                         order by v.n desc, x.clicked_at limit 1))
    into r;
  return r;
end $$;

-- ----------------------------------------------------------------- streaks --
-- (0019's, with dials leaving out the not-placed)
create or replace function public.streaks()
returns table (agent_id uuid, streak int)
language sql stable security invoker set search_path = public as $$
  with cfg as (
    select greatest(1, coalesce((select target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day'), 1)) as target,
           coalesce(public.setting('business_hours')->'days', '[1,2,3,4,5]'::jsonb) as days,
           public.business_tz() as tz, public.business_date() as today
  ),
  work_days as (
    select d::date as day
      from cfg, generate_series((cfg.today - 60)::timestamp, cfg.today::timestamp, interval '1 day') d
     where extract(isodow from d)::int in (select jsonb_array_elements_text(cfg.days)::int)
  ),
  per_day as (
    select a.agent_id, (a.clicked_at at time zone cfg.tz)::date as day, count(*) as dials
      from attempts a, cfg
     where a.clicked_at >= (cfg.today - 61)::timestamp at time zone cfg.tz
       and a.disposition is distinct from 'not_placed'
     group by 1, 2
  ),
  grid as (
    select p.id as agent_id, w.day, coalesce(pd.dials, 0) >= cfg.target as hit
      from profiles p cross join work_days w cross join cfg
      left join per_day pd on pd.agent_id = p.id and pd.day = w.day
     where p.active
  ),
  last_miss as (
    select g.agent_id, max(g.day) filter (where not g.hit and g.day < (select today from cfg)) as day
      from grid g group by g.agent_id
  )
  select g.agent_id, (count(*) filter (where g.hit and g.day > coalesce(m.day, '-infinity'::date)))::int
    from grid g join last_miss m using (agent_id)
   group by g.agent_id
$$;

-- ------------------------------------------------------------ power hours --
-- (0019's board, with dials leaving out the not-placed, and a dead heat named
--  instead of settled alphabetically: on a tie there is no winner row; the tied
--  rows come back under "winners" and the page says so)
create or replace function public.sprint_board()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  s sprints%rowtype;
  v_to timestamptz;
  v_rows jsonb;
  v_cand jsonb;
  v_win jsonb;
  v_ties jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into s from sprints where ends_at > now() - interval '12 hours' order by ends_at desc, id desc limit 1;
  if not found then return null; end if;
  v_to := least(s.ends_at, now());
  with ev as (  -- a dial counts when placed, a conversation when its outcome is logged
    select x.agent_id, case when s.metric = 'dials' then x.clicked_at else coalesce(x.disposed_at, x.clicked_at) end as t
      from attempts x
     where x.clicked_at >= s.starts_at - interval '2 hours' and x.clicked_at <= v_to
       and x.disposition is distinct from 'not_placed'
       and (s.metric = 'dials' or public.is_conversation(x.connected, x.disposition))
  ),
  per as (
    select ev.agent_id, count(*) as n, (array_agg(ev.t order by ev.t))[s.goal] as reached_at
      from ev where ev.t >= s.starts_at and ev.t <= v_to group by ev.agent_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('agent_id', p.id, 'name', p.name, 'count', coalesce(per.n, 0),
                                               'reached_at', per.reached_at)
                            order by coalesce(per.n, 0) desc, per.reached_at nulls last, lower(p.name)), '[]'::jsonb)
    into v_rows
    from profiles p left join per on per.agent_id = p.id
   where p.active and (p.role = 'agent' or per.n > 0);

  -- first to the goal wins at once; without one, the most when time is up
  select x into v_win from jsonb_array_elements(v_rows) x
   where case when s.goal is not null then x->>'reached_at' is not null
              else s.ends_at <= now() and (x->>'count')::int > 0 end
   order by case when s.goal is not null then (x->>'reached_at')::timestamptz end, (x->>'count')::int desc
   limit 1;

  -- a dead heat is a dead heat: same moment to the goal, or the same count at
  -- the bell, and nobody gets the alphabet's trophy
  if v_win is not null then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_ties from jsonb_array_elements(v_rows) x
     where case when s.goal is not null
                then x->>'reached_at' is not null
                     and (x->>'reached_at')::timestamptz = (v_win->>'reached_at')::timestamptz
                else (x->>'count')::int = (v_win->>'count')::int end;
    if jsonb_array_length(v_ties) > 1 then
      return jsonb_build_object('id', s.id, 'name', s.name, 'metric', s.metric, 'goal', s.goal,
                                'starts_at', s.starts_at, 'ends_at', s.ends_at, 'running', s.ends_at > now(),
                                'rows', v_rows, 'winner', null, 'winners', v_ties);
    end if;
  end if;
  return jsonb_build_object('id', s.id, 'name', s.name, 'metric', s.metric, 'goal', s.goal,
                            'starts_at', s.starts_at, 'ends_at', s.ends_at, 'running', s.ends_at > now(),
                            'rows', v_rows, 'winner', v_win);
end $$;

-- ---------------------------------------------------------------------- C4 --
-- (0012's missed_tries, counted per business and inside a window)
-- The tries that count: rang out or went to voicemail (never a live conversation),
-- placed inside the lead's business hours on its own clock. Counted across every
-- lead record sharing the phone — the business was called, whichever row the dial
-- landed on — and only the last 90 days: a business that ignored eight calls last
-- spring but picks up now is not a never-answers lead, and the old all-time count
-- could never unmake itself.
create or replace function public.missed_tries(p_lead_id bigint)
returns table (clicked_at timestamptz)
language sql stable set search_path = public as $$
  with h as (
    select coalesce(public.setting('business_hours'),
                    '{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}'::jsonb) as v
  ),
  me as (select phone_norm from leads where id = p_lead_id)
  select a.clicked_at
    from attempts a
    join leads l on l.id = a.lead_id
    join me on me.phone_norm = l.phone_norm
    cross join h
   where a.clicked_at >= now() - interval '90 days'
     and not coalesce(a.connected, false)
     and (a.disposition in ('no_answer', 'voicemail')
          or (a.disposition is null and a.call_result = 'not_answered'))
     and extract(isodow from a.clicked_at at time zone coalesce(l.tz, 'America/New_York'))::int
           in (select jsonb_array_elements_text(h.v->'days')::int)
     and (a.clicked_at at time zone coalesce(l.tz, 'America/New_York'))::time
           between (h.v->>'start')::time and (h.v->>'end')::time
$$;

-- ------------------------------------------------------------ radar ranking --
-- (0012's, with the month's rates read without the not-placed)
create or replace function public.radar_rank()
returns table (lead_id bigint, rank numeric)
language sql stable set search_path = public as $$
  with recent as (
    select a.lead_id, coalesce(a.connected, false) as connected
      from attempts a
     where a.clicked_at >= now() - interval '30 days'
       and a.disposition is distinct from 'not_placed'
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

-- ----------------------------------------------------------- manager's radar --
-- (0012's, with "converting above average" actually about conversations — it
--  compared pickup rates — and the not-placed out of both sides of that ratio)
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
                 'rate', round(100.0 * count(*) filter (where g.convo) / count(*), 1),
                 'floor', round(100 * f.rate, 1),
                 'ratio', round((count(*) filter (where g.convo)::numeric / count(*)) / f.rate, 2)) as x
          from (select 'intent' as kind, ic.label, public.is_conversation(a.connected, a.disposition) as convo
                  from attempts a
                  join lead_intents li on li.lead_id = a.lead_id
                  join intents_catalog ic on ic.key = li.intent_key
                 where a.clicked_at >= now() - interval '30 days'
                   and a.disposition is distinct from 'not_placed'
                union all
                select 'trade', split_part(l.category_key, ',', 1), public.is_conversation(a.connected, a.disposition)
                  from attempts a join leads l on l.id = a.lead_id
                 where a.clicked_at >= now() - interval '30 days' and l.category_key is not null
                   and a.disposition is distinct from 'not_placed') g,
               (select count(*) filter (where public.is_conversation(connected, disposition))::numeric
                       / nullif(count(*), 0) as rate
                  from attempts
                 where clicked_at >= now() - interval '30 days'
                   and disposition is distinct from 'not_placed') f
         where f.rate > 0
         group by g.kind, g.label, f.rate
        having count(*) >= 20 and count(*) filter (where g.convo)::numeric / count(*) >= 1.5 * f.rate
         order by (count(*) filter (where g.convo)::numeric / count(*)) / f.rate desc
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

-- ----------------------------------------------------------------- best time --
-- (0018's, with the samples leaving out the not-placed — a dial that rang nowhere
--  says nothing about when this trade picks up)
-- HAND-APPLY AT LIVE TIME: the body carries a "delete from", which the management
-- API's confirmation scanner stalls on. Dashboard SQL editor, like 0022's refresh_lead.
create or replace function public.best_time_refresh()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := coalesce(public.setting('best_time'), '{}'::jsonb);
  v_days int := greatest(7, least(coalesce((cfg->>'days')::int, 90), 365));
  v_min int := greatest(1, coalesce((cfg->>'min_dials')::int, 30));
  v_min_total int := greatest(0, coalesce((cfg->>'min_total')::int, 1000));
  k numeric := greatest(1, coalesce((cfg->>'prior')::numeric, 20));  -- 1+: every smoothed rate stays above 0
  v_total int;
  v_conn int;
  p0 numeric;
  st jsonb;
begin
  select count(*), count(*) filter (where coalesce(a.connected, false))
    into v_total, v_conn
    from attempts a
   where a.clicked_at >= now() - make_interval(days => v_days)
     and a.disposition is not null and a.disposition not in ('skipped', 'not_placed');
  p0 := case when v_total > 0 then v_conn::numeric / v_total end;

  delete from best_time_cells where true;  -- a bare DELETE is refused on API sessions (Supabase's safeupdate)
  if p0 > 0 then
    insert into best_time_cells (trade, hour, dials, connects, rate, lift, reliable)
    with a as (
      select coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)') as trade,
             extract(hour from a.clicked_at at time zone coalesce(l.tz, 'America/New_York'))::int as hour,
             coalesce(a.connected, false) as c
        from attempts a join leads l on l.id = a.lead_id
       where a.clicked_at >= now() - make_interval(days => v_days)
         and a.disposition is not null and a.disposition not in ('skipped', 'not_placed')
    ),
    hr as (  -- the hour of day, every trade together
      select hour, count(*) as n, count(*) filter (where c) as cn,
             (count(*) filter (where c) + k * p0) / (count(*) + k) as r
        from a group by hour
    ),
    tr as (  -- each trade, all day
      select trade, count(*) as n, count(*) filter (where c) as cn,
             (count(*) filter (where c) + k * p0) / (count(*) + k) as r
        from a group by trade
    ),
    cell as (
      select trade, hour, count(*) as n, count(*) filter (where c) as cn from a group by trade, hour
    ),
    est as (  -- a cell leans on its trade's rate shifted by the hour's effect
      select cell.*, tr.r as tr_r,
             (cell.cn + k * least(0.99, tr.r * hr.r / p0)) / (cell.n + k) as r
        from cell join tr using (trade) join hr using (hour)
    )
    select '*', -1, v_total, v_conn, p0, 1, v_total >= v_min_total
    union all
    select '*', hr.hour, hr.n, hr.cn, hr.r, hr.r / p0, hr.n >= v_min and v_total >= v_min_total from hr
    union all
    select tr.trade, -1, tr.n, tr.cn, tr.r, tr.r / p0, tr.n >= v_min and v_total >= v_min_total from tr
    union all
    select est.trade, est.hour, est.n, est.cn, est.r, est.r / est.tr_r, est.n >= v_min and v_total >= v_min_total from est;
  end if;

  st := jsonb_build_object('at', now(), 'total', v_total, 'rate', round(coalesce(p0, 0), 4),
                           'min_total', v_min_total, 'min_dials', v_min, 'days', v_days);
  insert into app_settings (key, value) values ('best_time_state', st)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return st;
end $$;

-- -------------------------------------------------------------- API surface --
-- Replacing a function keeps the grants it had; written out again so the
-- migration that last touched these says who may call them.
revoke execute on function public.talk_seconds(boolean, text, int), public.business_days_ago(int),
  public.funnel(int), public.digest(uuid, int), public.insights(int), public.scorecard(uuid, int),
  public.leaderboard(text), public.streaks(), public.sprint_board(), public.missed_tries(bigint),
  public.radar_rank(), public.radar() from public, anon;
revoke execute on function public.best_time_refresh() from public, anon, authenticated;
grant execute on function public.talk_seconds(boolean, text, int), public.business_days_ago(int),
  public.funnel(int), public.digest(uuid, int), public.insights(int), public.scorecard(uuid, int),
  public.leaderboard(text), public.streaks(), public.sprint_board(), public.missed_tries(bigint),
  public.radar_rank(), public.radar() to authenticated;
