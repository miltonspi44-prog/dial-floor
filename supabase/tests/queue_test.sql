-- Queue-engine tests. Each block pins down a bug found in the Phase 0 build.
-- Run by run.sh against a fresh database with the stub and every migration applied.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

-- ---------------------------------------------------------------- fixtures --
update app_settings set value = '{"start":"00:00","end":"23:59:59"}' where key = 'call_window'; -- time of day out of the way
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'agent.a@test'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'agent.b@test'),
  ('cccccccc-0000-0000-0000-00000000000c', 'manager@test');
update profiles set role = 'manager' where id = 'cccccccc-0000-0000-0000-00000000000c';
insert into leads (source_id, name, phone_norm, phone_display, addr_state, score, review_count) values
  (1, 'X',  '3055550001', '(305) 555-0001', 'FL', 95, 50),
  (2, 'Y',  '3055550002', '(305) 555-0002', 'FL', 90, 40),
  (3, 'Z',  '3055550003', '(305) 555-0003', 'FL', 85, 30),
  (4, 'W',  '3055550004', '(305) 555-0004', 'FL', 80, 20),
  (5, 'D1', '3055550099', '(305) 555-0099', 'FL', 10, 1),  -- one business scraped twice:
  (6, 'D2', '3055550099', '(305) 555-0099', 'FL',  9, 1);  -- same number, two lead records
do $$ begin perform refresh_lead(id) from leads; end $$;

create schema t;
grant usage on schema t to public;
create function t.uid(p text) returns uuid language sql immutable as $$
  select case p when 'A' then 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid
                when 'B' then 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid
                when 'M' then 'cccccccc-0000-0000-0000-00000000000c'::uuid end $$;
-- act as a signed-in user (auth.uid() reads this claim); null = nobody
create function t.as_user(p text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(t.uid(p)::text, ''), false) $$;
create function t.lead(p text) returns bigint language sql stable as $$ select id from public.leads where name = p $$;
create function t.name(w jsonb) returns text language sql immutable as $$ select w->'lead'->>'name' $$;
create function t.next(p text) returns jsonb language plpgsql as $$
begin perform t.as_user(p); return public.next_lead(); end $$;
create function t.dial(p text, lead text) returns bigint language plpgsql as $$
begin perform t.as_user(p); return (public.start_attempt(t.lead(lead))->>'attempt_id')::bigint; end $$;
create function t.log(p text, att bigint, dispo text, args jsonb default '{}') returns jsonb language plpgsql as $$
begin perform t.as_user(p); return public.log_disposition(att, dispo, args); end $$;
create function t.skip(p text, lead text) returns jsonb language plpgsql as $$
begin perform t.as_user(p); return public.skip_lead(t.lead(lead)); end $$;
-- the statement must fail with an error containing expect
create function t.fails(stmt text, expect text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if sqlerrm like '%' || expect || '%' then return; end if;
    raise exception 'expected "%" from [%], got "%"', expect, stmt, sqlerrm;
  end;
  raise exception 'expected "%" from [%], but it succeeded', expect, stmt;
end $$;
create function t.reset() returns void language plpgsql as $$
begin
  truncate attempts, callbacks, suppression, lists, list_items, handoff_ledger, email_queue,
           agent_status, card_taps, number_stats restart identity cascade;
  update lead_state set state = 'queued', owner_agent = null, rest_until = null, attempts_total = 0,
    attempts_today = 0, attempts_today_date = null, connects_total = 0, last_attempt_at = null,
    in_progress_since = null, reserved_by = null, reserved_until = null,
    writeback_status = null, writeback_note = null, writeback_done = true;
end $$;

\echo '1 · Skip moves on (it used to reload the same lead)'
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  assert t.name(t.next('A')) = 'X', 'A starts on the top lead';
  n := t.skip('A', 'X');
  assert t.name(n->'next') = 'Y', format('skip should move on, got %s', t.name(n->'next'));
  assert (select rest_until > now() and reserved_by is null from lead_state where lead_id = t.lead('X')),
    'the skipped lead sits out, unreserved';
end $$;

\echo '2 · Two agents are never served, or able to dial, the same lead'
select t.reset() \g /dev/null
do $$
begin
  assert t.name(t.next('A')) = 'X';
  assert t.name(t.next('B')) = 'Y', 'B must not be served the lead A has open';
  perform t.as_user('B');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'another agent has this lead open');
  perform t.dial('A', 'X');
  perform t.as_user('B');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'already dialing');
  assert (select count(*) from attempts where lead_id = t.lead('X')) = 1, 'one attempt, one agent';
end $$;
select t.reset() \g /dev/null
do $$
begin
  assert t.name(t.next('A')) = 'X';
  update lead_state set reserved_until = now() - interval '1 minute' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X', 'a lapsed reservation frees the lead';
end $$;

\echo '3 · No answer does not serve the same business straight back'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  perform t.next('A');
  att := t.dial('A', 'X');
  n := t.log('A', att, 'no_answer');
  assert t.name(n->'next') = 'Y', format('expected Y after no answer, got %s', t.name(n->'next'));
  update lead_state set last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  assert t.name(t.next('B')) = 'X', 'eligible again once the gap has passed';
