-- Dial Floor · 0020 scorecards (Phase 2 · E6)
--   A weekly scorecard per agent for a 15-minute review: each business week
--   (Monday on) of the last four, the agent's funnel next to the floor's (every
--   agent who dialed that week), plus the receipts for this week:
--   · the handoffs, with what was agreed
--   · worth talking through: the longest conversations that still ended in a no
--   · calls a manager saved to the library (managers only, like the library)
--   No QA scores and no clips: those needed recordings (E3 was cut). Agents see
--   their own scorecard; managers see everyone's.

create or replace function public.scorecard(p_agent uuid, p_weeks int default 4)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  v_weeks int := greatest(1, least(coalesce(p_weeks, 4), 12));
  v_tz text := public.business_tz();
  v_this date := date_trunc('week', public.business_date()::timestamp)::date;
  v_from timestamptz := (v_this - 7 * (v_weeks - 1))::timestamp at time zone v_tz;
  v_week timestamptz := v_this::timestamp at time zone v_tz;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_agent is distinct from auth.uid() and not is_manager() then
    raise exception 'agents see their own scorecard';
  end if;

  with a as (
    select x.*, date_trunc('week', x.clicked_at at time zone v_tz)::date as wk,
           public.is_conversation(x.connected, x.disposition) as convo
      from attempts x where x.clicked_at >= v_from
  ),
  per as (  -- each agent's week
    select a.agent_id, a.wk,
           count(*) as dials,
           count(distinct (a.clicked_at at time zone v_tz)::date) as days,
           count(*) filter (where a.call_result = 'answered' or coalesce(a.connected, false)) as picked_up,
           count(*) filter (where a.convo) as conversations,
           count(*) filter (where a.convo and public.kept_alive(a.disposition)) as kept,
           count(*) filter (where a.disposition in ('chance_website', 'sale_closed')) as won,
           coalesce(sum(a.duration_seconds) filter (where a.call_result = 'answered'), 0) as talk_seconds,
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
                          and y.duration_seconds >= 120
                        order by y.duration_seconds desc limit 3) x
                 join leads l on l.id = x.lead_id),
    'saved', (select coalesce(jsonb_agg(jsonb_build_object('id', li.id, 'title', li.title, 'scenario', li.scenario,
                                                           'at', li.created_at) order by li.created_at), '[]'::jsonb)
                from library_items li join attempts y on y.id = li.attempt_id
               where y.agent_id = p_agent and y.clicked_at >= v_week))
    into r;
  return r;
end $$;

revoke execute on function public.scorecard(uuid, int) from public, anon;
grant execute on function public.scorecard(uuid, int) to authenticated;
