-- Dial Floor · 0037 radar lists wait for a manager's approval
-- The morning radar dealt every agent a fresh list every day and closed
-- yesterday's unread: two weeks of lists for one agent, none of them dialed, the
-- same leads re-dealt. Now the radar *proposes* a list (status 'draft'), a manager
-- approves it (status 'active', stamped with who and when), and the agent is
-- served from it until it is dialed through. No new list is proposed for an agent
-- while one of theirs is waiting for approval or still being dialed; a list
-- dialed through closes itself at the next run. A proposal holds its leads the
-- way an approved list does, so two proposals never carry the same lead.
--
-- Applies through the management API as it is: nothing in here is a statement
-- its confirmation scanner stalls on.

-- who approved a list, and when
alter table public.lists add column if not exists approved_by uuid references public.profiles(id);
alter table public.lists add column if not exists approved_at timestamptz;
create index if not exists lists_approved_by_idx on public.lists (approved_by);

-- --------------------------------------------------------- list_outstanding --
-- What is left to dial on a list: unserved items whose lead can still be served.
-- A lead suppressed or handed off since the list was built, or rested by a twin
-- record's dial, is not waiting on anyone, so it does not keep a list open.
create or replace function public.list_outstanding(p_list bigint)
returns int language sql stable set search_path = public as $$
  select count(*)::int
    from list_items li
    join lead_state ls on ls.lead_id = li.lead_id
   where li.list_id = p_list and li.served_at is null
     and ls.state in ('fresh', 'queued')
     and (ls.rest_until is null or ls.rest_until <= now())
$$;

-- ------------------------------------------------------------- radar_rank --
-- (0028's, with a lead on a *proposed* list held back as one on an approved list is)
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
                      where li2.lead_id = l.id and ld2.status in ('draft', 'active') and li2.served_at is null)
$$;