end $$;

\echo '4 · Callbacks: lead-local time, retried when unanswered, then finished (they used to loop forever)'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb; v_day date := (now() at time zone 'America/New_York')::date + 3;
begin
  perform t.next('A');
  att := t.dial('A', 'X');
  n := t.log('A', att, 'callback', jsonb_build_object('due_local', to_char(v_day, 'YYYY-MM-DD') || 'T10:00'));
  assert (select due_at from callbacks) = (v_day + time '10:00') at time zone 'America/New_York',
    format('10:00 on the lead''s clock expected, got %s', (select due_at from callbacks));
  assert t.name(n->'next') <> 'X', 'not due yet';
end $$;
update callbacks set due_at = now() - interval '1 minute';  -- the day arrives
do $$
declare att bigint; n jsonb;
begin
  for i in 1..3 loop
    n := t.next('A');
    assert n->>'reason' = 'callback_due' and t.name(n) = 'X', format('try %s: the callback is served', i);
    att := t.dial('A', 'X');
    n := t.log('A', att, 'no_answer');
    assert t.name(n->'next') is distinct from 'X', format('try %s: must not loop straight back', i);
    if i < 3 then
      assert (select status = 'scheduled' and tries = i and due_at > now() from callbacks), format('try %s: rescheduled', i);
      assert (select state = 'callback_locked' from lead_state where lead_id = t.lead('X')), 'still locked to the agent';
      update callbacks set due_at = now() - interval '1 minute';
    end if;
  end loop;
  assert (select status = 'missed' and tries = 3 from callbacks), 'the third miss closes the callback';
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')), 'back in the queue';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  att := t.dial('A', 'X');
  n := t.log('A', att, 'callback', jsonb_build_object('due_at', now() - interval '1 minute'));
  assert n->'next'->>'reason' = 'callback_due';
  att := t.dial('A', 'X');
  n := t.log('A', att, 'not_interested_soft');
  assert (select status from callbacks) = 'done', 'a callback that connects is done';
  assert t.name(n->'next') <> 'X', 'and does not come back';
  assert (select state from lead_state where lead_id = t.lead('X')) = 'resting';
end $$;

\echo '5 · A handoff keeps state handoff (it was overwritten to suppressed)'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  att := t.dial('A', 'X');
  perform t.log('A', att, 'chance_website', '{"summary":"wants a site","rating":5}');
  assert (select state from lead_state where lead_id = t.lead('X')) = 'handoff';
  assert (select count(*) from handoff_ledger) = 1;
end $$;

\echo '6 · Do-not-call covers every lead record with that number'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  att := t.dial('A', 'D1');
  perform t.log('A', att, 'dnc');
  assert (select state from lead_state where lead_id = t.lead('D2')) = 'suppressed', 'the duplicate record is suppressed too';
  perform t.as_user('B');
  perform t.fails(format('select public.start_attempt(%s)', t.lead('D2')), 'can no longer be dialed');
  update lead_state set state = 'queued' where lead_id = t.lead('D2');  -- even with a stale state row...
  perform t.fails(format('select public.start_attempt(%s)', t.lead('D2')), 'do-not-call');
  update leads set score = 100 where name = 'D2';
  assert t.name(t.next('B')) <> 'D2', '...the number is never served';
  update leads set score = 9 where name = 'D2';
end $$;

\echo '7 · The pool leaves other agents'' list leads alone; unassigned lists are shared'
select t.reset() \g /dev/null
do $$
declare n jsonb;
begin
  perform t.as_user('M');
  perform build_list('A''s list', t.uid('A'), '{}', 2);   -- X, Y
  perform build_list('shared', null, '{}', 1);            -- Z
  n := t.next('B');
  assert n->>'reason' = 'list' and t.name(n) = 'Z', format('B works the shared list, got %s/%s', n->>'reason', t.name(n));
  n := t.skip('B', 'Z');
  assert t.name(n->'next') = 'W', format('then the pool, past A''s list leads; got %s', t.name(n->'next'));
  n := t.next('A');
  assert n->>'reason' = 'list' and t.name(n) = 'X', 'A''s list is still A''s';
end $$;

\echo '8 · Reloading mid-call resumes the open attempt'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  perform t.next('A');
  att := t.dial('A', 'X');
  n := t.next('A');
  assert n->>'reason' = 'resume' and (n->>'attempt_id')::bigint = att, 'reload resumes the open call';
  n := t.log('A', att, 'no_answer');
  assert n->'next'->>'reason' <> 'resume' and t.name(n->'next') <> 'X';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  att := t.dial('A', 'X');
  -- the webhook auto-logs "no answer" before the agent presses a key
  update attempts set disposition = 'no_answer', auto_logged = true, connected = false, disposed_at = now() where id = att;
  n := t.next('A');
  assert n->>'reason' = 'resume', 'an auto-logged call still comes back for the agent to confirm';
  n := t.log('A', att, 'voicemail', '{"left_message": true}');
  assert n->>'already_logged' is null and (select disposition from attempts where id = att) = 'voicemail';
