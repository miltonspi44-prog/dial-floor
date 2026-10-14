-- Dial Floor · 0025 write-back failures
--   The sync worker pushes each lead's terminal status to the console (do-not-call,
--   wrong number, sold, not interested…) and marks writeback_done once the console
--   has it. Until now a row the console will never accept — a note the console's
--   older text column cannot store, a lead deleted there — was retried every minute
--   forever, and nothing recorded why. These two columns let the worker stop trying
--   and leave the reason where a manager can see it.
--
--   Keeping them truthful is the trigger's job rather than every writer's: a status
--   is "new" the moment writeback_done goes back to false, whoever set it, so the
--   old failure is cleared there instead of in each disposition path.

alter table public.lead_state
  add column if not exists writeback_failed_at timestamptz,
  add column if not exists writeback_error text;

create or replace function public.lead_state_clear_writeback_error()
returns trigger language plpgsql set search_path = public as $$
begin
  new.writeback_failed_at := null;
  new.writeback_error := null;
  return new;
end $$;

-- Two things count as a fresh promise: a finished write-back becoming pending again,
-- and a different status being promised while one is still waiting. Both mean the
-- recorded failure describes something we are no longer trying to send.
-- The WHEN clause keeps this off the hot path — lead_state is written on every dial,
-- and an ordinary update touches neither column.
drop trigger if exists lead_state_writeback_reset on public.lead_state;
create trigger lead_state_writeback_reset
  before update on public.lead_state
  for each row
  when (not new.writeback_done
        and (old.writeback_done or new.writeback_status is distinct from old.writeback_status))
  execute function public.lead_state_clear_writeback_error();

-- The worker reaches this table with the service role, which bypasses RLS; managers
-- read it through the existing lead_state read policy. Nothing new is granted.
revoke execute on function public.lead_state_clear_writeback_error() from public, anon, authenticated;
