-- Dial Floor · 0053 the handoffs recorded by hand before 0052 count too
-- Every handoff recorded by hand before 0052 has a ledger row and no call, so it
-- never reached its agent's numbers. Each gets the call 0052 now logs, on the
-- day it was recorded and for the agent it is credited to, so it counts in their
-- stats from that day; a manager can give any of them to someone else from the
-- Handoffs page (reassign_handoff). A handoff logged from a dial already has its
-- call and is left alone, and running this again finds nothing to do.
-- Applies through the management API as it is.

do $$
declare h record; v_attempt bigint;
begin
  for h in
    select * from handoff_ledger x
     where x.manual_attempt_id is null
       and not exists (select 1 from attempts w where w.lead_id = x.lead_id and w.disposition in ('chance_website', 'sale_closed'))
     order by x.id
  loop
    insert into attempts (lead_id, agent_id, clicked_at, disposed_at, connected, disposition, note, call_result, source, matched)
      values (h.lead_id, h.agent_id, h.handed_at, h.handed_at, true, h.kind, h.summary,
              'Called back: handoff recorded by hand', 'callback', true)
      returning id into v_attempt;
    update handoff_ledger set manual_attempt_id = v_attempt where id = h.id;
  end loop;
end $$;
