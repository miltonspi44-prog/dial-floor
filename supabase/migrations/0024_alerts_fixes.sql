-- Dial Floor · 0024 alerts fixes
--   Four things the floor board got wrong, every one of them an alert a manager
--   should never have seen or never got to see:
--     · idle, long call and behind pace took in everyone with a profile, so a
--       manager who made a test dial was told on their own board that they were
--       idle 14 minutes and behind pace
--     · pace counted up to now() with no end, so an agent who hit 400 dials at
--       4:30pm and went home still read "33 dials an hour, on pace for 267 of
--       400" at nine in the evening, with the behind-pace alert beside it
--     · the spam-label alert could not fire for a number nobody answers at all,
--       which is the one case it exists for, and a four-dial week counted as a
--       collapse
--     · the long-call alert came off the heartbeat, so a browser that died
--       mid-call cleared the alert five minutes later instead of raising it

-- ------------------------------------------------------------ number health --
-- A number with dials and not one pickup has a connect rate of 0%, not "no
-- rate". The nullif on the numerator turned that true zero into null, and the
-- spam alert skips a number without a rate, so a carrier-flagged number with 80
-- dials and no answers raised nothing while the same number with a single
-- pickup raised an alert. The nullif stays on the divisor, which is the one
-- that matters: it is what keeps a week with no dials from dividing by zero.
-- Last week's dial count comes along as well, because the drop rule compares
-- the two weeks and has to know whether either week is big enough to mean
-- anything.
create or replace view public.v_number_health with (security_invoker = true) as
select number,
  sum(dials) filter (where stat_date >= public.business_date() - 6) as dials_7d,
  sum(connects) filter (where stat_date >= public.business_date() - 6) as connects_7d,
  round(100.0 * sum(connects) filter (where stat_date >= public.business_date() - 6)
      / nullif(sum(dials) filter (where stat_date >= public.business_date() - 6), 0), 1) as rate_7d,
  round(100.0 * sum(connects) filter (where stat_date between public.business_date() - 13 and public.business_date() - 7)
      / nullif(sum(dials) filter (where stat_date between public.business_date() - 13 and public.business_date() - 7), 0), 1) as rate_prev_7d,
  sum(dials) filter (where stat_date between public.business_date() - 13 and public.business_date() - 7) as dials_prev_7d
from number_stats
group by number;

-- -------------------------------------------------------------------- pace --
-- Same as before, with one change: the active day ends at the agent's last sign
-- of life instead of at this moment. Someone who finishes at 4:30pm and shuts
-- the laptop keeps the rate they were working at, rather than watching it fall
-- all evening while nobody is dialing. The last sign of life is the later of
-- their last dial and their heartbeat, so an agent sitting on the board between
-- calls still has a running clock, and a pause taken after they stopped cannot
-- stretch past that end either. my_pace reads these rows, so the agent's own
-- strip shows the same numbers the floor board does.
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
    cross join lateral (
      select count(*) as dials,
             count(*) filter (where x.connected) as connects,
             count(*) filter (where public.is_conversation(x.connected, x.disposition)) as conversations,
             count(*) filter (where x.disposition in ('chance_website', 'sale_closed')) as handoffs,
             coalesce(sum(x.duration_seconds) filter (where x.call_result = 'answered'), 0)::bigint as talk_seconds,
             min(x.clicked_at) as first_dial, max(x.clicked_at) as last_dial
        from attempts x where x.agent_id = p.id and x.clicked_at >= t.t0) a
    cross join lateral (  -- the last sign of life: a dial, or a browser still saying hello
      select least(now(), greatest(a.last_dial, s.updated_at)) as ended_at) fin
    left join lateral (  -- paused since the first dial, and never past the end of the day's work
      select sum(greatest(0, extract(epoch from least(coalesce(b.ended_at, now()), fin.ended_at)
                                              - greatest(b.started_at, a.first_dial)))) as s
        from agent_breaks b
       where b.agent_id = p.id and a.first_dial is not null and coalesce(b.ended_at, now()) > a.first_dial) pz on true
    cross join lateral (
      select case when a.first_dial is null then 0::numeric
                  else greatest(0, extract(epoch from fin.ended_at - a.first_dial) - coalesce(pz.s, 0)) end as s) act
    left join agent_breaks ob on ob.agent_id = p.id and ob.ended_at is null
   where p.active
