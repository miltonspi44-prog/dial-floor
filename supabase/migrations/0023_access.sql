-- Dial Floor · 0023 access
--   Who is allowed to read what. Sign-ups are open on this project's Supabase
--   Auth and the publishable key sits in the public site's page source, so
--   anyone at all could get a signed-in session. Every data table answered a
--   signed-in session with "here is everything": all 2,445 businesses, their
--   phone numbers and every call note. Two changes close that: a new login
--   arrives switched off until a manager turns it on, and reading now asks
--   "is this login switched on?" instead of "is this anybody?".
--   The manager-only pages' tables go further and only answer managers.

-- ----------------------------------------------------------- a new signup --
-- A stranger who signs up is nobody until a manager says otherwise, so the
-- profile the trigger writes starts switched off. The Users tab switches a
-- login on explicitly when a manager adds someone, and that is the only way in.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, active)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)), false)
  on conflict (id) do nothing;
  return new;
end $$;

-- Every read policy below hangs off this one question, so a login nobody has
-- switched on sees nothing at all. It is security definer like is_manager(),
-- which is what lets it look at profiles without needing a policy there.
create or replace function public.is_active()
returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and active) $$;

-- ------------------------------------------------------------ what agents read --
-- The floor's working data: readable by a login that is switched on, not by
-- anyone who merely holds a session. The manager-only write policies that sit
-- on some of these tables are untouched.
do $$
declare t text;
begin
  foreach t in array array[
    'leads','lead_state','attempts','callbacks','suppression','lists','list_items',
    'intents_catalog','lead_intents','number_stats','email_templates','battlecards','card_taps',
    'agent_status','agent_breaks','app_settings','kpi_targets','radar_items','sprints','call_votes',
    'referrals','best_time_cells','area_code_tz','state_tz','ab_tests']
  loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_active())',
                   t || '_read', t);
  end loop;
end $$;

-- profiles is the exception: the app reads its own row the moment someone signs
-- in, to find out who they are and whether they are switched on. If that read
-- needed an active profile, a login waiting to be turned on could not even be
-- told it is waiting. So: your own row always, everyone else's once you are on.
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select to authenticated using (id = (select auth.uid()) or public.is_active());

-- --------------------------------------------------- the manager-only pages --
-- Handoffs, the email queue and the sync log are manager pages in the app, but
-- the database was handing them to any signed-in agent: every won deal and what
-- was said, customers' email addresses, and the sync log, whose detail column
-- carries raw error text from the console. Managers only now.
--   The queue is not affected by any of this: next_lead() and build_workspace()
-- reach lists and list_items as SECURITY DEFINER, so they read as the function's
-- owner and policies do not apply to them. Test 34 proves that still holds.
drop policy if exists sync_runs_read on public.sync_runs;
create policy sync_runs_read on public.sync_runs
  for select to authenticated using (public.is_manager());

-- Two of these keep a narrow door open for the agent's own rows, because the
-- agent-facing app really does read them. A weekly scorecard shows an agent the
-- handoffs they made, and scorecard() runs as the caller, so the ledger has to
-- answer an agent about their own deals — just not about anyone else's.
drop policy if exists handoff_ledger_read on public.handoff_ledger;
create policy handoff_ledger_read on public.handoff_ledger
  for select to authenticated using (public.is_manager() or agent_id = (select auth.uid()));

-- Same shape for the email queue: the agent who asked for an email typed that
-- address in themselves, so their own row is no secret from them. The queue as
-- a whole, with every customer's address on it, is the manager's.
drop policy if exists email_queue_read on public.email_queue;
create policy email_queue_read on public.email_queue
  for select to authenticated using (public.is_manager() or flagged_by = (select auth.uid()));

-- ---------------------------------------------------- one auth.uid() a query --
-- These four policies called auth.uid() again for every row they looked at.
-- Wrapped in a sub-select, Postgres works it out once and reuses the answer.
-- Nothing about who may do what changes here.
drop policy if exists agent_status_upsert on public.agent_status;
create policy agent_status_upsert on public.agent_status
  for insert to authenticated with check (agent_id = (select auth.uid()));
drop policy if exists agent_status_update on public.agent_status;
create policy agent_status_update on public.agent_status
  for update to authenticated using (agent_id = (select auth.uid()));
drop policy if exists card_taps_insert on public.card_taps;
create policy card_taps_insert on public.card_taps
  for insert to authenticated with check (agent_id = (select auth.uid()));
drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles
  for update to authenticated using (id = (select auth.uid()));

-- ------------------------------------------------------------ API surface --
-- Supabase grants EXECUTE on every new function to anon, and these seven were
-- left that way. They hand out the floor's settings and timezone rules rather
-- than anything secret, but nothing needs them without a login.
revoke execute on function public.norm_phone(text) from public, anon;
revoke execute on function public.derive_tz(text, text) from public, anon;
revoke execute on function public.setting(text) from public, anon;
revoke execute on function public.local_ok(text) from public, anon;
revoke execute on function public.business_tz() from public, anon;
revoke execute on function public.business_date() from public, anon;
revoke execute on function public.business_day_start() from public, anon;
revoke execute on function public.is_active() from public, anon;
grant execute on function
  public.norm_phone(text), public.derive_tz(text, text), public.setting(text), public.local_ok(text),
  public.business_tz(), public.business_date(), public.business_day_start(), public.is_active()
  to authenticated, service_role;

-- ------------------------------------------------------ foreign-key indexes --
-- Every one of these columns points at another table and had no index, so
-- Postgres read the whole table to follow it. With four to fifteen agents
-- dialing these are the joins that run on every served lead, every disposition
-- and every page of the manager's tabs.
create index if not exists list_items_lead_idx on public.list_items (lead_id);
create index if not exists lead_state_owner_idx on public.lead_state (owner_agent);
create index if not exists callbacks_agent_idx on public.callbacks (agent_id);
create index if not exists email_queue_lead_idx on public.email_queue (lead_id);
create index if not exists handoff_ledger_lead_idx on public.handoff_ledger (lead_id);
create index if not exists card_taps_card_idx on public.card_taps (card_id);
create index if not exists card_taps_agent_idx on public.card_taps (agent_id);
create index if not exists attempts_list_idx on public.attempts (list_id);
