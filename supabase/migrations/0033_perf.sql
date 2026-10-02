-- Dial Floor · 0033 the floor board gets cheap
-- Focus items 42, 49 and 54's indexes, reproduced in
-- supabase/tests/groups/44_perf.sql:
--   · 42 every open Floor tab fired eight queries per tile change — one of them
--     a 60-day streak walk — three times per dial. Streaks now live in a small
--     cache refreshed once per business day, and the whole board arrives in one
--     call. The page pairs it with realtime on the tiles.
--   · 49 the morning radar ran off whoever opened the app first; radar_cron()
--     is the same run with no login attached, for a scheduler to call.
--   · 54 the foreign keys the advisors flagged get their indexes.

-- ------------------------------------------------------------ streak cache --
create table if not exists public.streak_cache (
  agent_id uuid primary key references public.profiles(id) on delete cascade,
  streak int not null,
  day date not null
);
alter table public.streak_cache enable row level security;
create policy streak_cache_read on public.streak_cache for select to authenticated
  using (public.is_active());

-- The 60-day walk, once a day, into the cache. It hands the fresh rows back as
-- well: the caller's snapshot predates the insert, so on the first read of the
-- day the rows have to travel by return value, not by table.
create or replace function public.streaks_refresh()
returns table (agent_id uuid, streak int)
language sql security definer set search_path = public as $$
  insert into streak_cache (agent_id, streak, day)
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
  select g.agent_id,
         (count(*) filter (where g.hit and g.day > coalesce(m.day, '-infinity'::date)))::int,
         (select today from cfg)
    from grid g join last_miss m using (agent_id)
   group by g.agent_id
  on conflict (agent_id) do update set streak = excluded.streak, day = excluded.day
  returning streak_cache.agent_id, streak_cache.streak
$$;

-- same name and shape as before, so the leaderboard keeps its join; today's cache
-- when it exists, else one refresh under an advisory lock so a stampede of tabs
-- computes it once (volatile, because that first call of the day writes). A dial
-- made after the morning refresh shows tomorrow — a streak is a day-grain number,
-- so that is the honest grain.
create or replace function public.streaks()
returns table (agent_id uuid, streak int)
language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from streak_cache c
                  join profiles p on p.id = c.agent_id and p.active
                 where c.day = public.business_date()) then
    if pg_try_advisory_xact_lock(hashtext('dial-floor streaks_refresh')) then
      return query select * from public.streaks_refresh();
      return;
    end if;
  end if;
  return query
    select c.agent_id, c.streak from streak_cache c
     where c.day = public.business_date();
end $$;

-- ------------------------------------------------------------- one board --
-- Everything the Floor page shows, in one call. The manager-only panes come
-- back null for agents; floor_alerts already draws that line for itself.
create or replace function public.floor_board()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_mgr boolean;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.is_active() then raise exception 'your login is not switched on yet'; end if;
  v_mgr := public.is_manager();
  return jsonb_build_object(
    'tiles', (select coalesce(jsonb_agg(to_jsonb(v) order by v.role desc, lower(v.name)), '[]'::jsonb)
                from v_floor_today v),
    'pace', (select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) from public.floor_pace() f),
    'alerts', public.floor_alerts(),
    'leaderboard', public.leaderboard('today'),
    'sprint', public.sprint_board(),
    'callbacks', case when not v_mgr then null else
      (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', c.id, 'lead_id', c.lead_id, 'lead', l.name, 'phone', l.phone_display,
                 'tz', l.tz, 'agent', p.name, 'due_at', c.due_at, 'tries', c.tries)
               order by c.due_at), '[]'::jsonb)
         from callbacks c join leads l on l.id = c.lead_id join profiles p on p.id = c.agent_id
        where c.status = 'scheduled'
        limit 50) end,
    'recent', case when not v_mgr then null else
      (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', a.id, 'at', a.clicked_at, 'agent', p.name, 'lead', l.name,
                 'disposition', a.disposition, 'duration', a.duration_seconds,
                 'note', a.note, 'ai_summary', a.ai_summary)
               order by a.clicked_at desc), '[]'::jsonb)
         from (select * from attempts
                where disposition is not null and disposition <> 'not_placed'
                order by clicked_at desc limit 25) a
         join profiles p on p.id = a.agent_id
         join leads l on l.id = a.lead_id) end,
    'health', case when not v_mgr then null else
      (select coalesce(jsonb_agg(to_jsonb(n) order by n.dials_7d desc nulls last), '[]'::jsonb)
         from v_number_health n) end);