$$;

-- ------------------------------------------------------------------ alerts --
-- Same alerts, same thresholds, four fixes:
--   · idle and behind pace are about the people working the phones. A manager
--     who is really dialing today should still be covered, so the rule is
--     "dials today" rather than "never a manager". Wins ring for everyone, as
--     they did.
--   · behind pace now also asks the two questions a manager would ask before
--     walking over: is this person still here, and did they already make the
--     number? A tile nobody has touched for five minutes is someone gone, which
--     is the same line the floor board draws.
--   · the long call comes off the open attempt instead of the heartbeat.
--   · the spam drop rule wants a real week on both sides.
create or replace function public.floor_alerts()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  cfg jsonb := coalesce(public.setting('alerts'), '{}'::jsonb);
  v_idle int := coalesce((cfg->>'idle_minutes')::int, 10);
  v_long int := coalesce((cfg->>'long_call_minutes')::int, 15);
  v_pace numeric := coalesce((cfg->>'pace_pct')::numeric, 80);
  v_cb int := coalesce((cfg->>'callback_overdue_minutes')::int, 15);
  v_target numeric := (select target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day');
  v_shift numeric := greatest(1, least(coalesce((public.setting('shift_hours'))::numeric, 8), 16));
  v_drop numeric := coalesce((public.setting('spam_alert_drop_pts'))::numeric, 10);
  -- dials a week before the two weeks are worth comparing at all
  v_sample int := 30;
  v_tz text := public.business_tz();
  r jsonb := '[]';
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  -- wins ring the bell for everyone
  if coalesce((cfg->>'celebrate')::boolean, true) then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'win:' || a.id, 'kind', 'win', 'level', 'good', 'agent', p.name, 'at', a.disposed_at,
               'title', p.name || case when a.disposition = 'sale_closed' then ' closed a sale'
                                       else ' got the chance to build a website' end,
               'detail', l.name) order by a.disposed_at desc)
        from attempts a join profiles p on p.id = a.agent_id join leads l on l.id = a.lead_id
       where a.clicked_at >= now() - interval '1 day' and a.disposed_at >= now() - interval '60 minutes'
         and a.disposition in ('chance_website', 'sale_closed')), '[]'::jsonb);
  end if;
  if not is_manager() then return r; end if;

  r := r || coalesce((
    select jsonb_agg(x order by x->>'at') from (
      -- Idle: a live tile, up and quiet. A manager only counts here once they
      -- have dialed today; otherwise the manager watching the board was told
      -- they were the one standing around.
      select jsonb_build_object(
               'key', 'idle:' || s.agent_id || ':' || extract(epoch from s.since)::bigint,
               'kind', 'idle', 'level', 'warn', 'agent', p.name, 'at', s.since,
               'title', p.name || ' idle ' || floor(extract(epoch from now() - s.since) / 60) || ' min',
               'detail', 'no dial since ' || to_char(s.since at time zone v_tz, 'FMHH12:MI AM')) as x
        from agent_status s join profiles p on p.id = s.agent_id
       where v_idle > 0 and p.active and s.updated_at >= now() - interval '5 minutes'
         and s.status in ('idle', 'wrap') and s.since < now() - make_interval(mins => v_idle)
         and (p.role = 'agent' or exists (select 1 from attempts d
                                           where d.agent_id = p.id and d.clicked_at >= public.business_day_start()))
      union all
      -- The long call is the open attempt itself: dialed, and no outcome on it
      -- yet, not even the placeholder the webhook writes when Zoom says the call
      -- ended. Reading the heartbeat instead meant a browser that died mid-call
      -- cleared this alert after five quiet minutes, which is exactly when
      -- somebody should be walking over, and the outcome of that call was never
      -- going to be logged by itself. Only today's calls: an attempt nobody ever
      -- logged would otherwise sit on the board for the rest of time. Whoever has
      -- a call open is dialing, manager or not, so there is nothing to filter.
      select jsonb_build_object(
               'key', 'long:' || a.agent_id || ':' || a.id,
               'kind', 'long_call', 'level', 'warn', 'agent', p.name, 'at', a.clicked_at,
               'title', p.name || ' on one call ' || floor(extract(epoch from now() - a.clicked_at) / 60) || ' min',
               'detail', l.name || ': still talking, or the browser closed before the outcome was logged')
        from attempts a join profiles p on p.id = a.agent_id join leads l on l.id = a.lead_id
       where v_long > 0 and p.active and a.disposition is null and not a.auto_logged
         and a.clicked_at >= public.business_day_start()
         and a.clicked_at < now() - make_interval(mins => v_long)) q), '[]'::jsonb);

  if v_pace > 0 and v_target > 0 then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'pace:' || f.agent_id || ':' || public.business_date(),
               'kind', 'pace', 'level', 'warn', 'agent', p.name, 'at', f.first_dial,
               'title', p.name || ' behind pace',
               'detail', round(f.dials_per_hour) || ' dials an hour, on pace for ' || round(f.dials_per_hour * v_shift)
                         || ' of ' || round(v_target) || ' (that takes ' || ceil(v_target / v_shift) || ' an hour)'))
        from public.floor_pace() f
        join profiles p on p.id = f.agent_id
        join agent_status s on s.agent_id = f.agent_id
       where f.active_seconds >= 3600 and not f.on_break and f.dials_per_hour is not null
         and f.dials_per_hour * v_shift < v_pace / 100 * v_target
         -- somebody who has already made the day's number is not behind anything
         and f.dials < v_target
         -- and somebody whose tile has gone quiet has gone home: nothing to chase
         and s.status <> 'offline' and s.updated_at >= now() - interval '5 minutes'
         and (p.role = 'agent' or f.dials > 0)), '[]'::jsonb);
  end if;

  if v_cb > 0 then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'callback:' || c.id || ':' || extract(epoch from c.due_at)::bigint,
               'kind', 'callback', 'level', 'warn', 'agent', p.name, 'at', c.due_at,
               'title', 'Callback overdue: ' || l.name,
               'detail', p.name || '''s callback, due ' || to_char(c.due_at at time zone v_tz, 'FMHH12:MI AM Dy')) order by c.due_at)
        from callbacks c join profiles p on p.id = c.agent_id join leads l on l.id = c.lead_id
       where c.status = 'scheduled' and c.due_at < now() - make_interval(mins => v_cb)), '[]'::jsonb);
  end if;

  if coalesce((cfg->>'spam')::boolean, true) then
    -- The drop rule holds two weeks up against each other, so both weeks need
    -- enough dials to be saying anything: four dials last week against five this
    -- week is noise, not a number going bad. The absolute rule below it already
    -- carries its own floor of 60 dials.
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'spam:' || n.number || ':' || public.business_date(),
               'kind', 'spam', 'level', 'warn', 'agent', null, 'number', n.number, 'at', now(),
               'title', 'Possible spam label',
               'detail', 'connect rate ' || coalesce(n.rate_prev_7d || '% → ', '') || n.rate_7d
                         || '% over the last 7 days: swap the number in Zoom'))
        from v_number_health n
       where n.rate_7d is not null
         and ((n.rate_prev_7d is not null and n.rate_prev_7d - n.rate_7d >= v_drop
               and coalesce(n.dials_7d, 0) >= v_sample and coalesce(n.dials_prev_7d, 0) >= v_sample)
              or (coalesce(n.dials_7d, 0) >= 60 and n.rate_7d < 8))), '[]'::jsonb);
  end if;
  return r;
end $$;

-- -------------------------------------------------------------- API surface --
-- Replacing a function keeps the grants it had, but they are written out again
-- so the migration that last touched these says who may call them.
revoke execute on function public.floor_alerts(), public.floor_pace() from public, anon;
grant execute on function public.floor_alerts(), public.floor_pace() to authenticated;