end $$;

\echo '9 · A disposition logged twice (double key, retry) is applied once'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  att := t.dial('A', 'X');
  perform t.log('A', att, 'callback', jsonb_build_object('due_at', now() + interval '1 day'));
  n := t.log('A', att, 'callback', jsonb_build_object('due_at', now() + interval '1 day'));
  assert (n->>'already_logged')::boolean, 'second log is a no-op';
  assert (select count(*) from callbacks) = 1 and (select connects_total from lead_state where lead_id = t.lead('X')) = 1;
end $$;

\echo '10 · Today is the business day (it was the UTC day: reset at 5pm Pacific)'
select t.reset() \g /dev/null
do $$
begin
  perform t.dial('A', 'X');
  assert (select attempts_today_date from lead_state where lead_id = t.lead('X')) = business_date();
  assert business_day_start() at time zone 'America/Los_Angeles' = business_date()::timestamp, 'day starts at midnight Pacific';
  insert into attempts (lead_id, agent_id, clicked_at) values (t.lead('Y'), t.uid('A'), business_day_start() - interval '1 minute');
  assert (select dials_today from v_floor_today where agent_id = t.uid('A')) = 1, 'yesterday (Pacific) is not today';
end $$;

\echo '11 · Nobody signed in: every entry point refuses'
select t.as_user(null) \g /dev/null
do $$
begin
  perform t.fails('select public.log_disposition(1, ''dnc'')', 'not signed in');
  perform t.fails('select public.start_attempt(1)', 'not signed in');
  perform t.fails('select public.skip_lead(1)', 'not signed in');
  perform t.fails('select public.release_lead(1)', 'not signed in');
  perform t.fails('select public.heartbeat(''idle'')', 'not signed in');
  perform t.fails('select public.heartbeat(''ping'')', 'not signed in');
  assert public.next_lead()->>'error' = 'not signed in';
end $$;

\echo '12 · Grants: anon gets nothing; agents get the app''s calls but not the internals'
select t.reset() \g /dev/null
select t.as_user('A') \g /dev/null
set role anon;
do $$
begin
  perform t.fails('select public.next_lead()', 'permission denied');
  perform t.fails('select public.log_disposition(1, ''dnc'')', 'permission denied');
  perform t.fails('select public.build_workspace(1, ''peek'')', 'permission denied');
  perform t.fails('select public.bump_number_stats(''5555550000'', true)', 'permission denied');
  perform t.fails('select public.refresh_lead(1)', 'permission denied');
  perform t.fails('select public.funnel(1)', 'permission denied');
  perform t.fails('select public.team()', 'permission denied');
  perform t.fails('select public.battlecard_stats(30)', 'permission denied');
  perform t.fails('select public.ab_results(1)', 'permission denied');
  perform t.fails('select public.ab_set_status(1, ''running'')', 'permission denied');
  assert (select count(*) from public.library_items) = 0, 'anon sees no library';
  perform t.fails('select public.radar()', 'permission denied');
  perform t.fails('select public.radar_daily()', 'permission denied');
  perform t.fails('select public.radar_deal_now()', 'permission denied');
  perform t.fails('select public.set_member(t.uid(''A''), p_active => false)', 'permission denied');
end $$;
reset role;
set role authenticated;
do $$
begin
  assert t.name(public.next_lead()) = 'X', 'a signed-in agent can load a lead';
  perform public.heartbeat('idle');
  assert (select dials_today from public.v_floor_today where agent_id = t.uid('A')) = 0, 'the floor board is readable';
  perform t.fails('select public.build_workspace(1, ''peek'')', 'permission denied');
  perform t.fails('select public.wake_rested()', 'permission denied');
  perform t.fails('select public.refresh_lead(1)', 'permission denied');
  perform t.fails('select public.bump_number_stats(''5555550000'', true)', 'permission denied');
end $$;
reset role;
set role service_role;
do $$ begin perform public.refresh_lead(1); perform public.bump_number_stats('5555550000', true); end $$;
reset role;

\echo '13 · Signup still creates a profile with handle_new_user locked down'
set role supabase_auth_admin;
insert into auth.users (id, email) values ('dddddddd-0000-0000-0000-00000000000d', 'new.agent@test');
reset role;
do $$ begin
  assert exists (select 1 from profiles where id = 'dddddddd-0000-0000-0000-00000000000d');
end $$;

\echo '14 · A rest ends: resting leads rejoin the queue (they were dropped for good)'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  att := t.dial('A', 'X');
  n := t.log('A', att, 'not_interested_soft');
  assert (select state = 'resting' and rest_until > now() + interval '9 days' from lead_state where lead_id = t.lead('X')),
    'not interested (soft) rests 10 days';
  assert t.name(n->'next') <> 'X', 'not served while resting';
  -- ten days later
  update lead_state set rest_until = now() - interval '1 minute', last_attempt_at = now() - interval '10 days'
    where lead_id = t.lead('X');
  n := t.next('B');
  assert t.name(n) = 'X', format('served again once the rest is over, got %s', t.name(n));
  assert (select state from lead_state where lead_id = t.lead('X')) = 'queued', 'and back to queued';