end $$;

-- ------------------------------------------------------------ cron wrapper --
-- 49: the morning radar with no login attached. Same advisory lock and
-- once-a-day guard as radar_daily; for the scheduler (or service role) only.
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
  return radar_run() || '{"ran": true}';
end $$;

-- live tiles: the page subscribes to agent_status instead of refetching the board
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime'
                        and schemaname = 'public' and tablename = 'agent_status') then
    alter publication supabase_realtime add table public.agent_status;
  end if;
end $$;

-- ------------------------------------------------------------- FK indexes --
-- 54: the rest of the foreign keys the advisors flagged.
create index if not exists callbacks_agent_idx on public.callbacks (agent_id);
create index if not exists callbacks_lead_idx on public.callbacks (lead_id);
create index if not exists callbacks_requeued_by_idx on public.callbacks (requeued_by);
create index if not exists lists_agent_idx on public.lists (agent_id);
create index if not exists lists_created_by_idx on public.lists (created_by);
create index if not exists list_items_lead_idx on public.list_items (lead_id);
create index if not exists handoff_lead_idx on public.handoff_ledger (lead_id);
create index if not exists handoff_agent_idx on public.handoff_ledger (agent_id);
create index if not exists handoff_outcome_by_idx on public.handoff_ledger (outcome_by);
create index if not exists email_queue_lead_idx on public.email_queue (lead_id);
create index if not exists email_queue_flagged_idx on public.email_queue (flagged_by);
create index if not exists email_queue_sent_by_idx on public.email_queue (sent_by);
create index if not exists card_taps_card_idx on public.card_taps (card_id);
create index if not exists card_taps_agent_idx on public.card_taps (agent_id);
create index if not exists attempts_list_idx on public.attempts (list_id);
create index if not exists library_attempt_idx on public.library_items (attempt_id);
create index if not exists library_created_by_idx on public.library_items (created_by);
create index if not exists referrals_agent_idx on public.referrals (agent_id);
create index if not exists referrals_lead_idx on public.referrals (lead_id);
create index if not exists referrals_from_lead_idx on public.referrals (from_lead);
create index if not exists referrals_from_attempt_idx on public.referrals (from_attempt);
create index if not exists sprints_created_by_idx on public.sprints (created_by);
create index if not exists call_votes_voter_idx on public.call_votes (voter);
create index if not exists agent_breaks_agent_idx on public.agent_breaks (agent_id);
create index if not exists suppression_source_idx on public.suppression (source_attempt);
create index if not exists lead_state_owner_idx on public.lead_state (owner_agent);
create index if not exists lead_state_reserved_idx on public.lead_state (reserved_by);

-- -------------------------------------------------------------- API surface --
revoke execute on function public.streaks_refresh(), public.radar_cron() from public, anon, authenticated;
revoke execute on function public.floor_board(), public.streaks() from public, anon;
grant execute on function public.floor_board(), public.streaks() to authenticated;

