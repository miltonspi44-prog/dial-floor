-- Dial Floor · 0015 pacing (Phase 2 · A4)
--   · a wrap-up countdown after each logged call (wrapup_seconds, 0 = off). It
--     only paces: the next dial is always the agent's own key press, so the floor
--     stays manual dialing (no auto-dial on a timer, ever)
--   · pausing takes a reason (break, lunch, meeting, training, tech trouble, or
--     other with a note): the floor board shows it, and pace leaves the time out
--   · pace: dials and talk time per active hour today (from the first dial, less
--     the time paused), against the daily dial target spread over the shift
--     (shift_hours)

insert into public.app_settings (key, value) values
  ('wrapup_seconds', '20'),
  ('shift_hours', '8')
on conflict (key) do nothing;

-- today's floor reads attempts by time; the per-agent index doesn't cover that
create index if not exists attempts_clicked_idx on public.attempts (clicked_at desc);

-- -------------------------------------------------------------- agent_breaks --
create table public.agent_breaks (
  id bigint generated always as identity primary key,
  agent_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (reason in ('break', 'lunch', 'meeting', 'training', 'tech', 'other')),
  note text,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);
create index agent_breaks_agent_idx on public.agent_breaks (agent_id, started_at desc);
create unique index agent_breaks_open_idx on public.agent_breaks (agent_id) where ended_at is null;
alter table public.agent_breaks enable row level security;
create policy agent_breaks_read on public.agent_breaks for select to authenticated using (true);

-- ---------------------------------------------------------------- pause/resume --
create or replace function public.pause_work(p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_reclaim interval := make_interval(mins => coalesce((public.setting('reclaim_minutes'))::int, 30));
  b agent_breaks%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_reason is null or p_reason not in ('break', 'lunch', 'meeting', 'training', 'tech', 'other') then
    raise exception 'pick a reason for the pause';
  end if;
  if p_reason = 'other' and nullif(btrim(p_note), '') is null then
    raise exception 'say what the pause is for';
  end if;
  -- a call still open gets its outcome first (the same test next_lead resumes with)
  if exists (select 1 from attempts a join lead_state ls on ls.lead_id = a.lead_id
              where a.agent_id = v_uid and (a.disposition is null or a.auto_logged)
                and ls.state = 'in_progress' and ls.owner_agent = v_uid
                and a.clicked_at > now() - v_reclaim) then
    raise exception 'log the call you are on first';
  end if;

  select * into b from agent_breaks where agent_id = v_uid and ended_at is null;
  if found then return to_jsonb(b); end if;  -- already paused
  insert into agent_breaks (agent_id, reason, note)
    values (v_uid, p_reason, nullif(btrim(p_note), '')) returning * into b;
  -- the lead on screen goes back for someone else
  update lead_state set reserved_by = null, reserved_until = null where reserved_by = v_uid;
  insert into agent_status (agent_id, status, lead_id, lead_name, phone_display, since, updated_at)
  values (v_uid, 'break', null, null, null, now(), now())
  on conflict (agent_id) do update
    set status = 'break', lead_id = null, lead_name = null, phone_display = null, since = now(), updated_at = now();
  return to_jsonb(b);
end $$;

create or replace function public.resume_work()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); b agent_breaks%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  update agent_breaks set ended_at = now() where agent_id = v_uid and ended_at is null returning * into b;
  insert into agent_status (agent_id, status, since, updated_at) values (v_uid, 'idle', now(), now())
  on conflict (agent_id) do update set status = 'idle', since = now(), updated_at = now();
  if b.id is null then return jsonb_build_object('resumed', false); end if;
  return jsonb_build_object('resumed', true, 'minutes', round(extract(epoch from b.ended_at - b.started_at) / 60));
end $$;

-- -------------------------------------------------------------------- pace --
-- Today for everyone on the floor: activity, the time paused since the first
-- dial, and the rates per active hour (settled after the first quarter hour).
-- Talk time is what the funnel counts: Zoom's duration of answered calls.
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
    cross join lateral (
      select count(*) as dials,
             count(*) filter (where x.connected) as connects,
             count(*) filter (where public.is_conversation(x.connected, x.disposition)) as conversations,
             count(*) filter (where x.disposition in ('chance_website', 'sale_closed')) as handoffs,
             coalesce(sum(x.duration_seconds) filter (where x.call_result = 'answered'), 0)::bigint as talk_seconds,
             min(x.clicked_at) as first_dial
        from attempts x where x.agent_id = p.id and x.clicked_at >= t.t0) a
    left join lateral (  -- paused since the first dial
      select sum(extract(epoch from coalesce(b.ended_at, now()) - greatest(b.started_at, a.first_dial))) as s
        from agent_breaks b
       where b.agent_id = p.id and a.first_dial is not null and coalesce(b.ended_at, now()) > a.first_dial) pz on true
    cross join lateral (
      select case when a.first_dial is null then 0::numeric
                  else greatest(0, extract(epoch from now() - a.first_dial) - coalesce(pz.s, 0)) end as s) act
    left join agent_breaks ob on ob.agent_id = p.id and ob.ended_at is null
   where p.active
$$;

-- the Dial page's strip: my day, my pace, the target pace, the wrap-up length
create or replace function public.my_pace()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  r record;
  v_target numeric := (select target from kpi_targets where metric = 'dials_per_day' and scope = 'agent_day');
  v_shift numeric := greatest(1, least(coalesce((public.setting('shift_hours'))::numeric, 8), 16));
  ob agent_breaks%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into r from public.floor_pace() f where f.agent_id = auth.uid();
  -- a paused agent taken off the floor still sees the pause to end
  select * into ob from agent_breaks where agent_id = auth.uid() and ended_at is null;
  return jsonb_build_object(
    'dials', coalesce(r.dials, 0), 'connects', coalesce(r.connects, 0),
    'conversations', coalesce(r.conversations, 0), 'handoffs', coalesce(r.handoffs, 0),
    'talk_seconds', coalesce(r.talk_seconds, 0),
    'active_minutes', round(coalesce(r.active_seconds, 0) / 60), 'paused_minutes', round(coalesce(r.paused_seconds, 0) / 60),
    'dials_per_hour', r.dials_per_hour, 'talk_minutes_per_hour', r.talk_minutes_per_hour,
    'target', v_target, 'shift_hours', v_shift,
    'target_per_hour', case when v_target > 0 then round(v_target / v_shift, 1) end,
    'wrapup_seconds', greatest(0, coalesce((public.setting('wrapup_seconds'))::int, 20)),
    'break', case when ob.id is null then null
                  else jsonb_build_object('reason', ob.reason, 'note', ob.note, 'since', ob.started_at) end);
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.pause_work(text, text), public.resume_work(), public.floor_pace(), public.my_pace()
  from public, anon;
grant execute on function public.pause_work(text, text), public.resume_work(), public.floor_pace(), public.my_pace()
  to authenticated;