end $$;
select t.reset() \g /dev/null
do $$
declare att bigint; r jsonb;
begin
  att := t.dial('A', 'X');
  perform t.log('A', att, 'language_barrier');
  update lead_state set rest_until = now() - interval '1 minute' where lead_id = t.lead('X');
  perform t.as_user('M');
  r := build_list('after the rest', null, '{}', 10);
  assert exists (select 1 from list_items where list_id = (r->>'list_id')::bigint and lead_id = t.lead('X')),
    'list building picks it up too';
end $$;

\echo '15 · Agents can''t make themselves managers; a deactivated agent is served nothing and can''t dial'
select t.reset() \g /dev/null
select t.as_user('A') \g /dev/null
set role authenticated;
do $$
begin
  perform t.fails(format('update public.profiles set role = %L where id = %L', 'manager', t.uid('A')), 'permission denied');
  perform t.fails(format('update public.profiles set active = true where id = %L', t.uid('A')), 'permission denied');
  update public.profiles set name = 'Agent A' where id = t.uid('A');   -- renaming yourself is fine
end $$;
reset role;
do $$
declare att bigint; n jsonb;
begin
  assert (select role = 'agent' and name = 'Agent A' from profiles where id = t.uid('A'));
  update profiles set name = 'agent.a' where id = t.uid('A');
  att := t.dial('A', 'X');
  update profiles set active = false where id = t.uid('A');
  n := t.next('A');
  assert n->>'reason' = 'resume', 'a call open when deactivated still comes back to be logged';
  n := t.log('A', att, 'no_answer');
  assert n->'next'->>'error' like '%deactivated%', 'then no more leads';
  perform t.fails(format('select public.start_attempt(%s)', t.lead('Y')), 'deactivated');
  update profiles set active = true where id = t.uid('A');
  assert t.name(t.next('A')) is not null, 'reactivated: served again';
end $$;

\echo '16 · The calling window is checked when dialing, not only when the lead was served'
select t.reset() \g /dev/null
do $$
declare w jsonb := (select value from app_settings where key = 'call_window');
        shut text := left(((now() at time zone 'America/New_York') + interval '2 hours')::time::text, 5);
begin
  assert t.name(t.next('A')) = 'X', 'served while the window is open';
  update app_settings set value = jsonb_build_object('start', shut, 'end', shut) where key = 'call_window';
  perform t.fails(format('select public.start_attempt(%s)', t.lead('X')), 'calling window');
  update app_settings set value = w where key = 'call_window';
  perform t.dial('A', 'X');
end $$;

\echo '17 · The floor board shows a browser that went quiet as offline; a ping keeps it live'
select t.reset() \g /dev/null
do $$
begin
  perform t.as_user('A');
  perform public.heartbeat('idle');
  assert (select status from v_floor_today where agent_id = t.uid('A')) = 'idle';
  update agent_status set updated_at = now() - interval '10 minutes' where agent_id = t.uid('A');
  assert (select status from v_floor_today where agent_id = t.uid('A')) = 'offline', 'quiet for 10 minutes: offline';
  perform public.heartbeat('ping');
  assert (select status from v_floor_today where agent_id = t.uid('A')) = 'idle', 'a ping brings it back, status unchanged';
end $$;

\echo '18 · A lead''s history carries the AI call summary Zoom attached to an earlier call'
select t.reset() \g /dev/null
do $$
declare att bigint; n jsonb;
begin
  att := t.dial('A', 'X');
  perform t.log('A', att, 'no_answer');
  update attempts set ai_summary = '{"summary":"Owner wants a quote","next_steps":"Call Friday"}' where id = att;
  update lead_state set last_attempt_at = now() - interval '3 hours' where lead_id = t.lead('X');
  n := t.next('B');
  assert t.name(n) = 'X', format('X comes round again, got %s', t.name(n));
  assert n->'history'->0->>'ai_summary' = 'Owner wants a quote' and n->'history'->0->>'next_steps' = 'Call Friday',
    'the earlier call shows its summary';
end $$;

