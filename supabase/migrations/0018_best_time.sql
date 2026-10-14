-- Dial Floor · 0018 best time to call (Phase 2 · C6)
--   The chance someone picks up, by trade and by the lead's own hour of day,
--   learned from the attempt log. Thin data lies, so each estimate is pulled
--   toward the trade's all-day rate (and that toward the floor's) until it has
--   the dials to stand on its own, and nothing is called reliable before the
--   floor has min_total dials in the window and the cell min_dials. It is one
--   factor among several:
--   · the Funnel tab shows the best hours per trade, and the Dial page a hint
--     for the lead's trade
--   · with use_in_queue switched on (off by default), the general pool leans
--     toward trades in a good hour: score × the hour's lift, held to 0.7–1.3, so
--     it reorders the pool without overriding it. Lists and callbacks keep
--     their own order
--   "Picks up" = the agent logged a live person (a gatekeeper counts: the
--   business answered). The model refreshes when read, at most every 6 hours.

insert into public.app_settings (key, value) values
  ('best_time', '{"days": 90, "min_dials": 30, "min_total": 1000, "prior": 20, "use_in_queue": false}')
on conflict (key) do nothing;

-- trade '*' = every trade; hour -1 = all day
create table public.best_time_cells (
  trade text not null,
  hour int not null check (hour between -1 and 23),
  dials int not null,
  connects int not null,
  rate numeric not null,     -- smoothed pickup rate
  lift numeric not null,     -- against the trade's all-day rate (all-day rows: against the floor's)
  reliable boolean not null,
  primary key (trade, hour)
);
alter table public.best_time_cells enable row level security;
create policy best_time_cells_read on public.best_time_cells for select to authenticated using (true);

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
   where a.clicked_at >= now() - make_interval(days => v_days) and a.disposition is not null and a.disposition <> 'skipped';
  p0 := case when v_total > 0 then v_conn::numeric / v_total end;

  delete from best_time_cells where true;  -- a bare DELETE is refused on API sessions (Supabase's safeupdate)
  if p0 > 0 then
    insert into best_time_cells (trade, hour, dials, connects, rate, lift, reliable)
    with a as (
      select coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)') as trade,
             extract(hour from a.clicked_at at time zone coalesce(l.tz, 'America/New_York'))::int as hour,
             coalesce(a.connected, false) as c
        from attempts a join leads l on l.id = a.lead_id
       where a.clicked_at >= now() - make_interval(days => v_days) and a.disposition is not null and a.disposition <> 'skipped'
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

-- the model as the Funnel tab and the Dial page read it (refreshed when 6+ hours old)
create or replace function public.best_times()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  st jsonb := public.setting('best_time_state');
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if (st is null or (st->>'at')::timestamptz < now() - interval '6 hours')
     and pg_try_advisory_xact_lock(hashtext('dial-floor best_time_refresh')) then
    st := public.best_time_refresh();
  end if;
  return jsonb_build_object(
    'state', st,
    'ready', coalesce((st->>'total')::int >= (st->>'min_total')::int, false),
    'use_in_queue', coalesce((public.setting('best_time')->>'use_in_queue')::boolean, false),
    'hours', (select coalesce(jsonb_agg(jsonb_build_object('hour', hour, 'dials', dials, 'rate', round(rate, 4),
                                                           'lift', round(lift, 3), 'reliable', reliable) order by hour), '[]'::jsonb)
                from best_time_cells where trade = '*' and hour >= 0),
    'trades', (select coalesce(jsonb_agg(jsonb_build_object(
                  'trade', t.trade,
                  'label', (select min(l.category) from leads l where split_part(l.category_key, ',', 1) = t.trade),
                  'dials', t.dials, 'rate', round(t.rate, 4),
                  'cells', (select coalesce(jsonb_agg(jsonb_build_object('hour', c.hour, 'dials', c.dials, 'rate', round(c.rate, 4),
                                                                         'lift', round(c.lift, 3)) order by c.rate desc), '[]'::jsonb)
                              from best_time_cells c where c.trade = t.trade and c.hour >= 0 and c.reliable))
                  order by t.dials desc), '[]'::jsonb)
                 from best_time_cells t where t.trade <> '*' and t.hour = -1));
end $$;

create or replace function public.next_lead()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_max int := coalesce((public.setting('max_attempts_per_day'))::int, 2);
  v_reclaim interval := make_interval(mins => coalesce((public.setting('reclaim_minutes'))::int, 30));
  v_gap interval := make_interval(mins => coalesce((public.setting('min_redial_minutes'))::int, 120));
  v_hold interval := make_interval(mins => coalesce((public.setting('reserve_minutes'))::int, 10));
  v_bt boolean := coalesce((public.setting('best_time')->>'use_in_queue')::boolean, false);
  v_today date := public.business_date();
  v_lead bigint;
  v_reason text;
  r record;
begin
  if v_uid is null then return jsonb_build_object('error', 'not signed in'); end if;

  -- 0. a call I started and never logged (page reloaded mid-call): pick it back up
  --    (even when deactivated meanwhile, so the call still gets its outcome)
  select a.id, a.lead_id, a.clicked_at into r
    from attempts a
    join lead_state ls on ls.lead_id = a.lead_id
    where a.agent_id = v_uid and (a.disposition is null or a.auto_logged)
      and ls.state = 'in_progress' and ls.owner_agent = v_uid
      and a.clicked_at > now() - v_reclaim
    order by a.clicked_at desc limit 1;
  if found then
    return build_workspace(r.lead_id, 'resume')
      || jsonb_build_object('attempt_id', r.id, 'clicked_at', r.clicked_at);
  end if;

  if not exists (select 1 from profiles where id = v_uid and active) then
    return jsonb_build_object('error', 'your account is deactivated — ask your manager');
  end if;

  -- an agent holds one lead at a time
  update lead_state set reserved_by = null, reserved_until = null where reserved_by = v_uid;

  perform wake_rested();

  -- 1. my due callbacks (a promise beats every cold dial)
  select c.lead_id into v_lead
    from callbacks c
    join lead_state ls on ls.lead_id = c.lead_id
    join leads l on l.id = c.lead_id
    where c.agent_id = v_uid and c.status = 'scheduled' and c.due_at <= now() + interval '10 minutes'
      and ls.state not in ('suppressed', 'handoff')
      and (ls.state <> 'in_progress' or ls.owner_agent = v_uid or ls.in_progress_since < now() - v_reclaim)
      and (ls.reserved_by is null or ls.reserved_by = v_uid or ls.reserved_until < now())
      and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
      and local_ok(l.tz)
    order by c.due_at limit 1
    for update of ls skip locked;
  if found then v_reason := 'callback_due'; end if;

  -- 2. next from my lists, then from unassigned (shared) lists
  if v_lead is null then
    select li.lead_id into v_lead
      from lists ld
      join list_items li on li.list_id = ld.id and li.served_at is null
      join lead_state ls on ls.lead_id = li.lead_id
      join leads l on l.id = li.lead_id
      where (ld.agent_id = v_uid or ld.agent_id is null) and ld.status = 'active'
        and (ls.state in ('fresh','queued')
             or (ls.state = 'in_progress' and ls.in_progress_since < now() - v_reclaim))
        and (ls.rest_until is null or ls.rest_until <= now())
        and (ls.attempts_today_date is distinct from v_today or ls.attempts_today < v_max)
        and (ls.last_attempt_at is null or ls.last_attempt_at <= now() - v_gap)
        and (ls.reserved_by is null or ls.reserved_by = v_uid or ls.reserved_until < now())
        and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
        and local_ok(l.tz)
      order by (ld.agent_id is null), ld.list_date desc, li.position limit 1
      for update of ls skip locked;
    if found then v_reason := 'list'; end if;
  end if;

  -- 3. general pool (manager can turn this off in settings)
  if v_lead is null and coalesce((public.setting('allow_general_pool'))::boolean, true) then
    select ls.lead_id into v_lead
      from lead_state ls
      join leads l on l.id = ls.lead_id
      -- C6, when switched on: lean toward trades that pick up at this hour of their day
      left join best_time_cells bt on v_bt and bt.reliable
        and bt.trade = coalesce(nullif(split_part(l.category_key, ',', 1), ''), '(none)')
        and bt.hour = extract(hour from now() at time zone coalesce(l.tz, 'America/New_York'))::int
      where (ls.state in ('fresh','queued')
             or (ls.state = 'in_progress' and ls.in_progress_since < now() - v_reclaim))
        and (ls.rest_until is null or ls.rest_until <= now())
        and (ls.attempts_today_date is distinct from v_today or ls.attempts_today < v_max)
        and (ls.last_attempt_at is null or ls.last_attempt_at <= now() - v_gap)
        and (ls.reserved_by is null or ls.reserved_by = v_uid or ls.reserved_until < now())
        and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
        -- a lead waiting on another agent's list stays with that agent
        and not exists (select 1 from list_items li join lists ld on ld.id = li.list_id
                        where li.lead_id = ls.lead_id and li.served_at is null and ld.status = 'active'
                          and ld.agent_id is not null and ld.agent_id <> v_uid)
        and local_ok(l.tz)
      order by case when v_bt then coalesce(l.score, 0) * greatest(0.7, least(1.3, coalesce(bt.lift, 1))) end desc nulls last,
               l.score desc nulls last, l.review_count desc nulls last limit 1
      for update of ls skip locked;
    if found then v_reason := 'pool'; end if;
  end if;

  if v_lead is null then
    return jsonb_build_object('empty', true,
      'hint', 'No eligible lead right now: lists empty, callbacks not due, recently dialed leads still cooling down, or every lead is outside its local calling window.');
  end if;

  update lead_state set reserved_by = v_uid, reserved_until = now() + v_hold where lead_id = v_lead;
  return build_workspace(v_lead, v_reason);
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.best_time_refresh() from public, anon, authenticated;
revoke execute on function public.best_times() from public, anon;
grant execute on function public.best_times() to authenticated;
