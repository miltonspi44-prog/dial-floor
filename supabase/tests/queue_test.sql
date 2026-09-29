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

\echo 'all queue tests passed'