\echo '19 · Every dial records where it came from, and the funnel adds it all up (managers only)'
select t.reset() \g /dev/null
do $$
declare att bigint; f jsonb; n jsonb; v_list bigint;
begin
  perform t.as_user('M');
  v_list := (build_list('A''s list', t.uid('A'), '{}', 1)->>'list_id')::bigint;   -- just X
  n := t.next('A');
  assert n->>'reason' = 'list';
  att := t.dial('A', 'X');
  assert (select source = 'list' and list_id = v_list from attempts where id = att), 'a list dial records its list';
  -- the call connected (as the webhook records it) and ended in a callback that is due now
  update attempts set call_result = 'answered', duration_seconds = 90 where id = att;
  perform t.log('A', att, 'callback', jsonb_build_object('due_at', now() - interval '1 minute'));
  att := t.dial('A', 'X');
  assert (select source = 'callback' and list_id is null from attempts where id = att), 'a due callback is recorded as one';
  perform t.log('A', att, 'chance_website', '{"summary":"wants a site","rating":5}');
  n := t.next('B');
  assert n->>'reason' = 'pool';
  att := t.dial('B', t.name(n));
  assert (select source = 'pool' from attempts where id = att), 'a pool dial is recorded as one';
  perform t.log('B', att, 'no_answer');

  -- and one from three days ago
  insert into attempts (lead_id, agent_id, clicked_at, source) values (t.lead('Z'), t.uid('B'), now() - interval '3 days', 'pool');

  perform t.as_user('M');
  f := public.funnel(1);
  assert (f->'totals'->>'dials')::int = 3, format('3 dials, got %s', f->'totals');
  -- the handoff call was never matched by Zoom, but a logged conversation was picked up
  assert (f->'totals'->>'answered')::int = 2 and (f->'totals'->>'conversations')::int = 2
     and (f->'totals'->>'handoffs')::int = 1 and (f->'totals'->>'talk_seconds')::int = 90,
    format('answered 2, conversations 2, handoffs 1, 90 s talk; got %s', f->'totals');
  assert jsonb_array_length(f->'by_agent') = 2, 'two agents dialed';
  assert exists (select 1 from jsonb_array_elements(f->'by_source') s
                  where s->>'source' = 'list' and s->>'list' = 'A''s list' and (s->>'dials')::int = 1),
    format('by source: %s', f->'by_source');
  assert exists (select 1 from jsonb_array_elements(f->'by_source') s
                  where s->>'source' = 'callback' and (s->>'handoffs')::int = 1), 'the handoff came from the callback';
  assert (select sum((h->>'dials')::int) from jsonb_array_elements(f->'by_hour') h) = 3, 'every dial lands in an hour';
  assert (public.funnel(7)->'totals'->>'dials')::int = 4, 'the last 7 days include the older dial; today does not';

  perform t.as_user('A');
  perform t.fails('select public.funnel(7)', 'manager only');
end $$;

\echo '20 · Email templates: managers write them, the queue records which one went out'
select t.reset() \g /dev/null
set role anon;
do $$ begin
  assert (select count(*) from public.email_templates) = 0, 'anon sees no templates';
end $$;
reset role;
set role authenticated;
do $$
declare att bigint; q bigint; tpl bigint; n int;
begin
  perform t.as_user('A');
  assert (select count(*) from email_templates where active) >= 3, 'the starter drafts are there, and agents can read them';
  perform t.fails('insert into email_templates (name, subject, body) values (''mine'', ''s'', ''b'')', 'row-level security');
  update email_templates set body = 'hijacked' where name = 'AI receptionist';
  get diagnostics n = row_count;
  assert n = 0, 'an agent can''t edit a template';

  -- an agent queues an email the usual way
  att := t.dial('A', 'X');
  perform t.log('A', att, 'email_requested', '{"email":"owner@x.test","note":"wants prices"}');
  q := (select id from email_queue where lead_id = t.lead('X'));
  assert q is not null, 'the email is queued';
  update email_queue set status = 'sent' where id = q;
  get diagnostics n = row_count;
  assert n = 0, 'an agent can''t mark it sent';

  perform t.as_user('M');
  insert into email_templates (name, subject, body) values ('Follow-up', 'Hi {business}', 'From {my_name}') returning id into tpl;
  update email_templates set subject = 'Hello {business}' where id = tpl;
  assert (select subject from email_templates where id = tpl) = 'Hello {business}', 'a manager edits templates';
  perform t.fails('insert into email_templates (name) values (''  '')', 'check constraint');
  update email_queue set status = 'sent', template = 'Follow-up', sent_by = t.uid('M'), sent_at = now() where id = q;
  assert (select status = 'sent' and template = 'Follow-up' from email_queue where id = q), 'the queue records the template that went out';
  delete from email_templates where id = tpl;
  assert (select template from email_queue where id = q) = 'Follow-up', 'deleting a template keeps the history';
end $$;
reset role;

