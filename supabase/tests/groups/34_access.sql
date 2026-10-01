-- 0023: who can read what. Sign-ups are open on this project, so these checks
-- are about a session the floor never issued, and about agents reaching manager
-- data through the API rather than through the app's hidden pages.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '34 · Access: a sign-up arrives switched off and reads nothing; manager data answers managers; the queue still runs on the definer path'
select t.reset() \g /dev/null
-- Other people's work on file: a call that asked for an email, two handoffs, a
-- sync run with a console error in it, and a list of A's own.
do $$
declare att bigint; l bigint;
begin
  att := t.dial('A', 'X');
  perform t.log('A', att, 'email_requested', '{"email":"owner@x.test","note":"wants prices"}');
  insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, agent_id)
    values (t.lead('Y'), '{"name":"Y"}', 'sale_closed', 'signed on the call', t.uid('A'));
  insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, agent_id)
    values (t.lead('Z'), '{"name":"Z"}', 'chance_website', 'wants a site', t.uid('B'));
  insert into email_queue (lead_id, email, flagged_by) values (t.lead('Z'), 'owner@z.test', t.uid('B'));
  insert into sync_runs (kind, ok, rows, detail) values ('pull_leads', false, 0, 'connect ECONNREFUSED 10.0.0.9:3306');
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
  assert (select count(*) from profiles) = 1
     and (select id from profiles) = 'ffffffff-0000-0000-0000-00000000000f'::uuid,
    'only their own profile, so the app can still tell them who they are';

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

\echo '  · the manager-only pages'
set role authenticated;
do $$
begin
  perform t.as_user('A');
  assert (select count(*) from sync_runs) = 0, 'an agent cannot read the sync log';
  assert (select count(*) from handoff_ledger) = 1
     and (select summary from handoff_ledger) = 'signed on the call',
    'an agent sees their own handoff (their scorecard shows it) and nobody else''s';
  assert (select count(*) from email_queue) = 1 and (select email from email_queue) = 'owner@x.test',
    'and only the email they asked for themselves';

  perform t.as_user('M');
  assert (select count(*) from handoff_ledger) = 2, 'a manager sees every deal';
  assert (select count(*) from email_queue) = 2, 'and the whole email queue';
  assert (select detail from sync_runs) like '%ECONNREFUSED%', 'and the sync log with its error text';
end $$;
reset role;

\echo '  · the queue reads lists as the function''s owner, not as the agent'
-- The item that restricts the lists wants proof that next_lead() is unaffected
-- by their read policy. Make them manager-read for the length of this check and
-- then put them back exactly as 0023 leaves them.
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
\echo 'access tests passed'