-- -------------------------------------------------------------- build_list --
-- (0012's, with the same hold for a lead on a proposed list)
create or replace function public.build_list(p_name text, p_agent uuid, p_rules jsonb, p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_list bigint; v_count int;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  perform wake_rested();
  insert into lists (name, agent_id, rules, created_by)
    values (p_name, p_agent, p_rules, auth.uid()) returning id into v_list;
  insert into list_items (list_id, lead_id, position)
  select v_list, l.id, row_number() over (order by l.score desc nulls last, l.review_count desc nulls last)
    from leads l
    join lead_state ls on ls.lead_id = l.id
    where ls.state in ('fresh','queued')
      and (ls.rest_until is null or ls.rest_until <= now())
      and not exists (select 1 from suppression s where s.phone_norm = l.phone_norm)
      and (p_rules->>'state' is null or l.addr_state = upper(p_rules->>'state'))
      and (p_rules->>'tier' is null or l.tier = upper(p_rules->>'tier'))
      and (p_rules->>'min_score' is null or l.score >= (p_rules->>'min_score')::int)
      and (p_rules->>'intent' is null or exists
            (select 1 from lead_intents li where li.lead_id = l.id and li.intent_key = p_rules->>'intent'))
      and (p_rules->>'phone_type' is null or l.phone_type = p_rules->>'phone_type')
      -- radar card rules: trade keys (any of, comma-separated), city, website, first seen
      and (p_rules->>'category' is null
           or string_to_array(l.category_key, ',') && string_to_array(p_rules->>'category', ','))
      and (p_rules->>'city' is null or lower(l.addr_city) = lower(p_rules->>'city'))
      and (p_rules->>'website_type' is null or l.website_type = p_rules->>'website_type')
      and (p_rules->>'fresh_days' is null
           or l.first_seen >= now() - make_interval(days => (p_rules->>'fresh_days')::int))
      and not exists (select 1 from list_items li2 join lists ld2 on ld2.id = li2.list_id
                      where li2.lead_id = l.id and ld2.status in ('draft', 'active') and li2.served_at is null)
    limit p_limit;
  get diagnostics v_count = row_count;
  return jsonb_build_object('list_id', v_list, 'count', v_count);
end $$;

-- ------------------------------------------------------------- radar_deal --
-- (0012's, turned into a proposal.) A list dialed through closes itself; an agent
-- with a list waiting for approval, or one still being dialed, is dealt nothing;
-- everyone else is dealt their best leads as a draft, and nothing is served from
-- it until a manager approves it (approve_list). The ranking is read once into
-- an array, so a morning with nothing to deal makes no empty lists.
create or replace function public.radar_deal()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_n int := coalesce((public.setting('radar_deal_per_agent'))::int, 100);
  v_today date := public.business_date();
  v_agents uuid[];
  v_picks bigint[];
  v_lists bigint[] := '{}';
  v_list bigint;
  v_closed int;
  k int;
  r jsonb;
begin
  update lists set status = 'done'
   where kind = 'radar' and status = 'active' and public.list_outstanding(id) = 0;
  get diagnostics v_closed = row_count;
  if v_n <= 0 then
    return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n, 'closed', v_closed);
  end if;

  -- only an agent with no radar list waiting for approval and none still being dialed
  select array_agg(p.id order by lower(p.name), p.id) into v_agents
    from profiles p
   where p.active and p.role = 'agent'
     and not exists (select 1 from lists ld
                      where ld.kind = 'radar' and ld.agent_id = p.id and ld.status in ('draft', 'active'));
  k := coalesce(array_length(v_agents, 1), 0);
  if k = 0 then
    return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n, 'closed', v_closed);
  end if;

  select array_agg(x.lead_id order by x.rn) into v_picks
    from (select rr.lead_id, row_number() over (order by rr.rank desc, rr.lead_id) as rn
            from radar_rank() rr) x
   where x.rn <= v_n * k;
  if coalesce(array_length(v_picks, 1), 0) = 0 then
    return jsonb_build_object('dealt', '[]'::jsonb, 'per_agent', v_n, 'closed', v_closed);
  end if;

  for i in 1..k loop
    insert into lists (name, agent_id, rules, list_date, kind, status)
      values ('Radar · ' || to_char(v_today, 'Dy Mon FMDD'), v_agents[i], '{"radar": true}', v_today, 'radar', 'draft')
      returning id into v_list;
    v_lists := v_lists || v_list;
  end loop;

  -- round-robin down the ranking, so every agent gets a fair share of the best leads
  insert into list_items (list_id, lead_id, position)
  select v_lists[1 + ((u.rn - 1) % k)::int], u.lead_id, ((u.rn - 1) / k + 1)::int
    from unnest(v_picks) with ordinality as u(lead_id, rn);

  select jsonb_agg(jsonb_build_object('agent_id', ld.agent_id, 'list_id', ld.id, 'status', ld.status,
           'count', (select count(*) from list_items li where li.list_id = ld.id)) order by ld.id)
    into r from lists ld where ld.id = any (v_lists);
  return jsonb_build_object('dealt', coalesce(r, '[]'::jsonb), 'per_agent', v_n, 'closed', v_closed);
end $$;

-- ------------------------------------------------------------ approve_list --
-- A manager's approval: the one way a proposed list starts being served. One
-- radar list at a time per agent: approving a second while the first is still
-- being dialed is the very thing the approval exists to stop.
create or replace function public.approve_list(p_list bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ld lists%rowtype;
  v_busy lists%rowtype;
  v_count int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  select * into ld from lists where id = p_list;
  if not found then raise exception 'list not found'; end if;
  if ld.status <> 'draft' then raise exception 'only a list waiting for approval can be approved'; end if;
  if ld.kind = 'radar' and ld.agent_id is not null then
    select * into v_busy from lists
     where kind = 'radar' and status = 'active' and agent_id = ld.agent_id and id <> ld.id
       and public.list_outstanding(id) > 0
     order by id limit 1;
    if found then
      raise exception '% still has % leads to dial on "%": close that list first, or discard this one',
        (select name from profiles where id = ld.agent_id), public.list_outstanding(v_busy.id), v_busy.name;
    end if;
  end if;
  update lists set status = 'active', approved_by = auth.uid(), approved_at = now() where id = p_list;
  select count(*) into v_count from list_items where list_id = p_list;
  return jsonb_build_object('list_id', p_list, 'count', v_count, 'left', public.list_outstanding(p_list));
end $$;

-- ------------------------------------------------------------------ radar --
-- (0028's, with the lists card showing every radar list still in play, what is
--  left on each, and who approved it)
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
    -- the radar lists still in play (waiting for approval, or being dialed) and the
    -- ones closed today; a list put away stays away
    'lists', (select coalesce(jsonb_agg(jsonb_build_object(
          'list_id', ld.id, 'agent', p.name, 'name', ld.name, 'status', ld.status,
          'list_date', ld.list_date, 'created_at', ld.created_at,
          'approved_by', ap.name, 'approved_at', ld.approved_at,
          'total', (select count(*) from list_items li where li.list_id = ld.id),
          'served', (select count(*) from list_items li where li.list_id = ld.id and li.served_at is not null),
          'left', public.list_outstanding(ld.id))
        order by (ld.status = 'draft') desc, p.name, ld.id), '[]'::jsonb)
       from lists ld
       left join profiles p on p.id = ld.agent_id
       left join profiles ap on ap.id = ld.approved_by
      where ld.kind = 'radar' and (ld.status in ('draft', 'active') or (ld.status = 'done' and ld.list_date = v_today)))
  ) into r;
  return r;
end $$;

-- ----------------------------------------------------------- floor alerts --
-- (0036's v4, with one line for managers: a radar list waiting for approval;
--  its switch is alerts.radar_approvals)
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
  -- Wave 5: the sync pulls every quarter hour, so three quarters of an hour of
  -- silence is a pull that did not happen; the console scrapes most days, so
  -- three days without a new lead is worth a look; and a call the floor cannot
  -- see is worth knowing about the day it happens
  v_sync_quiet int := coalesce((cfg->>'sync_quiet_minutes')::int, 45);
  v_console_quiet int := coalesce((cfg->>'console_quiet_days')::int, 3);
  v_last_pull timestamptz;
  v_last_added timestamptz;
  v_outside int;
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

  -- The sync has gone quiet. Only once it has been running at all this week:
  -- a floor fed by the PC loop on somebody's desk, or a brand-new database, is
  -- not a sync that stopped. Keyed on the last good pull, so the alert is one
  -- notification per outage rather than one per board refresh.
  select max(started_at) into v_last_pull from sync_runs where kind = 'pull_leads' and ok;
  if v_sync_quiet > 0 and v_last_pull > now() - interval '7 days'
     and v_last_pull < now() - make_interval(mins => v_sync_quiet) then
    r := r || jsonb_build_array(jsonb_build_object(
      'key', 'sync:' || extract(epoch from v_last_pull)::bigint,
      'kind', 'sync', 'level', 'warn', 'agent', null, 'at', v_last_pull,
      'title', 'Lead sync has gone quiet',
      'detail', 'last good pull ' || to_char(v_last_pull at time zone v_tz, 'FMHH12:MI AM Dy')
                || coalesce((select ' — latest run failed: ' || left(s.detail, 140) from sync_runs s
                              where s.ok = false and s.started_at > v_last_pull order by s.id desc limit 1),
                            ' — no pull has run since')));
  end if;

  -- The console has gone quiet: nothing new has arrived for days. The scraper
  -- feeds the floor most days, so this usually means it stopped. Keyed on the
  -- day, so it says so once a morning until something arrives.
  select max(added_at) into v_last_added from leads;
  if v_console_quiet > 0 and v_last_added < now() - make_interval(days => v_console_quiet) then
    r := r || jsonb_build_array(jsonb_build_object(
      'key', 'console:' || public.business_date(),
      'kind', 'console', 'level', 'warn', 'agent', null, 'at', v_last_added,
      'title', 'No new leads from the console',
      'detail', 'the last one arrived ' || to_char(v_last_added at time zone v_tz, 'FMMon FMDD')
                || ' (' || floor(extract(epoch from now() - v_last_added) / 86400) || ' days ago) — the scraper may have stopped'));
  end if;

  -- Calls placed outside the dialer today. The webhook sees every outbound call
  -- from our seats; one that no dial matched was started straight from Zoom, so
  -- no lead, outcome or note was recorded for it.
  if coalesce((cfg->>'outside_calls')::boolean, true) then
    select count(*) into v_outside from webhook_events
     where received_at >= public.business_day_start()
       and payload->>'dial_floor_outcome' like 'no dial of ours matched%';
    if v_outside > 0 then
      r := r || jsonb_build_array(jsonb_build_object(
        'key', 'outside:' || public.business_date(),
        'kind', 'outside', 'level', 'warn', 'agent', null, 'at', now(),
        'title', v_outside || ' call' || case when v_outside = 1 then '' else 's' end || ' placed outside the dialer today',
        'detail', 'dialed straight from Zoom, so no lead, outcome or note was recorded — the floor only counts calls started from the Dial page'));
    end if;
  end if;
  -- A radar list waiting for a manager's approval. The radar proposes and a person
  -- approves; until someone does, the agent dials from the pool and the proposal
  -- sits. Keyed on the list, so each proposal says so once.
  if coalesce((cfg->>'radar_approvals')::boolean, true) then
    r := r || coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', 'radar:' || ld.id,
               'kind', 'radar', 'level', 'warn', 'agent', p.name, 'at', ld.created_at,
               'title', coalesce(p.name || '''s', 'A shared') || ' radar list is waiting for approval',
               'detail', ld.name || ' · ' || (select count(*) from list_items li where li.list_id = ld.id)
                         || ' leads, proposed ' || to_char(ld.created_at at time zone v_tz, 'FMHH12:MI AM Dy')
                         || ' — approve or discard it on the Lists page') order by ld.created_at, ld.id)
        from lists ld left join profiles p on p.id = ld.agent_id
       where ld.kind = 'radar' and ld.status = 'draft'), '[]'::jsonb);
  end if;
  return r;
end $$;

-- -------------------------------------------------------------- hand_back --
-- (0027's, withdrawing a proposal made for someone taken off the floor)
create or replace function public.hand_back(p_id uuid, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cb int; v_lists int; v_drafts int;
begin
  -- their promised callbacks go back to the queue (the same as "push back" on the floor)
  update callbacks set status = 'requeued', requeued_by = p_by
   where agent_id = p_id and status = 'scheduled';
  get diagnostics v_cb = row_count;
  update lead_state set state = 'queued', owner_agent = null, updated_at = now()
   where owner_agent = p_id and state = 'callback_locked';
  -- their lists stay alive, shared with everyone
  update lists set agent_id = null where agent_id = p_id and status = 'active';
  get diagnostics v_lists = row_count;
  -- a radar list proposed for them and never approved is withdrawn: it was built
  -- for a person who is no longer on the floor
  update lists set status = 'archived' where agent_id = p_id and kind = 'radar' and status = 'draft';
  get diagnostics v_drafts = row_count;
  update lead_state set reserved_by = null, reserved_until = null where reserved_by = p_id;
  return jsonb_build_object('callbacks', v_cb, 'lists', v_lists, 'proposals', v_drafts);
end $$;

-- ------------------------------------------------------- settings registry --
-- (0032's, with the radar size saying what it now sizes, and the alerts help
--  naming every switch)
create or replace function public.settings_registry()
returns jsonb language sql immutable set search_path = public as $$
select jsonb_build_array(
  jsonb_build_object('key','call_window','kind','window','grp','Calling window','label','Calling hours (lead''s local time)','help','No lead is served or dialed outside these hours on its own clock.','def','{"start":"08:00","end":"20:30"}'::jsonb),
  jsonb_build_object('key','business_hours','kind','window_days','grp','Calling window','label','Business hours (for never-answers proof)','help','The hours and days that count as "they should have picked up".','def','{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}'::jsonb),
  jsonb_build_object('key','business_tz','kind','tz','grp','Calling window','label','Business timezone','help','The clock the floor''s day, streaks and reports run on.','def',to_jsonb('America/Los_Angeles'::text)),
  jsonb_build_object('key','max_attempts_per_day','kind','int','grp','Queue','label','Calls per business per day','min',1,'max',6,'def',to_jsonb(2)),
  jsonb_build_object('key','min_redial_minutes','kind','int','grp','Queue','label','Redial gap (minutes)','min',15,'max',720,'def',to_jsonb(120)),
  jsonb_build_object('key','reserve_minutes','kind','int','grp','Queue','label','Lead held on screen (minutes)','min',3,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','reclaim_minutes','kind','int','grp','Queue','label','Abandoned call reclaimed after (minutes)','min',10,'max',120,'def',to_jsonb(30)),
  jsonb_build_object('key','skip_rest_minutes','kind','int','grp','Queue','label','Rest after a skip (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','reclaim_sweep_max','kind','int','grp','Queue','label','Stranded calls finished per check','min',5,'max',100,'def',to_jsonb(25)),
  jsonb_build_object('key','allow_general_pool','kind','bool','grp','Queue','label','Serve from the general pool','help','Off = agents only dial callbacks and lists.','def',to_jsonb(true)),
  jsonb_build_object('key','callback_retry_minutes','kind','int','grp','Callbacks','label','Unanswered callback retried after (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','callback_max_tries','kind','int','grp','Callbacks','label','Tries before a callback is unreached','min',1,'max',6,'def',to_jsonb(3)),
  jsonb_build_object('key','callback_missed_hours','kind','int','grp','Callbacks','label','Overdue hours before a callback is missed','min',4,'max',72,'def',to_jsonb(24)),
  jsonb_build_object('key','rest_soft_days','kind','int','grp','Rests','label','"Not interested — soft" rest (days)','min',1,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','rest_hard_days','kind','int','grp','Rests','label','"Not interested — hard" rest (days)','min',1,'max',120,'def',to_jsonb(20)),
  jsonb_build_object('key','recycle_provider_days','kind','int','grp','Rests','label','"Has provider" auto-return (days, 0 = off)','min',0,'max',365,'def',to_jsonb(0)),
  jsonb_build_object('key','shift_hours','kind','num','grp','Pace','label','Shift length (hours)','min',1,'max',16,'def',to_jsonb(8)),
  jsonb_build_object('key','wrapup_seconds','kind','int','grp','Pace','label','Wrap-up countdown (seconds, 0 = off)','min',0,'max',300,'def',to_jsonb(20)),
  jsonb_build_object('key','alerts','kind','json','grp','Alerts','label','Alert thresholds','help','idle_minutes, long_call_minutes, pace_pct, callback_overdue_minutes, celebrate, spam, sync_quiet_minutes, console_quiet_days, outside_calls, radar_approvals.','def','{}'::jsonb),
  jsonb_build_object('key','spam_alert_drop_pts','kind','num','grp','Alerts','label','Spam alert: connect-rate drop (points)','min',1,'max',50,'def',to_jsonb(10)),
  jsonb_build_object('key','radar_deal_per_agent','kind','int','grp','Radar','label','Radar leads per proposed list','help','The radar proposes one list per agent and waits for a manager to approve it; the next is proposed once that one is dialed through. 0 turns the radar lists off.','min',0,'max',500,'def',to_jsonb(100)),
  jsonb_build_object('key','missed_call_threshold','kind','int','grp','Radar','label','Missed tries before "never answers"','min',2,'max',10,'def',to_jsonb(4)),
  jsonb_build_object('key','seasons','kind','json','grp','Radar','label','Seasonal windows','help','A list of {label, keys, months, states}.','def','[]'::jsonb),
  jsonb_build_object('key','best_time','kind','json','grp','Model','label','Best-time-to-call model','help','use_in_queue, days, min_dials, min_total, prior.','def','{}'::jsonb),
  jsonb_build_object('key','ai_summaries_enabled','kind','bool','grp','Model','label','Fetch Zoom AI call summaries','def',to_jsonb(false))
)
$$;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.list_outstanding(bigint), public.approve_list(bigint) from public, anon;
grant execute on function public.list_outstanding(bigint), public.approve_list(bigint) to authenticated;
