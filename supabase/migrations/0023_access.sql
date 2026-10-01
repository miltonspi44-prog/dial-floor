-- Dial Floor · 0023 access
--   Who is allowed to read what. Sign-ups are open on this project's Supabase
--   Auth and the publishable key sits in the public site's page source, so
--   anyone at all could get a signed-in session. Every data table answered a
--   signed-in session with "here is everything": all 2,445 businesses, their
--   phone numbers and every call note. Two changes close that: a new login
--   arrives switched off until a manager turns it on, and reading now asks
--   "is this login switched on?" instead of "is this anybody?".
--   The manager-only pages' tables go further and only answer managers, which
--   for the handoff ledger means moving scorecard() onto the definer path so an
--   agent's own week still reaches them.

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

-- The ledger is the manager's as well. A weekly scorecard does show an agent the
-- handoffs they made, so it is tempting to let an agent read their own rows —
-- but the row carries more than the scorecard shows: outcome, outcome_note and
-- outcome_by are the manager's own record of whether the deal actually came off
-- and who decided that, and an agent reading the table directly got all three.
-- So the table answers managers, and the scorecard reaches it another way.
drop policy if exists handoff_ledger_read on public.handoff_ledger;
create policy handoff_ledger_read on public.handoff_ledger
  for select to authenticated using (public.is_manager());

