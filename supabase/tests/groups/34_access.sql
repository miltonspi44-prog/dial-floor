-- 0023: who can read what. Sign-ups are open on this project, so these checks
-- are about a session the floor never issued, and about agents reaching manager
-- data through the API rather than through the app's hidden pages.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '34 · Access: a sign-up arrives switched off and reads nothing; manager data answers managers; the queue still runs on the definer path'
select t.reset() \g /dev/null
-- Other people's work on file: a call that asked for an email, two handoffs (A's
-- with the manager's verdict already written on it), a sync run with a console
-- error in it, a call a manager saved to the library, and a list of A's own.
do $$
declare att bigint; l bigint;
begin
  att := t.dial('A', 'X');
  perform t.log('A', att, 'email_requested', '{"email":"owner@x.test","note":"wants prices"}');
  insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, agent_id, outcome, outcome_note, outcome_by)
    values (t.lead('Y'), '{"name":"Y"}', 'sale_closed', 'signed on the call', t.uid('A'),
            'not_closed', 'owner went quiet and would not sign; do not chase', t.uid('M'));
  insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, agent_id)
    values (t.lead('Z'), '{"name":"Z"}', 'chance_website', 'wants a site', t.uid('B'));
  insert into email_queue (lead_id, email, flagged_by) values (t.lead('Z'), 'owner@z.test', t.uid('B'));
  insert into sync_runs (kind, ok, rows, detail) values ('pull_leads', false, 0, 'connect ECONNREFUSED 10.0.0.9:3306');
  insert into library_items (title, scenario, attempt_id, created_by)
    values ('How A opened the call with X', 'Opening', att, t.uid('M'));
  insert into lists (name, agent_id, status) values ('Access check', t.uid('A'), 'active') returning id into l;
  insert into list_items (list_id, lead_id, position) values (l, t.lead('W'), 1);
end $$;

-- a stranger signs up with the publishable key from the page source
set role supabase_auth_admin;
insert into auth.users (id, email) values ('ffffffff-0000-0000-0000-00000000000f', 'stranger@test');
reset role;
do $$
begin
  assert (select not active and role = 'agent' from profiles where id = 'ffffffff-0000-0000-0000-00000000000f'),
    'the trigger creates the login switched off';
end $$;
set role authenticated;
do $$
begin
  perform set_config('request.jwt.claim.sub', 'ffffffff-0000-0000-0000-00000000000f', false);
  assert (select count(*) from leads) = 0, 'a stranger who signed up reads no leads';
  assert (select count(*) from attempts) = 0, 'no call notes';
  assert (select count(*) from app_settings) = 0, 'none of the floor''s settings';
  assert (select count(*) from agent_status) = 0 and (select count(*) from battlecards) = 0, 'nothing else either';
  -- the floor board is a view, and a view that ran as its owner would hand them
  -- every agent's name and the lead each one is on, policies or no policies
  assert (select count(*) from v_floor_today) = 0, 'and nobody''s line on the floor board';
  assert (select count(*) from profiles) = 1
     and (select id from profiles) = 'ffffffff-0000-0000-0000-00000000000f'::uuid,
    'only their own profile, so the app can still tell them who they are';
  -- a scorecard runs as its owner now, so it has to turn them away itself
  perform t.fails(format('select public.scorecard(%L)', 'ffffffff-0000-0000-0000-00000000000f'), 'not switched on');

  perform t.as_user('A');
  assert (select count(*) from leads) > 0, 'a login a manager switched on reads the floor';
  assert (select count(*) from app_settings) > 0, 'and its settings';
end $$;
reset role;
delete from auth.users where id = 'ffffffff-0000-0000-0000-00000000000f';

-- switching a login off takes the data back, not just at sign-up
update profiles set active = false where id = t.uid('B');
set role authenticated;
do $$
begin
  perform t.as_user('B');
  assert (select count(*) from leads) = 0, 'an agent a manager switched off reads nothing';
end $$;
reset role;
update profiles set active = true where id = t.uid('B');

-- and a manager is no exception: is_manager() asks whether the login is on too
update profiles set active = false where id = t.uid('M');
set role authenticated;
do $$
begin
  perform t.as_user('M');
  assert (select count(*) from leads) = 0, 'a manager whose login was switched off reads nothing either';
  assert (select count(*) from handoff_ledger) = 0, 'not even the manager pages';
end $$;
reset role;
update profiles set active = true where id = t.uid('M');