\echo '21 · Team: managers rename, promote and deactivate; nobody can lock the team out'
select t.reset() \g /dev/null
set role authenticated;
do $$
declare r jsonb; n jsonb;
begin
  perform t.as_user('A');
  perform t.fails('select * from public.team()', 'manager only');
  perform t.fails('select public.set_member(t.uid(''A''), p_role => ''manager'')', 'manager only');
  perform t.fails('select public.set_member(t.uid(''B''), p_active => false)', 'manager only');

  perform t.as_user('M');
  assert (select count(*) from public.team()) >= 3, 'the manager sees the whole team';
  assert (select email from public.team() where id = t.uid('A')) = 'agent.a@test', 'with each login''s email';

  r := public.set_member(t.uid('A'), p_name => '  Ana  ');
  assert r->>'name' = 'Ana' and (select name from profiles where id = t.uid('A')) = 'Ana', 'rename (trimmed)';
  perform t.fails('select public.set_member(t.uid(''A''), p_name => ''  '')', 'can''t be empty');
  perform t.fails('select public.set_member(t.uid(''A''), p_role => ''owner'')', 'role must be');
  perform t.fails('select public.set_member(t.uid(''M''), p_active => false)', 'yourself');
  perform t.fails('select public.set_member(t.uid(''M''), p_role => ''agent'')', 'yourself');
  perform t.fails('select public.set_member(''eeeeeeee-0000-0000-0000-00000000000e'', p_name => ''x'')', 'no such team member');
  r := public.set_member(t.uid('M'), p_name => 'Boss');
  assert r->>'role' = 'manager' and (r->>'active')::boolean, 'a manager can still rename themselves';

  -- deactivate: served nothing, gone from the floor board, still listed on the team
  perform public.set_member(t.uid('B'), p_active => false);
  n := t.next('B');
  assert n->>'error' like '%deactivated%', format('a deactivated agent is served nothing: %s', n);
  perform t.as_user('M');
  assert not exists (select 1 from v_floor_today where agent_id = t.uid('B')), 'off the floor board';
  assert (select not active from public.team() where id = t.uid('B')), 'still on the team, marked inactive';
  perform public.set_member(t.uid('B'), p_active => true);
  assert t.name(t.next('B')) is not null, 'reactivated, they dial again';

  -- promote an agent; the new manager can manage, and demote the first one
  perform t.as_user('M');
  perform public.set_member(t.uid('A'), p_role => 'manager');
  perform t.as_user('A');
  assert (select count(*) from public.team()) >= 3, 'the promoted agent now sees the team';
  perform public.set_member(t.uid('M'), p_role => 'agent');
  perform t.as_user('M');
  perform t.fails('select * from public.team()', 'manager only');
  -- put things back for anything that runs after (each one by the other manager)
  perform t.as_user('A');
  perform public.set_member(t.uid('M'), p_role => 'manager', p_name => 'manager');
  perform t.as_user('M');
  perform public.set_member(t.uid('A'), p_role => 'agent', p_name => 'agent.a');
end $$;
reset role;

