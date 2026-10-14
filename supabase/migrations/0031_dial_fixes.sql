-- Dial Floor · 0031 the Dial page stops costing keystrokes
-- The database half of the focus list's agent-speed tier (items 26, 30, 32),
-- reproduced in supabase/tests/groups/42_dial.sql. The page half ships with the
-- same build: auto-advance off Zoom's result, callback quick-picks, a "when are
-- they back" ask, honest statuses on reload and sign-out.

-- 26: the page listens for the webhook's write on its own attempt, so the queue
-- table has to be in the realtime publication. Guarded, because the local test
-- stub has no realtime publication at all.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime'
                        and schemaname = 'public' and tablename = 'attempts') then
    alter publication supabase_realtime add table public.attempts;
  end if;
end $$;

-- 32: the page now says what is actually happening — "dialing" again after a
-- mid-call reload (so the idle nudge doesn't fire on somebody mid-conversation),
-- "offline" on sign-out. The floor board already knows both words; heartbeat
-- just refused to say them. The lead fields on the tile are left as they were:
-- a status-only ping must not blank the lead a reload is resuming.
create or replace function public.heartbeat(p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  -- 'ping' only says "still here": the tile keeps its status and stays off the stale list
  if p_status = 'ping' then
    update agent_status set updated_at = now() where agent_id = auth.uid();
    return;
  end if;
  if p_status not in ('idle','wrap','break','offline','dialing','on_call') then
    raise exception 'bad status';
  end if;
  insert into agent_status (agent_id, status, since, updated_at)
  values (auth.uid(), p_status, now(), now())
  on conflict (agent_id) do update set status = excluded.status, since = now(), updated_at = now();
end $$;

-- 30: "language barrier" flags the lead for list filtering instead of only
-- resting it. The flag is an intent, so the list builder's intent rule, the
-- workspace tags and the funnel's by-intent all see it with no new machinery.
-- Source 'manual' because refresh_lead rewrites the 'auto' rows from lead
-- columns, and no lead column says what happened on a call.
insert into public.intents_catalog (key, label, description, priority) values
  ('language_barrier', 'Language barrier', 'A call ended because there was no shared language', 95)
on conflict (key) do nothing;

create or replace function public.flag_language_barrier()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into lead_intents (lead_id, intent_key, confidence, source)
  values (new.lead_id, 'language_barrier', 1.0, 'manual')
  on conflict (lead_id, intent_key) do nothing;
  return new;
end $$;

create trigger attempts_language_flag
  after insert or update of disposition on public.attempts
  for each row when (new.disposition = 'language_barrier')
  execute function public.flag_language_barrier();

revoke execute on function public.flag_language_barrier() from public, anon, authenticated;