-- ------------------------------------------------------------ alert clocks --
-- (0024's floor_alerts, with one change for item 45: the overdue-callback line
--  says the time on the lead's own clock — the clock the promise was made on —
--  instead of business time.)
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
  -- Dials that count as a manager working the phones. The complaint this came
  -- from was a manager who made one test dial being told on their own board that
  -- they were idle 14 minutes and behind pace, so "has dialed today" is not the
  -- line: one dial is poking at the thing, a morning of them is working it.
  v_mgr_dials int := 10;
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
      -- have really worked the phones today; otherwise the manager watching the
      -- board was told they were the one standing around.
      select jsonb_build_object(
               'key', 'idle:' || s.agent_id || ':' || extract(epoch from s.since)::bigint,
               'kind', 'idle', 'level', 'warn', 'agent', p.name, 'at', s.since,
               'title', p.name || ' idle ' || floor(extract(epoch from now() - s.since) / 60) || ' min',
               'detail', 'no dial since ' || to_char(s.since at time zone v_tz, 'FMHH12:MI AM')) as x
        from agent_status s join profiles p on p.id = s.agent_id
       where v_idle > 0 and p.active and s.updated_at >= now() - interval '5 minutes'
         and s.status in ('idle', 'wrap') and s.since < now() - make_interval(mins => v_idle)
         and (p.role = 'agent' or (select count(*) from attempts d
                                    where d.agent_id = p.id
                                      and d.clicked_at >= public.business_day_start()) >= v_mgr_dials)
      union all
      -- The long call is the open attempt itself, not the heartbeat: a browser
      -- that died mid-call used to clear this alert after five quiet minutes,
      -- which is exactly when somebody should be walking over, and the outcome of
      -- that call was never going to be logged by itself. "Open" is said here
      -- the same way next_lead says it when it hands an agent back a call they
      -- started and never logged: no outcome on the attempt, or only the
      -- placeholder the webhook writes when Zoom says the call ended, with the
      -- lead still in progress under that agent and the call still inside the
      -- reclaim window. Saying it the same way is the point — every call the
      -- queue still wants an outcome for is on the board and nothing else is. So
      -- a lead a manager has released, and one the queue has already finished and
      -- handed on, stop being that agent's call and stop raising an alert,
      -- instead of sitting on the board with the minutes climbing and no way for
      -- anyone to clear them. Whoever has a call open is dialing, manager or not,
      -- so there is nothing to filter.
      select jsonb_build_object(
               'key', 'long:' || a.agent_id || ':' || a.id,
               'kind', 'long_call', 'level', 'warn', 'agent', p.name, 'at', a.clicked_at,
               'title', p.name || ' on one call ' || floor(extract(epoch from now() - a.clicked_at) / 60) || ' min',
               'detail', l.name || ': still talking, or the browser closed before the outcome was logged')
        from attempts a join profiles p on p.id = a.agent_id join leads l on l.id = a.lead_id
       -- "Open" has to mean the same thing here as it does in next_lead, which hands a
       -- call back to its agent while the outcome is still only Zoom's placeholder.
       -- If the board read it any other way a call would fall between the two.
       where v_long > 0 and p.active and (a.disposition is null or a.auto_logged)
         and exists (select 1 from lead_state ls
                      where ls.lead_id = a.lead_id and ls.state = 'in_progress'
                        and ls.owner_agent = a.agent_id)
         -- No upper bound on age. Tying this to the window the queue waits before
         -- calling a call abandoned is what hid the case the alert exists for: a real
         -- conversation outlives it, and so does a browser that died. The day is not
         -- the bound either — a call open across the rollover is exactly when a dead
         -- tab is least likely to be noticed. A day's grace only stops a call nobody
         -- ever resolved from nagging for ever; by then the lead needs a manager.
         and a.clicked_at > now() - interval '24 hours'
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
         and (p.role = 'agent' or f.dials >= v_mgr_dials)), '[]'::jsonb);
  end if;

  if v_cb > 0 then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'callback:' || c.id || ':' || extract(epoch from c.due_at)::bigint,
               'kind', 'callback', 'level', 'warn', 'agent', p.name, 'at', c.due_at,
               'title', 'Callback overdue: ' || l.name,
               -- item 45: the promise was made on the lead's clock, so that is the
               -- clock this line reads
               'detail', p.name || '''s callback, due ' ||
                         to_char(c.due_at at time zone coalesce(l.tz, 'America/New_York'), 'FMHH12:MI AM Dy')
                         || ' their time') order by c.due_at)
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