\echo '  · the manager-only pages'
set role authenticated;
do $$
declare sc jsonb;
begin
  perform t.as_user('A');
  assert (select count(*) from sync_runs) = 0, 'an agent cannot read the sync log';
  assert (select count(*) from handoff_ledger) = 0, 'nor the handoff ledger, not even the deal they closed themselves';
  assert (select count(*) from email_queue) = 1 and (select email from email_queue) = 'owner@x.test',
    'the email queue answers them for the address they typed in themselves, and nothing else';

  -- Their own week still shows them their handoffs: scorecard() runs as its
  -- owner, so the manager-only ledger policy does not apply to it.
  sc := public.scorecard(t.uid('A'));
  assert jsonb_array_length(sc->'handoffs') = 1 and sc->'handoffs'->0->>'summary' = 'signed on the call',
    format('the agent still gets the handoffs they made: %s', sc->'handoffs');
  assert sc->'handoffs'->0->>'outcome' = 'not_closed', 'including whether the deal came off';
  -- but not the manager's own note about it, or who wrote it: the scorecard never
  -- showed those, and now the table will not hand them over either
  assert not (sc->'handoffs'->0 ? 'outcome_note') and not (sc->'handoffs'->0 ? 'outcome_by'),
    format('the manager''s record of the deal stays the manager''s: %s', sc->'handoffs'->0);
  -- the library is the manager's, which was the library's own policy's job until
  -- this function started running as its owner
  assert jsonb_array_length(sc->'saved') = 0, 'and no saved calls: the library is the manager''s';

  perform t.as_user('M');
  assert (select count(*) from handoff_ledger) = 2, 'a manager sees every deal';
  assert (select outcome_note from handoff_ledger where agent_id = t.uid('A')) like '%would not sign%',
    'with their own note on it';
  assert (select count(*) from email_queue) = 2, 'and the whole email queue';
  assert (select detail from sync_runs) like '%ECONNREFUSED%', 'and the sync log with its error text';
  assert jsonb_array_length(public.scorecard(t.uid('A'))->'saved') = 1,
    'and the saved call on the agent''s scorecard, which only they get to see';
  perform t.as_user('B');
  perform t.fails(format('select public.scorecard(%L)', t.uid('A')), 'their own scorecard');
end $$;
reset role;

\echo '  · everything the agent''s own session reads straight from a table'
-- Dial, Floor and Coaching are an agent's whole job, and these are the tables
-- those pages read with the agent's own session rather than through a function.
-- If a later tightening takes one of them away the agent cannot work, so each
-- one is asked here by name.
set role authenticated;
do $$
begin
  perform t.as_user('A');
  assert (select count(*) from profiles where id = t.uid('A')) = 1, 'their own profile: who am I, am I switched on';
  assert (select count(*) from kpi_targets where scope = 'agent_day') = 3, 'the daily targets on the Dial strip';
  assert (select count(*) from battlecards where active) > 0, 'the objection cards beside the lead';
  assert (select count(*) from app_settings where key in ('spam_alert_drop_pts', 'ai_summaries_enabled')) = 2,
    'the two settings the floor board reads';
  assert (select count(*) from attempts) > 0, 'the recent calls on the floor board';
  assert (select count(*) from v_floor_today where agent_id = t.uid('A')) = 1, 'their own line on the floor board';
  assert (select count(*) from profiles where active and id in (t.uid('A'), t.uid('B'), t.uid('M'))) = 3,
    'the Coaching page''s list of who to look at';
  -- empty on a fresh database, so these just have to answer rather than refuse
  perform count(*) from callbacks;
  perform count(*) from v_number_health;
end $$;
reset role;

\echo '  · the floor board''s views read as whoever is asking'
-- A view without security_invoker runs as its owner, and policies do not apply
-- to it: it would hand an agent, or a stranger, rows the read policies above
-- just refused. All three of ours are invoker views; this says so out loud.
do $$
declare v text;
begin
  foreach v in array array['v_floor_today', 'v_number_health', 'v_funnel'] loop
    assert (select 'security_invoker=true' = any(reloptions) from pg_class where oid = ('public.' || v)::regclass),
      format('%s has to be a security_invoker view', v);
  end loop;
end $$;

\echo '  · the policies that name one agent still name only that agent'
-- heartbeat() and the battlecards write these rows for whoever is calling. The
-- policies are what stop a session writing someone else's line on the floor
-- board or renaming somebody else, and wrapping auth.uid() in a sub-select for
-- speed is exactly the kind of edit that could have dropped the condition.
insert into agent_status (agent_id, status) values (t.uid('B'), 'idle')
  on conflict (agent_id) do update set status = 'idle';
