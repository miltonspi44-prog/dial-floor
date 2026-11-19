-- Dial Floor · 0052 a handoff recorded by hand counts for the agent picked
-- A business that was dialed, did not pick up, and later called back to give a
-- chance (or buy) is recorded by hand (0042). That made the handoff, but no
-- agent's numbers moved: the floor board, the Dial page, the funnel, coaching
-- and scorecards all count handoffs from logged calls, and there was no call.
-- And it was credited to the list's agent, while two people can share one Zoom
-- number, so whoever took the callback may not be the list's agent.
-- Now:
--   · record_handoff credits the agent the manager picks, and logs the callback
--     as that agent's call with the outcome (chance given or sale), so it counts
--     in every one of their stats like a handoff logged from a dial: one call,
--     one conversation, one handoff. The call is marked matched, so the Zoom
--     webhook never attaches a recording to it, and the handoff keeps a link to
--     it (handoff_ledger.manual_attempt_id).
--   · reassign_handoff gives a handoff recorded by hand to someone else, its
--     call with it. A handoff logged from a call belongs to whoever made that
--     call and stays theirs.
-- Applies through the management API as it is.

alter table public.handoff_ledger
  add column if not exists manual_attempt_id bigint references public.attempts(id) on delete set null;
create index if not exists handoff_ledger_manual_attempt_idx on public.handoff_ledger (manual_attempt_id);

-- (0042's, crediting the agent picked and logging the callback as their call)
create or replace function public.record_handoff(p_lead_id bigint, p_kind text, p_summary text default null, p_agent uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l leads%rowtype;
  v_state text;
  v_agent uuid;
  v_note text;
  v_attempt bigint;
  v_handoff bigint;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_kind not in ('chance_website', 'sale_closed') then raise exception 'the kind is chance_website or sale_closed'; end if;
  select * into l from leads where id = p_lead_id;
  if not found then raise exception 'lead not found'; end if;
  select state into v_state from lead_state where lead_id = p_lead_id;
  if v_state = 'handoff' then raise exception 'this lead is already handed off'; end if;
  -- credited to the agent the manager picked (whoever took the callback), else to the manager
  v_agent := coalesce(p_agent, auth.uid());
  if not exists (select 1 from profiles where id = v_agent) then raise exception 'that login does not exist'; end if;
  v_note := coalesce(nullif(trim(p_summary), ''),
                     case p_kind when 'chance_website' then 'called back - gave upfront - website' else 'called back - sale closed' end);

  -- the callback, as the agent's call: it is what every stat counts a handoff from
  insert into attempts (lead_id, agent_id, clicked_at, disposed_at, connected, disposition, note, call_result, source, matched)
    values (l.id, v_agent, now(), now(), true, p_kind, v_note, 'Called back: handoff recorded by hand', 'callback', true)
    returning id into v_attempt;
  insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id, manual_attempt_id)
    values (l.id, to_jsonb(l), p_kind, v_note, null, v_agent, v_attempt)
    returning id into v_handoff;
  insert into suppression (phone_norm, place_id, reason)
    values (l.phone_norm, l.place_id, case p_kind when 'chance_website' then 'handoff_website' else 'handoff_sale' end)
    on conflict do nothing;

  -- the record itself: handed off, and the console told it was captured
  update lead_state set
      state = 'handoff', owner_agent = null, reserved_by = null, reserved_until = null,
      in_progress_since = null, rest_until = null,
      writeback_status = 'captured', writeback_note = v_note, writeback_done = false, updated_at = now()
    where lead_id = l.id;
  -- its twins (one business scraped twice): out of every queue, and the console told
  -- the same unless it already holds something at least as final
  update lead_state ls set
      state = case when ls.state in ('suppressed', 'handoff') then ls.state else 'suppressed' end,
      owner_agent = null, reserved_by = null, reserved_until = null, updated_at = now()
    from leads x
    where x.id = ls.lead_id and x.phone_norm = l.phone_norm and ls.lead_id <> l.id;
  update lead_state ls set
      writeback_status = 'captured', writeback_note = v_note, writeback_done = false, updated_at = now()
    from leads x
    where x.id = ls.lead_id and x.phone_norm = l.phone_norm and ls.lead_id <> l.id
      and 2 <= case ls.writeback_status when 'do_not_call' then 1 when 'captured' then 2
                                        when 'wrong_number' then 3 else 9 end;
  update callbacks c set status = 'cancelled'
    from leads x
    where x.id = c.lead_id and x.phone_norm = l.phone_norm and c.status = 'scheduled';
  perform refresh_lead(l.id);

  return jsonb_build_object('lead_id', l.id, 'kind', p_kind, 'agent_id', v_agent,
    'handoff_id', v_handoff, 'attempt_id', v_attempt);
end $$;

-- Give a handoff recorded by hand to someone else, and its call with it: the
-- handoff and the call move together, so every stat follows. One logged from a
-- dial is whoever made that call's, and stays theirs.
create or replace function public.reassign_handoff(p_handoff bigint, p_agent uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare h handoff_ledger%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  select * into h from handoff_ledger where id = p_handoff;
  if not found then raise exception 'that handoff does not exist'; end if;
  if h.manual_attempt_id is null then
    raise exception 'only a handoff recorded by hand can be given to someone else: one logged from a call belongs to whoever made the call';
  end if;
  if not exists (select 1 from profiles where id = p_agent) then raise exception 'that login does not exist'; end if;
  update handoff_ledger set agent_id = p_agent where id = p_handoff;
  update attempts set agent_id = p_agent where id = h.manual_attempt_id;
  return jsonb_build_object('handoff_id', p_handoff, 'agent_id', p_agent,
    'name', (select name from profiles where id = p_agent));
end $$;

revoke execute on function public.record_handoff(bigint, text, text, uuid), public.reassign_handoff(bigint, uuid) from public, anon;
grant execute on function public.record_handoff(bigint, text, text, uuid), public.reassign_handoff(bigint, uuid) to authenticated;
