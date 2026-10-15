-- Dial Floor · 0042 a chance given off the phone, recorded by hand
-- A business that was dialed and later calls back to give a chance (or buy)
-- has no call in progress to log the outcome on. record_handoff() is that
-- outcome without a dial: the same handoff row, the same hold on the number
-- for every record carrying it, the same word to the console, and the lead
-- leaves every list and queue. Managers only, from the Lists page.
-- Applies through the management API as it is.
create or replace function public.record_handoff(p_lead_id bigint, p_kind text, p_summary text default null, p_agent uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l leads%rowtype;
  v_state text;
  v_agent uuid;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_kind not in ('chance_website', 'sale_closed') then raise exception 'the kind is chance_website or sale_closed'; end if;
  select * into l from leads where id = p_lead_id;
  if not found then raise exception 'lead not found'; end if;
  select state into v_state from lead_state where lead_id = p_lead_id;
  if v_state = 'handoff' then raise exception 'this lead is already handed off'; end if;
  -- credited to the agent named (the list's agent, usually), else to the manager
  v_agent := coalesce(p_agent, auth.uid());
  if not exists (select 1 from profiles where id = v_agent) then raise exception 'that login does not exist'; end if;
  v_note := coalesce(nullif(trim(p_summary), ''),
                     case p_kind when 'chance_website' then 'called back - gave upfront - website' else 'called back - sale closed' end);

  insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
    values (l.id, to_jsonb(l), p_kind, v_note, null, v_agent);
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
    'handoff_id', (select max(id) from handoff_ledger where lead_id = l.id));
end $$;
revoke execute on function public.record_handoff(bigint, text, text, uuid) from public, anon;
grant execute on function public.record_handoff(bigint, text, text, uuid) to authenticated;