\echo '22 · Playbook: counters ranked by the calls they kept alive, taps in each call''s log, the A/B lab off until switched on, a manager-only library'
select t.reset() \g /dev/null
set role authenticated;
do $$
declare att bigint; card bigint; s jsonb; c jsonb;
begin
  card := (select id from battlecards where objection = 'Too expensive');
  -- A hears "too expensive", answers with the first counter, and gets a callback
  att := t.dial('A', 'X');
  insert into card_taps (attempt_id, card_id, agent_id) values (att, card, t.uid('A'));
  insert into card_taps (attempt_id, card_id, agent_id, counter) values (att, card, t.uid('A'), 'first counter');
  insert into card_taps (attempt_id, card_id, agent_id, counter) values (att, card, t.uid('A'), 'first counter'); -- a double tap counts once
  perform t.log('A', att, 'callback', jsonb_build_object('due_at', now() + interval '1 day'));
  perform t.fails(format('insert into card_taps (attempt_id, card_id, agent_id) values (%s, %s, %L)', att, card, t.uid('B')), 'row-level security');
  -- B hears it too, tries the second counter, and loses the call (A's next lead is held for A)
  att := t.dial('B', 'D1');
  insert into card_taps (attempt_id, card_id, agent_id, counter) values (att, card, t.uid('B'), 'second counter');
  perform t.log('B', att, 'not_interested_soft');

  perform t.as_user('A');
  s := (select x from jsonb_array_elements(public.battlecard_stats(30)) x where (x->>'card_id')::bigint = card);
  assert (s->>'calls')::int = 2 and (s->>'kept')::int = 1, format('heard in 2 calls, 1 kept alive: %s', s);
  c := s->'counters';
  assert jsonb_array_length(c) = 2 and c->0->>'text' = 'first counter' and (c->0->>'uses')::int = 1 and (c->0->>'kept')::int = 1
     and c->1->>'text' = 'second counter' and (c->1->>'kept')::int = 0, format('the counter that kept a call alive ranks first: %s', c);
end $$;
reset role;
do $$
declare h jsonb;
begin
  h := public.build_workspace(t.lead('X'), 'peek')->'history'->0;
  assert h->'taps'->0->>'objection' = 'Too expensive' and h->'taps'->0->'counters' = '["first counter"]'::jsonb,
    format('the call log shows the objection and the counter used: %s', h);
  assert h->>'disposition' = 'callback', 'next to the outcome';
end $$;

-- D6 (logging a call reserves the agent's next lead: clear holds between steps)
update lead_state set reserved_by = null, reserved_until = null;
set role authenticated;
do $$
declare tst bigint; tst2 bigint; tst3 bigint; att bigint; r jsonb;
begin
  perform t.as_user('M');
  insert into ab_tests (name, variants) values ('Opener', '[{"key":"A","text":"Hi, opener A"},{"key":"B","text":"Hi, opener B"}]') returning id into tst;
  perform public.ab_set_status(tst, 'running');
  assert (select status = 'running' and started_at is not null from ab_tests where id = tst), 'the test runs';

  att := t.dial('A', 'Z');
  assert (select ab_test_id is null from attempts where id = att), 'the lab switch is off: no opener recorded';

  perform t.as_user('M');
  update app_settings set value = 'true' where key = 'ab_lab_enabled';
  att := t.dial('A', 'W');
  assert (select ab_test_id = tst and ab_variant in ('A', 'B') from attempts where id = att), 'switched on: the dial records its opener';
  perform t.log('A', att, 'email_requested', '{"email":"w@x.test"}');

  perform t.as_user('A');
  perform t.fails(format('select public.ab_set_status(%s, ''stopped'')', tst), 'manager only');
  perform t.fails(format('select public.ab_results(%s)', tst), 'manager only');

  perform t.as_user('M');
  r := public.ab_results(tst);
  assert jsonb_array_length(r) = 1 and (r->0->>'dials')::int = 1 and (r->0->>'kept')::int = 1, format('results: %s', r);
  perform t.fails(format('update ab_tests set variants = ''[{"key":"A","text":"x"},{"key":"B","text":"y"}]'' where id = %s', tst), 'already run');

  insert into ab_tests (name, variants) values ('One-sided', '[{"key":"A","text":"only one"}]') returning id into tst2;
  perform t.fails(format('select public.ab_set_status(%s, ''running'')', tst2), 'at least two variants');
  insert into ab_tests (name, variants) values ('Next', '[{"key":"A","text":"a"},{"key":"B","text":"b"},{"key":"C","text":"c"}]') returning id into tst3;
  perform public.ab_set_status(tst3, 'running');
  assert (select status = 'stopped' and stopped_at is not null from ab_tests where id = tst), 'starting a test stops the one running';
  assert (select count(*) from ab_tests where status = 'running') = 1, 'one test at a time';
  perform public.ab_set_status(tst3, 'stopped');
  update app_settings set value = 'false' where key = 'ab_lab_enabled';
end $$;
reset role;
do $$
declare w jsonb;
begin
  -- the opener on screen is the one the dial recorded
  update app_settings set value = 'true' where key = 'ab_lab_enabled';
  update ab_tests set status = 'running', stopped_at = null where name = 'Opener';
  w := public.build_workspace(t.lead('W'), 'peek');
  assert w->'ab'->>'variant' = (select ab_variant from attempts where lead_id = t.lead('W') order by id desc limit 1),
    format('same opener on screen and on record: %s', w->'ab');
  update ab_tests set status = 'stopped' where name = 'Opener';
  update app_settings set value = 'false' where key = 'ab_lab_enabled';
  assert not (public.build_workspace(t.lead('W'), 'peek') ? 'ab'), 'no opener while the lab is off';
end $$;

-- D5
set role authenticated;
do $$
begin
  perform t.as_user('M');
  insert into library_items (title, scenario, body) values ('Price save', 'Price objection', 'We build it first…');
  assert (select count(*) from library_items) = 1, 'the manager keeps talk tracks';
  perform t.as_user('A');
  assert (select count(*) from library_items) = 0, 'agents don''t see the library';
  perform t.fails('insert into library_items (title) values (''mine'')', 'row-level security');
  perform t.as_user('M');
  delete from library_items;
end $$;
reset role;
delete from ab_tests;

\echo '23 · Radar: no pickup in business hours flags the AI-receptionist list; each business day every agent is dealt the best leads, once'
select t.reset() \g /dev/null
-- every hour of every day is business hours here, and 3 tries make the list
update app_settings set value = '{"start":"00:00","end":"23:59:59","days":[1,2,3,4,5,6,7]}' where key = 'business_hours';
update app_settings set value = '3' where key = 'missed_call_threshold';
set role authenticated;
do $$
declare att bigint;
begin
  -- X: rings out twice, then voicemail: flagged
  for i in 1..3 loop
    att := t.dial('A', 'X');
    perform t.log('A', att, case when i < 3 then 'no_answer' else 'voicemail' end,
                  case when i < 3 then '{}'::jsonb else '{"left_message": false}'::jsonb end);
  end loop;
  assert exists (select 1 from lead_intents where lead_id = t.lead('X') and intent_key = 'never_answers'),
    'three tries in business hours with no pickup: on the AI-receptionist list';
  -- Y: only two tries so far
  for i in 1..2 loop att := t.dial('A', 'Y'); perform t.log('A', att, 'no_answer'); end loop;
  assert not exists (select 1 from lead_intents where lead_id = t.lead('Y') and intent_key = 'never_answers'), 'two tries are not enough';
  -- Z: someone picked up once (a gatekeeper), so it doesn't "never answer"
  att := t.dial('A', 'Z'); perform t.log('A', att, 'gatekeeper_end');
  for i in 1..3 loop att := t.dial('A', 'Z'); perform t.log('A', att, 'no_answer'); end loop;
  assert not exists (select 1 from lead_intents where lead_id = t.lead('Z') and intent_key = 'never_answers'), 'a lead that once answered is not flagged';
end $$;
reset role;
-- tries outside business hours don't count
update app_settings set value = '{"start":"00:00","end":"23:59:59","days":[]}' where key = 'business_hours';
update lead_state set reserved_by = null, reserved_until = null;  -- A's logged calls hold A's next lead
set role authenticated;
do $$
declare att bigint;
begin
  for i in 1..3 loop att := t.dial('B', 'W'); perform t.log('B', att, 'no_answer'); end loop;
  assert not exists (select 1 from lead_intents where lead_id = t.lead('W') and intent_key = 'never_answers'),
    'tries outside their business hours prove nothing';
end $$;
reset role;
update app_settings set value = '{"start":"00:00","end":"23:59:59","days":[1,2,3,4,5,6,7]}' where key = 'business_hours';
do $$
declare w jsonb;
begin
  w := public.build_workspace(t.lead('X'), 'peek');
  assert (w->'missed'->>'count')::int = 3 and jsonb_array_length(w->'missed'->'times') = 3,
    format('the agent sees the tries as proof: %s', w->'missed');
  assert not (public.build_workspace(t.lead('Y'), 'peek') ? 'missed'), 'no proof line for a lead not on the list';
end $$;

-- C3: two leads in season, two agents, two leads each
update app_settings set value = '2' where key = 'radar_deal_per_agent';
update app_settings set value = '[{"label":"Test season","keys":["siding"],"months":[1,2,3,4,5,6,7,8,9,10,11,12]}]' where key = 'seasons';
update leads set category_key = 'roofing,siding', addr_city = 'Tampa', website_type = 'none', first_seen = now() - interval '2 days'
 where name in ('Y', 'Z');
-- the next morning: nothing is cooling down or held yet
update lead_state set reserved_by = null, reserved_until = null, last_attempt_at = now() - interval '1 day', attempts_today = 0;
delete from app_settings where key = 'radar_last_run';
update profiles set active = false where id = 'dddddddd-0000-0000-0000-00000000000d';  -- group 13's signup: off the floor, so not dealt
set role authenticated;
do $$
declare r jsonb; la bigint; lb bigint; n jsonb;
begin
  perform t.as_user('A');
  r := public.radar_daily();
  assert (r->>'ran')::boolean and (r->>'lists')::int = 2, format('the first page of the day deals each active agent a list: %s', r);
  assert not (public.radar_daily()->>'ran')::boolean, 'and only once a day';
  la := (select id from lists where kind = 'radar' and agent_id = t.uid('A'));
  lb := (select id from lists where kind = 'radar' and agent_id = t.uid('B'));
  assert (select count(*) from list_items where list_id = la) = 2 and (select count(*) from list_items where list_id = lb) = 2, 'two leads each';
  assert not exists (select 1 from list_items a join list_items b on b.lead_id = a.lead_id where a.list_id = la and b.list_id = lb),
    'no lead is dealt twice';
  assert not exists (select 1 from lists where kind = 'radar' and agent_id = t.uid('M')), 'managers are not dealt a list';
  assert not exists (select 1 from lists where kind = 'radar' and agent_id = 'dddddddd-0000-0000-0000-00000000000d'), 'nor is an agent off the floor';
  assert (select count(*) from lead_intents where intent_key = 'seasonal_window' and source = 'radar') = 2, 'in-season trades are tagged';
  n := t.next('A');
  assert n->>'reason' = 'list', format('A is served from their radar list: %s', n->>'reason');
  perform t.fails('select public.radar_deal_now()', 'manager only');
  perform t.fails('select public.radar()', 'manager only');

  perform t.as_user('M');
  r := public.radar();
  assert (r->'never_answers'->>'total')::int = 1 and (r->'never_answers'->>'new_this_week')::int = 1, format('never answers: %s', r->'never_answers');
  assert jsonb_array_length(r->'lists') = 2, 'today''s radar lists are on the card';
  assert (select count(*) from jsonb_array_elements(r->'seasons') x where (x->>'open')::boolean) = 1, 'the season shows open';
  assert jsonb_array_length(r->'fresh_no_site') = 0, 'two fresh no-site roofers are not a cluster yet (3 needed)';
  assert (public.radar_deal_now()->'dealt') = '[]'::jsonb, 'dealing again mid-day leaves agents with a list alone';
end $$;
reset role;
-- the next business day: yesterday's radar lists close and fresh ones are dealt
update lists set list_date = list_date - 1 where kind = 'radar';
update app_settings set value = jsonb_set(value, '{date}', to_jsonb((business_date() - 1)::text)) where key = 'radar_last_run';
set role authenticated;
do $$
begin
  perform t.as_user('B');
  assert (public.radar_daily()->>'ran')::boolean, 'a new day, a new deal';
  assert (select count(*) from lists where kind = 'radar' and status = 'done') = 2, 'yesterday''s radar lists are closed';
  assert (select count(*) from lists where kind = 'radar' and status = 'active' and list_date = business_date()) = 2, 'today''s are dealt';

  -- the lists the radar cards build: trade, city, website, freshness
  perform t.as_user('M');
  update lists set status = 'done' where kind = 'radar';
  assert (public.build_list('Tampa roofers', null, '{"category":"plumbing,roofing","city":"tampa","website_type":"none","fresh_days":7}', 10)->>'count')::int = 2,
    'trade (any of), city, website and freshness rules';
  update lists set status = 'done';
  assert (public.build_list('Plumbers', null, '{"category":"plumbing"}', 10)->>'count')::int = 0, 'no plumbers here';
end $$;
reset role;

\echo 'all queue tests passed'
