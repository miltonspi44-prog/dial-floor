-- Dial Floor · 0019 leaderboard (Phase 2 · E5)
--   Deliberately light, and activity only: dials and conversations. Nothing here
--   scores outcomes, so there are no points to win by burning leads.
--   · leaderboard: today or this week, with each agent's streak (working days in a
--     row at the daily dial target; today counts once it is hit, and a day not yet
--     over never breaks one)
--   · power hours: a manager starts a sprint (dials or conversations, N minutes,
--     optionally "first to N"); the floor board and the Dial page show the race
--   · call of the day: everyone gets one vote a day for a conversation someone
--     else had today
--   The bell for a chance given or a sale closed is E4's win alert (0016).

create table public.sprints (
  id bigint generated always as identity primary key,
  name text not null,
  metric text not null check (metric in ('dials', 'conversations')),
  goal int check (goal > 0),              -- "first to N"; null = most by the end
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index sprints_ends_idx on public.sprints (ends_at desc);
alter table public.sprints enable row level security;
create policy sprints_read on public.sprints for select to authenticated using (true);

create table public.call_votes (
  vote_date date not null,
  voter uuid not null references public.profiles(id) on delete cascade,
  attempt_id bigint not null references public.attempts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (vote_date, voter)
);
create index call_votes_attempt_idx on public.call_votes (attempt_id);
alter table public.call_votes enable row level security;
create policy call_votes_read on public.call_votes for select to authenticated using (true);

-- ------------------------------------------------------------------ streaks --
-- working days (business_hours.days) in a row at the daily dial target (1 dial
-- when no target is set), counted back from today over the last 60 days
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

-- -------------------------------------------------------------- leaderboard --
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
      from attempts x where x.clicked_at >= v_from group by x.agent_id
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

-- ------------------------------------------------------------ power hours --
create or replace function public.start_sprint(p_name text, p_metric text, p_minutes int, p_goal int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s sprints%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_metric is null or p_metric not in ('dials', 'conversations') then raise exception 'race on dials or conversations'; end if;
  if p_minutes is null or p_minutes < 5 or p_minutes > 240 then raise exception 'a sprint runs 5 to 240 minutes'; end if;
  if p_goal is not null and p_goal < 1 then raise exception 'the goal must be 1 or more'; end if;
  -- one race at a time: a new one ends the one running
  update sprints set ends_at = now() where ends_at > now();
  insert into sprints (name, metric, goal, ends_at, created_by)
    values (coalesce(nullif(btrim(p_name), ''), 'Power hour'), p_metric, p_goal,
            now() + make_interval(mins => p_minutes), auth.uid())
    returning * into s;
  return to_jsonb(s);
end $$;

create or replace function public.end_sprint()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  update sprints set ends_at = now() where ends_at > now();
end $$;

-- the race running now, or the last one (finished in the past 12 hours) with its winner
create or replace function public.sprint_board()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  s sprints%rowtype;
  v_to timestamptz;
  v_rows jsonb;
  v_win jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into s from sprints where ends_at > now() - interval '12 hours' order by ends_at desc, id desc limit 1;
  if not found then return null; end if;
  v_to := least(s.ends_at, now());
  with ev as (  -- a dial counts when placed, a conversation when its outcome is logged
    select x.agent_id, case when s.metric = 'dials' then x.clicked_at else coalesce(x.disposed_at, x.clicked_at) end as t
      from attempts x
     where x.clicked_at >= s.starts_at - interval '2 hours' and x.clicked_at <= v_to
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
  return jsonb_build_object('id', s.id, 'name', s.name, 'metric', s.metric, 'goal', s.goal,
                            'starts_at', s.starts_at, 'ends_at', s.ends_at, 'running', s.ends_at > now(),
                            'rows', v_rows, 'winner', v_win);
end $$;

-- --------------------------------------------------------- call of the day --
create or replace function public.vote_call(p_attempt_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_today date := public.business_date();
  a attempts%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and active) then raise exception 'your account is deactivated'; end if;
  if p_attempt_id is null then  -- take my vote back
    delete from call_votes where vote_date = v_today and voter = v_uid;
    return jsonb_build_object('voted', null);
  end if;
  select * into a from attempts where id = p_attempt_id;
  if not found or a.disposition is null or not public.is_conversation(a.connected, a.disposition)
     or a.clicked_at < public.business_day_start() then
    raise exception 'vote for a conversation from today';
  end if;
  if a.agent_id = v_uid then raise exception 'vote for someone else''s call'; end if;
  insert into call_votes (vote_date, voter, attempt_id) values (v_today, v_uid, p_attempt_id)
    on conflict (vote_date, voter) do update set attempt_id = excluded.attempt_id, created_at = now();
  return jsonb_build_object('voted', p_attempt_id,
                            'votes', (select count(*) from call_votes where vote_date = v_today and attempt_id = p_attempt_id));
end $$;

-- the Dial page's once-a-minute look at the floor: the race and the bells
create or replace function public.floor_pulse()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'sprint', public.sprint_board(),
    'wins', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(public.floor_alerts()) x
              where x->>'kind' = 'win'));
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.streaks(), public.leaderboard(text), public.start_sprint(text, text, int, int),
  public.end_sprint(), public.sprint_board(), public.vote_call(bigint), public.floor_pulse() from public, anon;
grant execute on function public.streaks(), public.leaderboard(text), public.start_sprint(text, text, int, int),
  public.end_sprint(), public.sprint_board(), public.vote_call(bigint), public.floor_pulse() to authenticated;
