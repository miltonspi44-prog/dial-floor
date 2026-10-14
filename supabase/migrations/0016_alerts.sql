-- Dial Floor · 0016 alerts (Phase 2 · E4)
--   floor_alerts(): what the floor board raises right now. Each alert carries a
--   stable key, so a browser that notifies does it once per event:
--   · idle: a lead up and no dial for idle_minutes (a pause with a reason is not
--     idle)
--   · long call: one call running long_call_minutes (still talking, or the
--     outcome was never logged)
--   · pace: after an hour on the floor, an agent on pace for less than pace_pct %
--     of the daily dial target
--   · callback overdue: a promised callback callback_overdue_minutes past due
--   · win: a chance given or a sale closed in the last hour, the bell for everyone
--   · spam: a caller number whose connect rate collapsed (the F5 rule)
--   Managers get them all, agents the wins. The thresholds live in the alerts
--   setting (the Floor tab edits it); 0 or false turns one off.

insert into public.app_settings (key, value) values
  ('alerts', '{"idle_minutes": 10, "long_call_minutes": 15, "pace_pct": 80, "callback_overdue_minutes": 15, "celebrate": true, "spam": true}')
on conflict (key) do nothing;

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

  -- live tiles, with the floor board's 5-minute freshness
  r := r || coalesce((
    select jsonb_agg(x order by x->>'at') from (
      select jsonb_build_object(
               'key', 'idle:' || s.agent_id || ':' || extract(epoch from s.since)::bigint,
               'kind', 'idle', 'level', 'warn', 'agent', p.name, 'at', s.since,
               'title', p.name || ' idle ' || floor(extract(epoch from now() - s.since) / 60) || ' min',
               'detail', 'no dial since ' || to_char(s.since at time zone v_tz, 'FMHH12:MI AM')) as x
        from agent_status s join profiles p on p.id = s.agent_id
       where v_idle > 0 and p.active and s.updated_at >= now() - interval '5 minutes'
         and s.status in ('idle', 'wrap') and s.since < now() - make_interval(mins => v_idle)
      union all
      select jsonb_build_object(
               'key', 'long:' || s.agent_id || ':' || extract(epoch from s.since)::bigint,
               'kind', 'long_call', 'level', 'warn', 'agent', p.name, 'at', s.since,
               'title', p.name || ' on one call ' || floor(extract(epoch from now() - s.since) / 60) || ' min',
               'detail', coalesce(s.lead_name, 'a lead') || ': still talking, or the outcome was never logged')
        from agent_status s join profiles p on p.id = s.agent_id
       where v_long > 0 and p.active and s.updated_at >= now() - interval '5 minutes'
         and s.status in ('dialing', 'on_call') and s.since < now() - make_interval(mins => v_long)) q), '[]'::jsonb);

  if v_pace > 0 and v_target > 0 then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'pace:' || f.agent_id || ':' || public.business_date(),
               'kind', 'pace', 'level', 'warn', 'agent', p.name, 'at', f.first_dial,
               'title', p.name || ' behind pace',
               'detail', round(f.dials_per_hour) || ' dials an hour, on pace for ' || round(f.dials_per_hour * v_shift)
                         || ' of ' || round(v_target) || ' (that takes ' || ceil(v_target / v_shift) || ' an hour)'))
        from public.floor_pace() f join profiles p on p.id = f.agent_id
       where f.active_seconds >= 3600 and not f.on_break and f.dials_per_hour is not null
         and f.dials_per_hour * v_shift < v_pace / 100 * v_target), '[]'::jsonb);
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
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'spam:' || n.number || ':' || public.business_date(),
               'kind', 'spam', 'level', 'warn', 'agent', null, 'number', n.number, 'at', now(),
               'title', 'Possible spam label',
               'detail', 'connect rate ' || coalesce(n.rate_prev_7d || '% → ', '') || n.rate_7d
                         || '% over the last 7 days: swap the number in Zoom'))
        from v_number_health n
       where n.rate_7d is not null
         and ((n.rate_prev_7d is not null and n.rate_prev_7d - n.rate_7d >= v_drop)
              or (coalesce(n.dials_7d, 0) >= 60 and n.rate_7d < 8))), '[]'::jsonb);
  end if;
  return r;
end $$;

revoke execute on function public.floor_alerts() from public, anon;
grant execute on function public.floor_alerts() to authenticated;
