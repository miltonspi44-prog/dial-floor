-- Dial Floor · 0027 outcomes that tell the truth
-- Four queue-machine fixes from the focus list, each reproduced first in
-- supabase/tests/groups/38_outcomes.sql:
--   · 17 a dial Zoom never placed (the zoom:// link went nowhere: Zoom closed,
--        the tab died before the call left the machine) still counted as a dial
--        for ever — in pace, in the funnel, against the lead's daily cap and
--        redial gap. One of the four attempts live today is exactly this.
--   · 18 a callback nobody picked up was marked "missed" after the retries ran
--        out, and a callback killed by somebody else's outcome (a park, a
--        suppression through a twin record) was marked "missed" too. Both
--        lowered the agent's callbacks-kept rate for things that weren't theirs
--        to keep. "missed" now means the one thing a manager would mean by it:
--        the agent never honoured the promise.
--   · 20 rest, the daily cap and the redial gap were per lead record, not per
--        business: a business imported twice could be called four times a day,
--        and a 20-day "not interested" on one record didn't rest its twin.
--   · 25 deactivating an agent stranded their promises: their callbacks kept
--        raising overdue alerts and their lists fenced leads off from everyone,
--        until a manager also pressed "hand back" — a step nothing pointed at.

-- --------------------------------------------------------------- settings --
insert into public.app_settings (key, value) values
  ('callback_missed_hours', '24')  -- a promise this long overdue, never dialed, is missed
on conflict (key) do nothing;

-- ------------------------------------------------------------- constraints --
-- HAND-APPLY AT LIVE TIME: the two swaps below contain "drop constraint", which
-- the management API's confirmation scanner stalls on (the same wall 0022's
-- refresh_lead hit — see that file). They go through the dashboard's SQL editor;
-- everything else in this file applies through the API.
alter table public.attempts drop constraint attempts_disposition_check;
alter table public.attempts add constraint attempts_disposition_check check (disposition in (
  'no_answer','busy_failed','disconnected','voicemail','wrong_number','gatekeeper_end',
  'not_interested_soft','not_interested_hard','has_provider','dm_not_in','callback',
  'email_requested','dnc','chance_website','sale_closed','language_barrier','skipped',
  'not_placed'));

alter table public.callbacks drop constraint callbacks_status_check;
alter table public.callbacks add constraint callbacks_status_check check (status in (
  'scheduled',   -- the promise, still open
  'done',        -- the owner called back and a person answered
  'missed',      -- the owner never honoured it (callback_missed_hours past due, untried)
  'unreached',   -- the owner tried, callback_max_tries times, and nobody picked up
  'cancelled',   -- the promise died through nobody's fault: the lead was parked,
                 -- suppressed (possibly through a twin record), or its number went dead
  'requeued'));  -- a manager handed it back to the queue