-- Which means scorecard() has to stop reading the ledger as the agent. This is
-- 0020's function with three changes and nothing else: it runs as its owner, and
-- the two rules row-level security used to enforce on its behalf are now written
-- into the body, where the next person reading it can see them.
create or replace function public.scorecard(p_agent uuid, p_weeks int default 4)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_weeks int := greatest(1, least(coalesce(p_weeks, 4), 12));
  v_tz text := public.business_tz();
  v_this date := date_trunc('week', public.business_date()::timestamp)::date;
  v_from timestamptz := (v_this - 7 * (v_weeks - 1))::timestamp at time zone v_tz;
  v_week timestamptz := v_this::timestamp at time zone v_tz;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  -- Row-level security used to be what kept a login nobody has switched on from
  -- seeing the floor's numbers here. This function now runs as its owner, so
  -- policies no longer apply to it and the question has to be asked out loud.
  if not public.is_active() then raise exception 'your login is not switched on yet'; end if;
  if p_agent is distinct from auth.uid() and not is_manager() then
    raise exception 'agents see their own scorecard';
  end if;

  with a as (
    select x.*, date_trunc('week', x.clicked_at at time zone v_tz)::date as wk,
           public.is_conversation(x.connected, x.disposition) as convo
      from attempts x where x.clicked_at >= v_from
  ),
  per as (  -- each agent's week
    select a.agent_id, a.wk,
           count(*) as dials,
           count(distinct (a.clicked_at at time zone v_tz)::date) as days,
           count(*) filter (where a.call_result = 'answered' or coalesce(a.connected, false)) as picked_up,
           count(*) filter (where a.convo) as conversations,
           count(*) filter (where a.convo and public.kept_alive(a.disposition)) as kept,
           count(*) filter (where a.disposition in ('chance_website', 'sale_closed')) as won,
           coalesce(sum(a.duration_seconds) filter (where a.call_result = 'answered'), 0) as talk_seconds,
           count(*) filter (where a.disposition = 'callback') as callbacks_set
      from a group by a.agent_id, a.wk
  ),
  cb as (  -- promised callbacks that came due that week: kept or missed
    select c.agent_id, date_trunc('week', c.due_at at time zone v_tz)::date as wk,
           count(*) filter (where c.status = 'done') as done, count(*) filter (where c.status = 'missed') as missed
      from callbacks c
     where c.due_at >= v_from and c.due_at < now() and c.status in ('done', 'missed')
     group by 1, 2
  ),
  weeks as (select (v_this - 7 * g)::date as wk from generate_series(0, v_weeks - 1) g)
  select jsonb_build_object(
    'agent', (select jsonb_build_object('id', p.id, 'name', p.name) from profiles p where p.id = p_agent),
    'this_week', v_this,
    'weeks', (select jsonb_agg(jsonb_build_object(
        'week', w.wk,
        'me', jsonb_build_object(
           'dials', coalesce(m.dials, 0), 'days', coalesce(m.days, 0), 'picked_up', coalesce(m.picked_up, 0),
           'conversations', coalesce(m.conversations, 0), 'kept', coalesce(m.kept, 0), 'won', coalesce(m.won, 0),
           'talk_seconds', coalesce(m.talk_seconds, 0), 'callbacks_set', coalesce(m.callbacks_set, 0),
           'cb_done', coalesce(mc.done, 0), 'cb_missed', coalesce(mc.missed, 0)),
        -- the floor's totals and headcount: averages and pooled rates are taken from these
        'floor', (select jsonb_build_object(
           'agents', count(*), 'dials', coalesce(sum(f.dials), 0), 'days', coalesce(sum(f.days), 0),
           'picked_up', coalesce(sum(f.picked_up), 0), 'conversations', coalesce(sum(f.conversations), 0),
           'kept', coalesce(sum(f.kept), 0), 'won', coalesce(sum(f.won), 0),
           'talk_seconds', coalesce(sum(f.talk_seconds), 0), 'callbacks_set', coalesce(sum(f.callbacks_set), 0),
           'cb_done', (select coalesce(sum(done), 0) from cb where cb.wk = w.wk),
           'cb_missed', (select coalesce(sum(missed), 0) from cb where cb.wk = w.wk))
           from per f where f.wk = w.wk))
        order by w.wk)
      from weeks w
      left join per m on m.wk = w.wk and m.agent_id = p_agent
      left join cb mc on mc.wk = w.wk and mc.agent_id = p_agent),
    'handoffs', (select coalesce(jsonb_agg(jsonb_build_object(
                    'at', h.handed_at, 'lead', h.lead_snapshot->>'name', 'kind', h.kind, 'summary', h.summary,
                    'rating', h.rating, 'outcome', h.outcome) order by h.handed_at), '[]'::jsonb)
                   from handoff_ledger h where h.agent_id = p_agent and h.handed_at >= v_week),
    'review', (select coalesce(jsonb_agg(jsonb_build_object(
                  'attempt_id', x.id, 'at', x.clicked_at, 'lead', l.name, 'disposition', x.disposition,
                  'duration', x.duration_seconds, 'note', x.note,
                  'objections', (select coalesce(jsonb_agg(distinct b.objection), '[]'::jsonb)
                                   from card_taps t join battlecards b on b.id = t.card_id where t.attempt_id = x.id))
                  order by x.duration_seconds desc), '[]'::jsonb)
                 from (select * from attempts y
                        where y.agent_id = p_agent and y.clicked_at >= v_week
                          and public.is_conversation(y.connected, y.disposition) and not public.kept_alive(y.disposition)
                          and y.duration_seconds >= 120
                        order by y.duration_seconds desc limit 3) x
                 join leads l on l.id = x.lead_id),
    -- Saved calls are the manager's, like the Playbook page they live on. The
    -- library's own manager-only policy used to be what kept agents out of this
    -- list; running as the owner skips that policy, so the rule is written here.
    'saved', (select coalesce(jsonb_agg(jsonb_build_object('id', li.id, 'title', li.title, 'scenario', li.scenario,
                                                           'at', li.created_at) order by li.created_at), '[]'::jsonb)
                from library_items li join attempts y on y.id = li.attempt_id
               where y.agent_id = p_agent and y.clicked_at >= v_week and public.is_manager()))
    into r;
  return r;
end $$;

-- The email queue does keep a narrow door open for the agent's own row: the
-- agent who asked for an email typed that address in themselves, so it is no
-- secret from them. The queue as a whole, with every customer's address on it,
-- is the manager's.
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

-- And two the first pass missed, both on a column something above filters by on
-- every single read: the email queue's own policy tests flagged_by, and every
-- scorecard anyone opens looks that agent's handoffs up by agent_id.
create index if not exists handoff_ledger_agent_idx on public.handoff_ledger (agent_id);
create index if not exists email_queue_flagged_idx on public.email_queue (flagged_by);
