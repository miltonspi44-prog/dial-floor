-- Dial Floor · 0026 what counts as history, and finding a call by its Zoom id
--
--   Two loose ends from the Wave 1 review, both of which only bite later.

-- ----------------------------------------------------------- member_history --
--   This decides whether removing someone deletes their login outright or keeps
--   it blocked with their history intact. It counted nine things and missed four
--   tables added since, two of which delete with the row: an agent whose only
--   trace was a break or a vote for someone's call of the day read as "nothing on
--   file", and deleting them took those rows with it. Pacing would quietly lose a
--   day's breaks, and a vote would vanish from the board that counted it.
--
--   Everything referencing a person belongs here, so the rule stays "anything at
--   all means keep". sprints.created_by and referrals.agent_id survive a delete
--   (they null out), but a power hour with no one who started it, and a referral
--   with no one who took it, are still history worth keeping someone for.
create or replace function public.member_history(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'attempts',  (select count(*) from attempts where agent_id = p_id),
    'callbacks', (select count(*) from callbacks where agent_id = p_id or requeued_by = p_id),
    'lists',     (select count(*) from lists where agent_id = p_id or created_by = p_id),
    'handoffs',  (select count(*) from handoff_ledger where agent_id = p_id or outcome_by = p_id),
    'emails',    (select count(*) from email_queue where flagged_by = p_id or sent_by = p_id),
    'taps',      (select count(*) from card_taps where agent_id = p_id),
    'radar',     (select count(*) from radar_items where agent_id = p_id),
    'library',   (select count(*) from library_items where created_by = p_id),
    'leads',     (select count(*) from lead_state where owner_agent = p_id),
    'breaks',    (select count(*) from agent_breaks where agent_id = p_id),
    'votes',     (select count(*) from call_votes where voter = p_id),
    'sprints',   (select count(*) from sprints where created_by = p_id),
    'referrals', (select count(*) from referrals where agent_id = p_id))
$$;

-- ------------------------------------------------------------ attempts index --
--   The Zoom webhook looks a dial up by the call id twice per delivery, to tell a
--   repeat delivery of a call it already has from a new one. Nothing indexed that
--   column, so each lookup read the whole table: measured at 200,000 attempts it
--   takes 17 ms against 0.05 ms with this index, and it only grows. Partial,
--   because a dial with no call id yet is never searched for this way.
create index if not exists attempts_zoom_call_idx
  on public.attempts (zoom_call_id) where zoom_call_id is not null;