set role authenticated;
do $$
declare n int;
begin
  perform t.as_user('A');
  perform t.fails(format('insert into agent_status (agent_id, status) values (%L, ''idle'')', t.uid('B')),
                  'row-level security');
  update agent_status set status = 'on_call' where agent_id = t.uid('B');
  get diagnostics n = row_count;
  assert n = 0, 'nor change the line B already has';
  update profiles set name = 'not mine' where id = t.uid('B');
  get diagnostics n = row_count;
  assert n = 0, 'and a rename stops at their own row';

  insert into agent_status (agent_id, status) values (t.uid('A'), 'idle') on conflict (agent_id) do nothing;
  update agent_status set status = 'on_call' where agent_id = t.uid('A');
  get diagnostics n = row_count;
  assert n = 1, 'their own line they may write';
  update profiles set name = name where id = t.uid('A');
  get diagnostics n = row_count;
  assert n = 1, 'and their own name they may change';
end $$;
reset role;

\echo '  · the foreign-key indexes the joins need'
-- "The migration applied" was the only evidence these existed, which would miss
-- a create index line going astray in a later edit.
do $$
declare missing text;
begin
  select string_agg(i, ', ' order by i) into missing from unnest(array[
    'list_items_lead_idx', 'lead_state_owner_idx', 'callbacks_agent_idx', 'email_queue_lead_idx',
    'handoff_ledger_lead_idx', 'card_taps_card_idx', 'card_taps_agent_idx', 'attempts_list_idx',
    'handoff_ledger_agent_idx', 'email_queue_flagged_idx']) i
   where not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = i);
  assert missing is null, format('0023 is missing these indexes: %s', missing);
end $$;

\echo '  · the queue reads lists as the function''s owner, not as the agent'
-- 0023 leaves lists and list_items readable by any switched-on login. Narrowing
-- them to the agent's own lists would break group 23, where an agent deliberately
-- reads another agent's radar list, and that file is not this migration's to
-- change. So this block is not a guard on a shipped policy: it is the proof that
-- next_lead() never reads lists as the agent, so whoever does narrow them later
-- will not stop the queue by doing it. It puts both policies back exactly as it
-- found them, and then checks that it did — so whoever narrows the policy has to
-- change the two restores below to match, and the check is what will tell them.
select set_config('t.lists_read',
  (select string_agg(polname || ' = ' || pg_get_expr(polqual, polrelid), '; ' order by polname) from pg_policy
    where polrelid in ('public.lists'::regclass, 'public.list_items'::regclass) and polcmd = 'r'), false) \g /dev/null
drop policy lists_read on public.lists;
create policy lists_read on public.lists for select to authenticated using (public.is_manager());
drop policy list_items_read on public.list_items;
create policy list_items_read on public.list_items for select to authenticated using (public.is_manager());
set role authenticated;
do $$
declare n jsonb;
begin
  perform t.as_user('A');
  assert (select count(*) from lists) = 0 and (select count(*) from list_items) = 0,
    'the agent cannot read the lists table at all';
  n := public.next_lead();
  assert t.name(n) = 'W' and n->>'reason' = 'list',
    format('next_lead still serves them their list lead: %s', n);
end $$;
reset role;
drop policy lists_read on public.lists;
create policy lists_read on public.lists for select to authenticated using (public.is_active());
drop policy list_items_read on public.list_items;
create policy list_items_read on public.list_items for select to authenticated using (public.is_active());
do $$
begin
  assert current_setting('t.lists_read') =
    (select string_agg(polname || ' = ' || pg_get_expr(polqual, polrelid), '; ' order by polname) from pg_policy
      where polrelid in ('public.lists'::regclass, 'public.list_items'::regclass) and polcmd = 'r'),
    'both policies are back exactly as 0023 leaves them, so the groups after this one see what they expect';
end $$;

\echo '  · the helpers that were open to anyone'
set role anon;
do $$
begin
  perform t.fails('select public.setting(''call_window'')', 'permission denied');
  perform t.fails('select public.norm_phone(''(305) 555-0001'')', 'permission denied');
  perform t.fails('select public.derive_tz(''3055550001'', ''FL'')', 'permission denied');
  perform t.fails('select public.local_ok(''America/New_York'')', 'permission denied');
  perform t.fails('select public.business_tz()', 'permission denied');
  perform t.fails('select public.business_date()', 'permission denied');
  perform t.fails('select public.business_day_start()', 'permission denied');
  perform t.fails('select public.is_active()', 'permission denied');
end $$;
reset role;
select t.reset() \g /dev/null
delete from sync_runs;
delete from library_items;
\echo 'access tests passed'