-- ---------------------------------------------------------------- hand_back --
-- One definition of "take this person off the floor", shared by the Users tab
-- button and the deactivation trigger below. Internal: callers check who's asking.
create or replace function public.hand_back(p_id uuid, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cb int; v_lists int;
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
  update lead_state set reserved_by = null, reserved_until = null where reserved_by = p_id;
  return jsonb_build_object('callbacks', v_cb, 'lists', v_lists);
end $$;

create or replace function public.release_member(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  return public.hand_back(p_id, v_uid);
end $$;

-- 25: deactivating is taking them off the floor, so it hands everything back by
-- itself. Fires for the Users tab's toggle and for a removal (admin-users sets
-- active = false before banning the login), service role included. A lead they
-- were mid-call on stays theirs until the abandoned-call sweep settles it — the
-- call may still be real, and the sweep already knows how to tell.
create or replace function public.profile_deactivated()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.hand_back(new.id, auth.uid());
  return new;
end $$;

create trigger profiles_deactivate_hand_back
  after update of active on public.profiles
  for each row when (old.active and not new.active)
  execute function public.profile_deactivated();

-- ------------------------------------------------------------- wake_rested --
-- (0022's, with the not-placed dial, the unreached callback and the missed sweep)
create or replace function public.wake_rested()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_days int := coalesce((public.setting('recycle_provider_days'))::int, 0);
  v_reclaim interval := make_interval(mins => coalesce((public.setting('reclaim_minutes'))::int, 30));
  v_retry interval := make_interval(mins => coalesce((public.setting('callback_retry_minutes'))::int, 60));
  v_tries int := coalesce((public.setting('callback_max_tries'))::int, 3);
  v_missed interval := make_interval(hours => greatest(1, coalesce((public.setting('callback_missed_hours'))::int, 24)));
  -- One agent pressing Check must not pay for every call ever stranded. This is the
  -- first code that finishes them, so the first Check after release meets the whole
  -- backlog, and an API call has a statement timeout: unbounded, it timed out and the
  -- retry started the same work again, so it never got through. The oldest few per
  -- call clears the backlog over the morning instead, a Check at a time.
  v_sweep int := greatest(1, coalesce((public.setting('reclaim_sweep_max'))::int, 25));
  r record;
  att attempts%rowtype;
  cb callbacks%rowtype;
  v_state text;
  v_owner uuid;
  v_has_cb boolean;
  v_locked boolean;
begin
  update lead_state set state = 'queued', updated_at = now()
   where lead_id in (select lead_id from lead_state
                      where state = 'resting' and (rest_until is null or rest_until <= now())
                      for update skip locked);

  -- 18: a promise a day past due that its owner never dialed is missed — that is
  -- the one thing "missed" means now. Left "scheduled" it raised the overdue
  -- alert for ever and dragged nobody's rate down; a lead mid-call right now is
  -- left out because that call may be the promise being kept.
  -- A promise the queue itself refuses to serve is nobody's miss either: a rest
  -- on the business (somebody else's gatekeeper, a skip) blocks the owner from
  -- dialing, so while one holds, the due time rides to the rest's end instead of
  -- the miss clock running — the owner gets their day once dialing it is
  -- possible again. A lead the miss leaves locked with no promise left on it
  -- goes back to the queue, or nothing would ever serve it again.
  update callbacks c set due_at = tw.rest_ends
    from (select l2.phone_norm, max(ts.rest_until) as rest_ends
            from lead_state ts join leads l2 on l2.id = ts.lead_id
           where ts.rest_until > now() group by l2.phone_norm) tw, leads cl
   where cl.id = c.lead_id and cl.phone_norm = tw.phone_norm
     and c.status = 'scheduled' and c.due_at < tw.rest_ends;

  for r in
    select c.id, c.lead_id, c.agent_id from callbacks c
     where c.status = 'scheduled' and c.due_at < now() - v_missed
       and not exists (select 1 from lead_state ls
                        where ls.lead_id = c.lead_id and ls.state = 'in_progress')
     limit v_sweep
  loop
    update callbacks set status = 'missed' where id = r.id and status = 'scheduled';
    update lead_state ls set state = 'queued', owner_agent = null, updated_at = now()
     where ls.lead_id = r.lead_id and ls.state = 'callback_locked' and ls.owner_agent = r.agent_id
       and not exists (select 1 from callbacks c2 where c2.lead_id = ls.lead_id and c2.status = 'scheduled');
  end loop;

  -- A tab that dies mid-call leaves its lead in progress for good: build_list, the
  -- radar and recycling all want a fresh or queued lead, so they pass it over, and
  -- the no-answer Zoom wrote on the attempt never reaches the lead or its callback.
  -- Past reclaim_minutes the queue already counts the call as abandoned and offers the
  -- lead to somebody else, so finish it here the way the agent's no-answer would have.
  -- The agent who made the call still gets first refusal: next_lead hands an open call
  -- back to them before it reaches this. A rest someone else set is left alone.
  -- refresh_lead is deliberately not called per lead: it re-derives the timezone,
  -- rewrites the automatic intents and re-runs missed_tries, which costs far more than
  -- the sweep itself, and the lead's next outcome or sync does it anyway.
  -- Time alone does not mean the tab is gone. An agent thirty-five minutes into a
  -- conversation is still pinging every minute, and their tile still says they are on
  -- this lead: writing that call off would stamp a sale as a no-answer, hand the lead
  -- back to the pool mid-call and tell the radar this business never answers. A live
  -- heartbeat on this very lead is the one signal that says leave it alone.
  for r in
    select ls.lead_id from lead_state ls
     where ls.state = 'in_progress' and ls.in_progress_since <= now() - v_reclaim
       and not exists (select 1 from agent_status s
                        where s.lead_id = ls.lead_id and s.status in ('dialing', 'on_call')
                          and s.updated_at > now() - interval '5 minutes')
       -- A conversation nobody wrote down is left for a person to settle (below), so
       -- it must not be scanned either: this takes the oldest few each time, and a
       -- lead the loop will only ever skip would hold its place and starve the rest.
       and not exists (select 1 from attempts a
                        where a.lead_id = ls.lead_id and a.disposition is null
                          and (a.call_result = 'answered' or coalesce(a.duration_seconds, 0) > 0))
     order by ls.in_progress_since
     limit v_sweep
  loop
    -- Nothing here is waited for: an agent logging this very call holds these rows,
    -- and they are the one who should be finishing it, not us. The locks are all taken
    -- before anything is written, so giving up half way leaves nothing behind.
    perform 1 from lead_state
      where lead_id = r.lead_id and state = 'in_progress' and in_progress_since <= now() - v_reclaim
      for update skip locked;
    if not found then continue; end if;

    select * into att from attempts where lead_id = r.lead_id
      order by clicked_at desc, id desc limit 1 for update skip locked;
    v_locked := not found and exists (select 1 from attempts where lead_id = r.lead_id);
    -- Somebody is holding this call right now, which means they are logging it: theirs
    -- is the better outcome, so leave the whole lead to them and come back next time.
    if v_locked then continue; end if;

    -- A lead with no call at all, or whose last call the agent already logged, has
    -- nothing left to finish — but it is still sitting outside every queue. Freeing it
    -- is both the right answer and the only way it leaves this window: the sweep takes
    -- the oldest few each time, so a row it merely skipped would hold its place for
    -- ever and the backlog behind it would never clear.
    if not found or (att.disposition is not null and not att.auto_logged) then
      update lead_state set state = 'queued', owner_agent = null, in_progress_since = null,
          reserved_by = null, reserved_until = null, updated_at = now()
        where lead_id = r.lead_id;
      continue;
    end if;

    -- The callback this call was keeping belongs to the agent who made the call. Its
    -- own agent logging that call holds it and is waiting for the lead row this loop
    -- holds, so waiting for the callback in turn would deadlock the two: leave the
    -- whole lead to them instead, since their outcome is the better one anyway.
    v_has_cb := exists (select 1 from callbacks
                         where lead_id = r.lead_id and status = 'scheduled' and agent_id = att.agent_id);
    if v_has_cb then
      select * into cb from callbacks
        where lead_id = r.lead_id and status = 'scheduled' and agent_id = att.agent_id
        order by due_at limit 1
        for update skip locked;
      if not found then continue; end if;
    end if;

    -- This lead is coming off the agent whatever its outcome turns out to be, and the
    -- tab that was dialing it is gone, so the floor board should stop showing them on
    -- the call. Their last_seen is left where it is: the board reads that to show a
    -- browser that went quiet as offline, and the idle nudge only counts agents still
    -- seen, so touching it would turn a dead tab into somebody standing around.
    update agent_status set status = 'idle', lead_id = null, lead_name = null,
        phone_display = null
      where agent_id = att.agent_id and lead_id = r.lead_id and status in ('dialing', 'on_call');

    -- An answered call is a conversation. Zoom's webhook only writes the no-answer
    -- itself when nobody picked up, so an answered call nobody logged has no outcome
    -- at all — and writing "no answer" on it would tell the radar this business never
    -- answers and book a conversation as a miss. There is no outcome to guess, so this
    -- one is left exactly as it is: the lead stays with the agent who had the
    -- conversation, which keeps the call resumable if they come back and keeps it on
    -- the manager's long-call list if they do not. A person decides what happened —
    -- pushing the lead back to the queue is how a manager says "nothing came of it".
    if att.call_result = 'answered' or coalesce(att.duration_seconds, 0) > 0 then
      continue;
    end if;

    -- 17: no sign Zoom ever placed this call — no match, no call id, no result,
    -- and the webhook writes within seconds of a call ending. The click bought a
    -- dial that never rang anywhere, so it is closed as "not placed" (final, not
    -- a placeholder: there is no outcome for the agent to come back and log) and
    -- everything the click charged is given back — the day's cap, the redial gap,
    -- the totals. A callback it was serving keeps its due time untouched: nothing
    -- rang, so nothing was tried.
    if not att.matched and att.zoom_call_id is null and att.call_result is null then
      update attempts set
          disposition = 'not_placed',
          connected = false,
          auto_logged = false,
          disposed_at = now()
        where id = att.id;
      update lead_state set
          state = case when v_has_cb then 'callback_locked' else 'queued' end,
          owner_agent = case when v_has_cb then att.agent_id end,
          in_progress_since = null,
          reserved_by = null, reserved_until = null,
          attempts_today = case when attempts_today_date = public.business_date()
                                then greatest(0, attempts_today - 1) else attempts_today end,
          attempts_total = greatest(0, attempts_total - 1),
          last_attempt_at = (select max(a2.clicked_at) from attempts a2
                              where a2.lead_id = r.lead_id and a2.id <> att.id
                                and a2.disposition is distinct from 'not_placed'),
          updated_at = now()
        where lead_id = r.lead_id;
      continue;
    end if;

    update attempts set
        disposition = coalesce(disposition, 'no_answer'),
        connected = coalesce(connected, false),
        auto_logged = true,
        disposed_at = coalesce(disposed_at, now())
      where id = att.id;

    -- nobody picked up, so keep the promise and try again later
    v_state := 'queued';
    v_owner := null;
    if v_has_cb then
      if cb.tries + 1 < v_tries then
        update callbacks set tries = tries + 1, due_at = now() + v_retry where id = cb.id;
        v_state := 'callback_locked';
        v_owner := att.agent_id;
      else
        -- 18: the owner tried, every time, and the lead never picked up. That is
        -- the lead unreached, not the agent's promise missed.
        update callbacks set tries = tries + 1, status = 'unreached' where id = cb.id;
      end if;
    end if;

    update lead_state set state = v_state, owner_agent = v_owner, in_progress_since = null,
        reserved_by = null, reserved_until = null, updated_at = now()
      where lead_id = r.lead_id;
  end loop;

  if v_days > 0 then
    perform public.recycle_leads(array(select rc.lead_id from public.recycle_candidates('provider') rc
                                        where rc.parked_at <= now() - make_interval(days => v_days)), 'provider');
  end if;
end $$;

-- ------------------------------------------------------------ start_attempt --
-- (0022's, with the rest, cap and gap read per business — every lead record
--  sharing the phone number — instead of per record)
create or replace function public.start_attempt(p_lead_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_reclaim interval := make_interval(mins => coalesce((public.setting('reclaim_minutes'))::int, 30));
  v_max int := coalesce((public.setting('max_attempts_per_day'))::int, 2);
  v_gap interval := make_interval(mins => coalesce((public.setting('min_redial_minutes'))::int, 120));
  v_today date := public.business_date();
  l leads%rowtype;
  st lead_state%rowtype;
  v_attempt bigint;
  v_source text := 'pool';
  v_list bigint;
  v_overtaken boolean;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and active) then
    raise exception 'your account is deactivated — ask your manager';
  end if;
  select * into l from leads where id = p_lead_id;
  if not found then raise exception 'lead not found'; end if;

  select * into st from lead_state where lead_id = p_lead_id for update;
  if not found or st.state in ('suppressed', 'handoff') then
    raise exception 'this lead can no longer be dialed';
  end if;
  if exists (select 1 from suppression s where s.phone_norm = l.phone_norm) then
    raise exception 'this number is on the do-not-call list';
  end if;
  if st.state = 'in_progress' and st.owner_agent is distinct from v_uid
     and st.in_progress_since > now() - v_reclaim then
    raise exception 'another agent is already dialing this lead';
  end if;
  if st.state = 'callback_locked' and st.owner_agent is distinct from v_uid then
    raise exception 'this lead is locked to another agent''s callback';
  end if;
  if st.reserved_by is not null and st.reserved_by <> v_uid and st.reserved_until > now() then
    raise exception 'another agent has this lead open';
  end if;
  -- served while the window was open doesn't mean it still is (the lead stays loaded for minutes)
  if not local_ok(l.tz) then
    raise exception 'outside this lead''s calling window: it is % there',
      to_char(now() at time zone coalesce(l.tz, 'America/New_York'), 'FMHH12:MI AM');
  end if;

  -- where this dial came from, for the funnel (same order next_lead serves in)
  if exists (select 1 from callbacks c
              where c.lead_id = p_lead_id and c.agent_id = v_uid and c.status = 'scheduled'
                and c.due_at <= now() + interval '10 minutes') then
    v_source := 'callback';
  else
    select li.list_id into v_list
      from list_items li join lists ld on ld.id = li.list_id
      where li.lead_id = p_lead_id and li.served_at is null and ld.status = 'active'
        and (ld.agent_id = v_uid or ld.agent_id is null)
      order by (ld.agent_id is null), ld.list_date desc, li.position limit 1;
    if v_list is not null then v_source := 'list'; end if;
  end if;

  -- A reservation only holds a lead for ten minutes, so a lead that has been sitting
  -- on screen longer than that may have been served to somebody else, dialed and
  -- finished in the meantime. The dial has to be weighed against the queue as it is
  -- now, not against what the screen says: without this, a call logged off a stale
  -- screen quietly undoes the other agent's outcome, because a no-answer clears the
  -- rest they just set. What follows has to agree with next_lead, or an agent is
  -- handed a lead the Dial button then refuses.
  -- Everything here is read per business, not per record: one business scraped
  -- twice is two lead rows and one phone, and its rest, cap and gap are the
  -- business's. The twin's state lives on the twin's row, which is why each
  -- check walks every lead sharing the number (20).
  if v_source = 'callback' then
    -- An agent's own due callback is a promise, so it beats the daily cap and the
    -- redial gap: next_lead's first step serves it past both. It does not beat a
    -- park. A lead rested by somebody else's outcome is not served as a callback
    -- either, and dialing it anyway would wipe that rest out — which is how a
    -- 20-day "not interested" used to come back as nothing at all. A rest on the
    -- twin record is the same park: same business, same "leave them alone".
    if exists (select 1 from lead_state ts join leads t2 on t2.id = ts.lead_id
                where t2.phone_norm = l.phone_norm and ts.rest_until > now()) then
      raise exception 'this lead has been parked since you loaded it — press skip for the next one';
    end if;
  else
    if not (st.state in ('fresh', 'queued')
            or (st.state = 'in_progress'
                and (st.owner_agent = v_uid or st.in_progress_since <= now() - v_reclaim))
            or (st.state = 'callback_locked' and st.owner_agent = v_uid)) then
      raise exception 'this lead has been parked since you loaded it — press skip for the next one';
    end if;
    -- The rest, the daily cap and the redial gap are re-read unless the last call on
    -- this business was the agent's own: their own earlier calls are no surprise to
    -- them. A business with no call at all behind it is nobody's own, and a rest on
    -- one of those is somebody's Skip or a recycling pass — which is exactly the rest
    -- that must hold, so no attempt counts as somebody else. A dial Zoom never placed
    -- rang nowhere, so it is nobody's last call either.
    select a.agent_id <> v_uid into v_overtaken
      from attempts a join leads tl on tl.id = a.lead_id
      where tl.phone_norm = l.phone_norm and a.disposition is distinct from 'not_placed'
      order by a.clicked_at desc, a.id desc limit 1;
    if coalesce(v_overtaken, true) then
      if exists (select 1 from lead_state ts join leads t2 on t2.id = ts.lead_id
                  where t2.phone_norm = l.phone_norm and ts.rest_until > now()) then
        raise exception 'another agent has just been through this lead — press skip for the next one';
      end if;
      if (select coalesce(sum(ts.attempts_today), 0)
            from lead_state ts join leads t2 on t2.id = ts.lead_id
           where t2.phone_norm = l.phone_norm and ts.attempts_today_date = v_today) >= v_max then
        raise exception 'this lead has had all its calls for today — press skip for the next one';
      end if;
      if exists (select 1 from lead_state ts join leads t2 on t2.id = ts.lead_id
                  where t2.phone_norm = l.phone_norm and ts.last_attempt_at > now() - v_gap) then
        raise exception 'this lead was dialed since you loaded it — press skip for the next one';
      end if;
    end if;
  end if;

  insert into attempts (lead_id, agent_id, source, list_id)
    values (p_lead_id, v_uid, v_source, v_list) returning id into v_attempt;

  update lead_state set
    state = 'in_progress',
    owner_agent = v_uid,
    in_progress_since = now(),
    reserved_by = null,
    reserved_until = null,
    attempts_today = case when attempts_today_date = v_today then attempts_today + 1 else 1 end,
    attempts_today_date = v_today,
    attempts_total = attempts_total + 1,
    last_attempt_at = now(),
    updated_at = now()
  where lead_id = p_lead_id;

  -- dialed means served, whichever list it was waiting on
  update list_items li set served_at = now()
    from lists ld
    where li.lead_id = p_lead_id and li.list_id = ld.id and ld.status = 'active' and li.served_at is null;

  insert into agent_status (agent_id, status, lead_id, lead_name, phone_display, since, updated_at)
  values (v_uid, 'dialing', p_lead_id, l.name, l.phone_display, now(), now())
  on conflict (agent_id) do update
    set status = 'dialing', lead_id = excluded.lead_id, lead_name = excluded.lead_name,
        phone_display = excluded.phone_display, since = now(), updated_at = now();

  return jsonb_build_object('attempt_id', v_attempt, 'phone', l.phone_norm, 'display', l.phone_display);
end $$;

-- ---------------------------------------------------------------- next_lead --
-- (0022's, with the rest, cap and gap read per business across twin records)
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
  --    (even when deactivated meanwhile, so the call still gets its outcome).
  --    However old it is: a call can run well past reclaim_minutes, and the agent who
  --    made it still has to log it. Once wake_rested has finished a call for them the
  --    lead is out of progress, so it is no longer a resume. Read from the lead side,
  --    because an agent has at most one call in progress: this stays two index lookups
  --    however many calls they have made.
  --    Only ever the lead's newest call, logged or not. Picking the newest *unlogged*
  --    one instead would hand back a call from days ago whenever the call this lead is
  --    actually on had been logged already, and today's outcome would be written onto
  --    that old call — a wrong pair of times in the funnel and in the call log.
  select a.id, a.lead_id, a.clicked_at, a.disposition, a.auto_logged into r
    from lead_state ls
    join lateral (select x.* from attempts x
                   where x.lead_id = ls.lead_id and x.agent_id = v_uid
                   order by x.clicked_at desc, x.id desc limit 1) a on true
    where ls.state = 'in_progress' and ls.owner_agent = v_uid
    order by a.clicked_at desc limit 1;
  -- a webhook's auto-log is a placeholder, so that one is still the agent's to finish
  if found and (r.disposition is null or r.auto_logged) then
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
      -- A promise beats the daily cap and the redial gap, but not a park: a lead
      -- somebody else's outcome has rested is not dialable, and serving it as a
      -- callback only let the dial erase their rest. start_attempt refuses the same.
      -- The park is the business's, so a rest on a twin record parks this one too (20).
      and not exists (select 1 from lead_state ts join leads t2 on t2.id = ts.lead_id
                       where t2.phone_norm = l.phone_norm and ts.rest_until > now())
      -- Two agents can hold a promise on one business. Serving a lead that is locked to
      -- somebody else's callback only hands back a lead the dial then refuses, and the
      -- page reloads the same one behind the toast: the agent is stuck on it until they
      -- skip. Leave it to whoever holds the lock and move on to the next promise.
      and (ls.state <> 'callback_locked' or ls.owner_agent = v_uid)
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
        -- the same three, read off the twin records: one business, one budget (20)
        and not exists (select 1 from lead_state ts join leads t2 on t2.id = ts.lead_id
                         where t2.phone_norm = l.phone_norm and t2.id <> l.id
                           and (ts.rest_until > now() or ts.last_attempt_at > now() - v_gap))
        and (select coalesce(sum(ts.attempts_today), 0)
               from lead_state ts join leads t2 on t2.id = ts.lead_id
              where t2.phone_norm = l.phone_norm and ts.attempts_today_date = v_today) < v_max
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
        -- the same three, read off the twin records: one business, one budget (20)
        and not exists (select 1 from lead_state ts join leads t2 on t2.id = ts.lead_id
                         where t2.phone_norm = l.phone_norm and t2.id <> l.id
                           and (ts.rest_until > now() or ts.last_attempt_at > now() - v_gap))
        and (select coalesce(sum(ts.attempts_today), 0)
               from lead_state ts join leads t2 on t2.id = ts.lead_id
              where t2.phone_norm = l.phone_norm and ts.attempts_today_date = v_today) < v_max
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

-- --------------------------------------------------------- log_disposition --
-- (0022's, with the callback close-outs renamed to what actually happened: the
--  lead unreached, the promise cancelled by a park or a dead number, "missed"
--  reserved for the sweep above)
create or replace function public.log_disposition(p_attempt_id bigint, p_dispo text, p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  a attempts%rowtype;
  l leads%rowtype;
  cb callbacks%rowtype;
  v_has_cb boolean;
  v_connected boolean;
  v_rest interval;
  v_state text := 'queued';
  v_wb_status text;
  v_wb_note text;
  v_note text := nullif(p_args->>'note', '');
  v_due timestamptz;
  v_retry timestamptz;
  v_next jsonb;
  -- the page shows this where it would show the next lead, and offers Check again
  v_no_next text := 'Your call is saved. Loading the next lead did not work this time — press Check again.';
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into a from attempts where id = p_attempt_id for update;
  if not found then raise exception 'attempt not found'; end if;
  if a.agent_id <> v_uid and not is_manager() then raise exception 'not your attempt'; end if;

  -- Logged already (double key press, network retry): don't run the machine twice.
  -- A webhook auto-log is only a placeholder, so the agent's own key still counts.
  if a.disposed_at is not null and not a.auto_logged then
    begin
      v_next := next_lead();
    exception when query_canceled or others then
      raise warning 'next_lead failed for an already-logged attempt: % (%)', sqlerrm, sqlstate;
      v_next := jsonb_build_object('empty', true, 'hint', v_no_next);
    end;
    return jsonb_build_object('ok', true, 'already_logged', true, 'next', v_next);
  end if;

  select * into l from leads where id = a.lead_id;

  v_connected := p_dispo in ('wrong_number','gatekeeper_end','not_interested_soft','not_interested_hard',
                             'has_provider','dm_not_in','callback','email_requested','dnc',
                             'chance_website','sale_closed','language_barrier');

  -- The callback this call was keeping, if any, is the dialing agent's own. 0005
  -- took whichever callback was due on the lead: when a second agent picked the
  -- lead up and logged it, the first agent's promise was counted as tried and the
  -- lead was locked to the second agent, who could then never dial it.
  select * into cb from callbacks
    where lead_id = a.lead_id and status = 'scheduled' and agent_id = a.agent_id
    order by due_at limit 1
    for update;
  v_has_cb := found;

  update attempts set
    disposition = p_dispo,
    connected = v_connected,
    auto_logged = false,
    voicemail_left = case when p_dispo = 'voicemail' then coalesce((p_args->>'left_message')::boolean, false) end,
    note = coalesce(v_note, note),
    disposed_at = now()
  where id = p_attempt_id;

  case p_dispo
    when 'not_interested_soft' then
      v_rest := make_interval(days => coalesce((public.setting('rest_soft_days'))::int, 10)); v_state := 'resting';
      v_wb_status := 'not_interested';
    when 'not_interested_hard' then
      v_rest := make_interval(days => coalesce((public.setting('rest_hard_days'))::int, 20)); v_state := 'resting';
      v_wb_status := 'not_interested';
    when 'language_barrier' then
      v_rest := interval '60 days'; v_state := 'resting'; v_wb_status := 'not_interested';
    when 'has_provider' then
      v_state := 'provider_list'; v_wb_status := 'long_term'; v_wb_note := 'has provider';
    when 'gatekeeper_end' then
      v_rest := interval '3 days'; v_state := 'queued';
    when 'dm_not_in' then
      -- "try after four" is the lead's four o'clock: retry_local is wall-clock time
      -- on their side, like the callback's due_local. retry_at stays what it was,
      -- an exact moment the caller already worked out.
      v_retry := case when nullif(p_args->>'retry_local', '') is not null
                      then (p_args->>'retry_local')::timestamp at time zone coalesce(l.tz, 'America/New_York')
                      else (p_args->>'retry_at')::timestamptz end;
      if nullif(p_args->>'retry_local', '') is not null and v_retry <= now() then
        raise exception 'that time has already gone past — pick a later one';
      end if;
      v_rest := coalesce(v_retry - now(), interval '1 day'); v_state := 'queued';
    when 'voicemail' then
      v_state := 'queued';
    when 'no_answer' then v_state := 'queued';
    when 'busy_failed' then v_state := 'queued';
    when 'skipped' then v_state := 'queued';
    when 'disconnected' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'disconnected', p_attempt_id) on conflict do nothing;
      v_wb_status := 'wrong_number'; v_wb_note := 'disconnected number';
    when 'wrong_number' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'wrong_number', p_attempt_id) on conflict do nothing;
      v_wb_status := 'wrong_number';
    when 'dnc' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'dnc', p_attempt_id) on conflict do nothing;
      v_wb_status := 'do_not_call'; v_wb_note := coalesce(v_note, 'asked not to be called');
    when 'callback' then
      -- due_local is the lead's wall-clock time ("call me at 2"), read in the lead's own timezone
      v_due := case when nullif(p_args->>'due_local', '') is not null
                    then (p_args->>'due_local')::timestamp at time zone coalesce(l.tz, 'America/New_York')
                    else (p_args->>'due_at')::timestamptz end;
      if v_due is null then raise exception 'callback needs a date and time'; end if;
      -- A month typed wrong used to book the callback in the past, and the lead came
      -- straight back as due on the same screen. Only the time the agent types is
      -- checked: due_at is the exact moment a caller has already worked out, and
      -- "due now" is a fair thing to ask for.
      if nullif(p_args->>'due_local', '') is not null and v_due <= now() then
        raise exception 'that time has already gone past — pick a later one';
      end if;
      v_state := 'callback_locked'; v_wb_status := 'callback';
    when 'email_requested' then
      if p_args->>'email' is null then raise exception 'email_requested needs email'; end if;
      insert into email_queue (lead_id, email, flagged_by) values (a.lead_id, p_args->>'email', v_uid);
      update leads set email = p_args->>'email' where id = a.lead_id;
      v_rest := interval '3 days'; v_state := 'queued'; v_wb_status := 'long_term'; v_wb_note := 'asked for email';
    when 'chance_website' then
      insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
        values (a.lead_id, to_jsonb(l), 'chance_website', p_args->>'summary', (p_args->>'rating')::int, a.agent_id);
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'handoff_website', p_attempt_id) on conflict do nothing;
      v_state := 'handoff'; v_wb_status := 'captured'; v_wb_note := coalesce(p_args->>'summary', 'gave upfront - website');
    when 'sale_closed' then
      insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
        values (a.lead_id, to_jsonb(l), 'sale_closed', p_args->>'summary', (p_args->>'rating')::int, a.agent_id);
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'handoff_sale', p_attempt_id) on conflict do nothing;
      v_state := 'handoff'; v_wb_status := 'captured'; v_wb_note := coalesce(p_args->>'summary', 'sale closed - seo/receptionist');
    else
      raise exception 'unknown disposition %', p_dispo;
  end case;

  -- Close out the callback this call was keeping — the dialing agent's own, so the
  -- lead goes back to the agent who made the promise. Nobody picked up: keep the
  -- promise and try again later, up to callback_max_tries. After that the lead is
  -- unreached — the agent kept trying, so it is not their miss (18). A person
  -- answering settles the promise as done; a dead number cancels it, since there
  -- is nothing left to call.
  if v_has_cb then
    if p_dispo in ('no_answer', 'voicemail', 'busy_failed', 'skipped')
       and cb.tries + 1 < coalesce((public.setting('callback_max_tries'))::int, 3) then
      update callbacks set tries = tries + 1,
          due_at = now() + make_interval(mins => coalesce((public.setting('callback_retry_minutes'))::int, 60))
        where id = cb.id;
      v_state := 'callback_locked'; v_rest := null;
    else
      update callbacks set tries = tries + 1,
          status = case when v_connected then 'done'
                        when p_dispo = 'disconnected' then 'cancelled'
                        else 'unreached' end
        where id = cb.id;
    end if;
  end if;

  if p_dispo = 'callback' then
    insert into callbacks (lead_id, agent_id, due_at) values (a.lead_id, a.agent_id, v_due);
  end if;

  -- A lead this call has parked cannot have a promise kept on it, whoever made the
  -- promise. Leaving another agent's callback scheduled on a lead that is now resting
  -- for twenty days served it straight back to them as due, and their no-answer then
  -- cleared the rest this call had just set — the very thing start_attempt's stale-screen
  -- check exists to stop. The promise dies with the park, through no fault of whoever
  -- made it, so it is cancelled rather than missed (18).
  if v_state not in ('queued', 'callback_locked') then
    update callbacks set status = 'cancelled'
      where lead_id = a.lead_id and status = 'scheduled';
  end if;

  -- A dead or excluded number is dead for every lead record that carries it, and the
  -- console has to hear about all of them: it is one business scraped twice, and the
  -- record nobody wrote back stays dialable there (and a re-scrape brings the number
  -- back). The sync worker pushes whatever is left with writeback_done = false.
  if v_state in ('suppressed', 'handoff') then
    update lead_state ls set
        state = case when ls.state in ('suppressed', 'handoff') then ls.state else 'suppressed' end,
        owner_agent = null, reserved_by = null, reserved_until = null,
        updated_at = now()
      from leads x
      where x.id = ls.lead_id and x.phone_norm = l.phone_norm and ls.lead_id <> a.lead_id;

    -- What the console is told about the twin is only overwritten by something at least
    -- as final, ranked the way refresh_lead ranks the suppression reasons. Two agents
    -- can be on the two records of one business at the same time, and the console keeps
    -- one status per record: without this, a wrong number logged a moment later
    -- replaced "sold" on the record that was sold, and the sync pushed that.
    if v_wb_status is not null then
      update lead_state ls set
          writeback_status = v_wb_status,
          writeback_note = coalesce(v_wb_note, v_note, ls.writeback_note),
          writeback_done = false,
          updated_at = now()
        from leads x
        where x.id = ls.lead_id and x.phone_norm = l.phone_norm and ls.lead_id <> a.lead_id
          and case v_wb_status when 'do_not_call' then 1 when 'captured' then 2
                               when 'wrong_number' then 3 else 9 end
              <= case ls.writeback_status when 'do_not_call' then 1 when 'captured' then 2
                                          when 'wrong_number' then 3 else 9 end;
    end if;

    update callbacks c set status = 'cancelled'
      from leads x
      where x.id = c.lead_id and x.phone_norm = l.phone_norm and c.status = 'scheduled';
  end if;

  update lead_state set
    state = v_state,
    -- a lead left locked is locked to the agent whose call this is: the callback it
    -- keeps is now always their own, so there is no other owner to carry
    owner_agent = case when v_state in ('callback_locked','in_progress') then a.agent_id else null end,
    rest_until = case when v_rest is not null then now() + v_rest else null end,
    connects_total = connects_total + case when v_connected then 1 else 0 end,
    in_progress_since = null,
    reserved_by = null,
    reserved_until = null,
    writeback_status = coalesce(v_wb_status, writeback_status),
    writeback_note = coalesce(v_wb_note, v_note, writeback_note),
    writeback_done = case when v_wb_status is null then writeback_done else false end,
    updated_at = now()
  where lead_id = a.lead_id;

  perform refresh_lead(a.lead_id);

  insert into agent_status (agent_id, status, lead_id, lead_name, phone_display, since, updated_at)
  values (v_uid, 'idle', null, null, null, now(), now())
  on conflict (agent_id) do update
    set status = 'idle', lead_id = null, lead_name = null, phone_display = null, since = now(), updated_at = now();

  -- The outcome is logged and must stay logged. Fetching the next lead is a
  -- convenience bolted onto the same call, and when it fails (a setting someone
  -- typed wrong, a lock that timed out) the whole transaction used to roll back:
  -- the agent's call was lost and pressing the key again just repeated the error.
  -- A cancel has to be named: "when others" does not catch one, and the statement
  -- timeout the API puts on every call is the failure that actually happens here —
  -- it was reaching the client as a lost outcome rather than as an empty next.
  -- This is still a patch over the shape of the call, not a fix for it: if the
  -- connection itself goes, nothing in here runs at all, so the page fetching the
  -- next lead as its own request is what this really wants.
  begin
    v_next := next_lead();
  exception when query_canceled or others then
    -- the agent is only told to press Check again, so leave the real reason in the log
    raise warning 'next_lead failed after % was logged: % (%)', p_dispo, sqlerrm, sqlstate;
    v_next := jsonb_build_object('empty', true, 'hint', v_no_next);
  end;
  return jsonb_build_object('ok', true, 'next', v_next);
end $$;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.hand_back(uuid, uuid), public.profile_deactivated()
  from public, anon, authenticated;
revoke execute on function public.release_member(uuid), public.start_attempt(bigint),
  public.next_lead(), public.log_disposition(bigint, text, jsonb), public.wake_rested()
  from public, anon;
revoke execute on function public.wake_rested() from authenticated;
grant execute on function public.release_member(uuid), public.start_attempt(bigint),
  public.next_lead(), public.log_disposition(bigint, text, jsonb) to authenticated;
