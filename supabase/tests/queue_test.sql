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
           agent_status, card_taps, number_stats, agent_breaks, sprints, call_votes, referrals restart identity cascade;
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
  perform t.fails(format('select public.digest(%L, 7)', t.uid('A')), 'permission denied');
  perform t.fails('select public.insights(30)', 'permission denied');
  perform t.fails(format('select public.release_member(%L)', t.uid('A')), 'permission denied');
  perform t.fails('select public.set_member(t.uid(''A''), p_active => false)', 'permission denied');
  -- Phase 2
  perform t.fails('select public.pause_work(''lunch'')', 'permission denied');
  perform t.fails('select public.resume_work()', 'permission denied');
  perform t.fails('select public.my_pace()', 'permission denied');
  perform t.fails('select * from public.floor_pace()', 'permission denied');
  perform t.fails('select public.floor_alerts()', 'permission denied');
  perform t.fails('select public.recycle_pools()', 'permission denied');
  perform t.fails('select public.recycle_preview(''provider'', 0)', 'permission denied');
  perform t.fails('select public.recycle(''provider'', 0)', 'permission denied');
  perform t.fails('select * from public.recycle_candidates(''provider'')', 'permission denied');
  perform t.fails('select public.best_times()', 'permission denied');
  perform t.fails('select public.leaderboard(''today'')', 'permission denied');
  perform t.fails('select * from public.streaks()', 'permission denied');
  perform t.fails('select public.start_sprint(''x'', ''dials'', 30)', 'permission denied');
  perform t.fails('select public.end_sprint()', 'permission denied');
  perform t.fails('select public.sprint_board()', 'permission denied');
  perform t.fails('select public.vote_call(1)', 'permission denied');
  perform t.fails('select public.floor_pulse()', 'permission denied');
  perform t.fails(format('select public.scorecard(%L)', t.uid('A')), 'permission denied');
  perform t.fails('select public.add_referral(1, ''x'', ''3055550000'')', 'permission denied');
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
  perform t.fails('select public.best_time_refresh()', 'permission denied');
  perform t.fails('select public.recycle_leads(array[1]::bigint[], ''provider'')', 'permission denied');
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

\echo '24 · Coaching: each agent''s digest against the floor and targets, and outcome mining without the gatekeeper calls'
select t.reset() \g /dev/null
do $$
declare card bigint := (select id from battlecards where objection = 'Too expensive');
begin
  -- A: 40 dials today; 10 connected, one of them only a gatekeeper; 6 kept alive, 1 handoff, notes on every conversation
  insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, note, matched, duration_seconds)
  select t.lead('X'), t.uid('A'), now() - interval '30 seconds',
         i <= 10,
         case when i <= 5 then 'callback' when i = 6 then 'chance_website' when i <= 9 then 'not_interested_soft'
              when i = 10 then 'gatekeeper_end' else 'no_answer' end,
         case when i <= 5 then 'wants the homepage first, call Friday' when i <= 9 then 'said the price is fine' end,
         true, case when i <= 10 then 20 + i * 30 else 0 end
    from generate_series(1, 40) i;
  -- A tapped "too expensive" on three of the callbacks
  insert into card_taps (attempt_id, card_id, agent_id, counter)
  select id, card, t.uid('A'), 'first counter' from attempts where agent_id = t.uid('A') and disposition = 'callback' limit 3;
  -- B: 40 dials; 10 conversations, 2 kept alive, notes on 2
  insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, note, matched, duration_seconds)
  select t.lead('Y'), t.uid('B'), now() - interval '30 seconds',
         i <= 10,
         case when i <= 2 then 'callback' when i <= 10 then 'not_interested_hard' else 'no_answer' end,
         case when i between 3 and 4 then 'price too high for them' end,
         true, case when i <= 10 then 15 else 0 end
    from generate_series(1, 40) i;
end $$;
set role authenticated;
do $$
declare d jsonb; f jsonb;
begin
  perform t.as_user('A');
  d := public.digest(t.uid('A'), 1);
  assert (d->'me'->>'dials')::int = 40 and (d->'me'->>'conversations')::int = 9 and (d->'me'->>'kept')::int = 6,
    format('A: 40 dials, 9 conversations past the gatekeeper, 6 kept alive: %s', d->'me');
  assert (d->'floor'->>'conversations')::int = 19, format('the floor: %s', d->'floor');
  assert d->'strengths' = '["battlecards", "notes"]'::jsonb and d->>'fix' = 'pace',
    format('going well: taps and notes; to work on: the pace against 400 a day. Got %s / %s', d->'strengths', d->'fix');
  assert d->'objections'->0->>'objection' = 'Too expensive' and (d->'objections'->0->>'heard')::int = 3, format('objections: %s', d->'objections');
  assert (d->'best_hour'->>'dials')::int = 40, 'the best hour, on the leads'' clock';
  perform t.fails(format('select public.digest(%L, 7)', t.uid('B')), 'their own digest');
  perform t.fails('select public.insights(30)', 'manager only');

  perform t.as_user('B');
  d := public.digest(t.uid('B'), 1);
  assert d->>'fix' = 'pace' and not (d->'strengths' ? 'kept_rate'),
    format('B: 0 handoffs in 10 is not yet evidence (the floor predicts 0.5); pace is the fix. Got %s / %s', d->'strengths', d->'fix');

  perform t.as_user('M');
  assert (public.digest(t.uid('A'), 7)->'me'->>'dials')::int = 40, 'a manager reads anyone''s digest';
  f := public.insights(7);
  assert (f->>'conversations')::int = 19 and (f->>'kept')::int = 8, format('conversations and kept: %s', f);
  assert not exists (select 1 from jsonb_array_elements(f->'outcomes') o where o->>'disposition' = 'gatekeeper_end'),
    'gatekeeper calls are left out';
  assert f->'objections'->0->>'objection' = 'Too expensive' and (f->'objections'->0->>'kept')::int = 3
     and f->'objections'->0->'best_counter'->>'text' = 'first counter', format('objections: %s', f->'objections');
  assert (f->'no_objection'->>'calls')::int = 16, format('the calls without a tapped objection: %s', f->'no_objection');
  assert exists (select 1 from jsonb_array_elements(f->'words'->'kept') w where w->>'word' = 'homepage' and (w->>'notes')::int = 5),
    format('words in kept notes: %s', f->'words'->'kept');
  assert exists (select 1 from jsonb_array_elements(f->'words'->'lost') w where w->>'word' = 'price'),
    format('words in lost notes: %s', f->'words'->'lost');
  assert not exists (select 1 from jsonb_array_elements(f->'words'->'lost') w where w->>'word' = 'them'), 'stop words are dropped';
  assert (select sum((b->>'calls')::int) from jsonb_array_elements(f->'talk') b) = 19, 'every conversation lands in a talk-time bucket';
end $$;
reset role;

\echo '25 · Users: history decides delete vs remove, work can be handed back, a blocked login shows as removed'
select t.reset() \g /dev/null
update profiles set active = true;
set role supabase_auth_admin;
insert into auth.users (id, email) values ('eeeeeeee-0000-0000-0000-00000000000e', 'new.hire@test');  -- no history yet
reset role;
set role authenticated;
do $$
declare att bigint; r jsonb;
begin
  -- A: a call that ended in a callback, and a list of their own
  att := t.dial('A', 'X');
  perform t.log('A', att, 'callback', jsonb_build_object('due_at', now() + interval '1 day'));
  perform t.as_user('M');
  perform public.build_list('A''s list', t.uid('A'), '{}', 2);

  assert (select has_history from public.team() where id = t.uid('A')), 'A has calls on file';
  assert not (select has_history from public.team() where id = 'eeeeeeee-0000-0000-0000-00000000000e'), 'the new hire has none: deletable';
  assert not exists (select 1 from public.team() where removed), 'nobody is removed yet';
  assert (select callbacks = 1 and lists = 1 from public.team() where id = t.uid('A')), 'what A still holds';
  perform t.fails(format('select public.member_history(%L)', t.uid('A')), 'permission denied');

  perform t.as_user('A');
  perform t.fails(format('select public.release_member(%L)', t.uid('B')), 'manager only');

  perform t.as_user('M');
  r := public.release_member(t.uid('A'));
  assert (r->>'callbacks')::int = 1 and (r->>'lists')::int = 1, format('handed back: %s', r);
  assert (select status = 'requeued' from callbacks where lead_id = t.lead('X')), 'the callback is back in the queue';
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')), 'and so is its lead';
  assert (select agent_id is null and status = 'active' from lists where name = 'A''s list'), 'the list is shared with everyone';
end $$;
reset role;
do $$ begin
  assert (public.member_history(t.uid('A'))->>'attempts')::int = 1, 'the edge function (service role) reads the history';
end $$;
-- the edge function blocks a removed login in Auth
update auth.users set banned_until = now() + interval '100 years' where id = 'eeeeeeee-0000-0000-0000-00000000000e';
set role authenticated;
do $$ begin
  perform t.as_user('M');
  assert (select removed from public.team() where id = 'eeeeeeee-0000-0000-0000-00000000000e'), 'a blocked login shows as removed';
end $$;
reset role;

\echo '26 · Pacing: a pause needs a reason and is left out of pace; dials and talk per active hour against the target spread over the shift'
select t.reset() \g /dev/null
update profiles set active = false  -- the signups from groups 13 and 25: off the floor
 where id in ('dddddddd-0000-0000-0000-00000000000d', 'eeeeeeee-0000-0000-0000-00000000000e');
set role authenticated;
do $$
declare att bigint; p jsonb;
begin
  perform t.as_user('A');
  assert t.name(public.next_lead()) = 'X';
  perform t.fails('select public.pause_work(null)', 'pick a reason');
  perform t.fails('select public.pause_work(''nap'')', 'pick a reason');
  perform t.fails('select public.pause_work(''other'', ''  '')', 'say what the pause is for');
  att := t.dial('A', 'X');
  perform t.fails('select public.pause_work(''lunch'')', 'log the call you are on first');
  perform t.log('A', att, 'no_answer');
  assert exists (select 1 from lead_state where reserved_by = t.uid('A')), 'the next lead is up';
  p := public.pause_work('lunch');
  assert p->>'reason' = 'lunch';
  assert (select status from agent_status where agent_id = t.uid('A')) = 'break', 'the floor board shows the pause';
  assert not exists (select 1 from lead_state where reserved_by = t.uid('A')), 'the lead on screen goes back';
  assert public.my_pace()->'break'->>'reason' = 'lunch', 'the Dial page knows it is paused';
  assert public.pause_work('break')->>'reason' = 'lunch', 'pausing again keeps the one pause';
  assert (public.resume_work()->>'resumed')::boolean;
  assert jsonb_typeof(public.my_pace()->'break') = 'null' and not exists (select 1 from agent_breaks where ended_at is null), 'the pause is over';
  assert (select status from agent_status where agent_id = t.uid('A')) = 'idle';
  assert not (public.resume_work()->>'resumed')::boolean, 'resuming twice is harmless';
end $$;
reset role;
-- two hours on the floor with a half-hour lunch in the middle: 1.5 active hours
update attempts set clicked_at = now() - interval '2 hours' where agent_id = t.uid('A');
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, call_result, duration_seconds, matched)
select t.lead('Z'), t.uid('A'), now() - interval '1 hour' + make_interval(mins => i), i <= 3,
       case when i <= 3 then 'callback' else 'no_answer' end, case when i <= 3 then 'answered' end,
       case when i <= 3 then 300 else 0 end, true
  from generate_series(1, 44) i;
delete from agent_breaks;
insert into agent_breaks (agent_id, reason, started_at, ended_at)
  values (t.uid('A'), 'lunch', now() - interval '90 minutes', now() - interval '60 minutes');
set role authenticated;
do $$
declare p jsonb;
begin
  perform t.as_user('A');
  p := public.my_pace();
  -- 45 dials in 1.5 active hours = 30 an hour; 3 answered calls × 5 min = 15 min of talk = 10 a hour
  assert (p->>'dials')::int = 45, format('dials: %s', p);
  assert abs((p->>'dials_per_hour')::numeric - 30) < 0.5, format('30 dials an active hour: %s', p->>'dials_per_hour');
  assert abs((p->>'talk_minutes_per_hour')::numeric - 10) < 0.3, format('10 talk minutes an hour: %s', p->>'talk_minutes_per_hour');
  assert (p->>'paused_minutes')::int = 30, format('paused: %s', p->>'paused_minutes');
  assert (p->>'target_per_hour')::numeric = 50, 'a 400 target over an 8-hour shift is 50 an hour';
  assert (p->>'wrapup_seconds')::int = 20;
end $$;
reset role;

\echo '27 · Alerts: idle, a long call, behind pace, an overdue callback and a collapsing number reach managers; everyone hears the bell'
-- continues from 26: A is 1.5 active hours in at 30 an hour, on pace for 240 of 400
update agent_status set status = 'idle', since = now() - interval '25 minutes', updated_at = now() where agent_id = t.uid('A');
insert into agent_status (agent_id, status, lead_name, since, updated_at)
  values (t.uid('B'), 'dialing', 'W', now() - interval '20 minutes', now())
  on conflict (agent_id) do update set status = 'dialing', lead_name = 'W', since = excluded.since, updated_at = now();
insert into callbacks (lead_id, agent_id, due_at) values (t.lead('D1'), t.uid('B'), now() - interval '40 minutes');
insert into number_stats (number, stat_date, dials, connects) values
  ('3055551111', business_date() - 10, 100, 25), ('3055551111', business_date() - 1, 100, 5);
update lead_state set reserved_by = null, reserved_until = null;
set role authenticated;
do $$
declare al jsonb; att bigint;
begin
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'idle' and x->>'key' like 'idle:' || t.uid('A') || ':%'), format('A idle: %s', al);
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'long_call' and x->>'key' like 'long:' || t.uid('B') || ':%'), 'B on one call 20 min';
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'pace' and x->>'key' like 'pace:' || t.uid('A') || ':%'), 'A behind pace';
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'callback' and x->>'title' like '%D1'), 'B''s callback 40 min overdue';
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'spam' and x->>'number' = '3055551111'), 'a number down from 25% to 5%';
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'win');

  perform t.as_user('B');
  assert jsonb_array_length(public.floor_alerts()) = 0, 'agents only hear the bell';
  -- A hands off: the bell rings for everyone, and A is no longer idle
  att := t.dial('A', 'W');
  perform t.log('A', att, 'chance_website', '{"summary": "homepage first", "rating": 4}');
  perform t.as_user('B');
  al := public.floor_alerts();
  assert jsonb_array_length(al) = 1 and al->0->>'kind' = 'win' and al->0->>'key' = 'win:' || att and al->0->>'detail' = 'W', format('the bell: %s', al);
  perform t.as_user('M');
  al := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'win');
  assert not exists (select 1 from jsonb_array_elements(al) x where x->>'kind' = 'idle'), 'dialing ends the idle alert';
end $$;
reset role;
update app_settings set value = '{"idle_minutes": 0, "long_call_minutes": 0, "pace_pct": 0, "callback_overdue_minutes": 0, "celebrate": false, "spam": false}'
 where key = 'alerts';
set role authenticated;
do $$ begin
  perform t.as_user('M');
  assert jsonb_array_length(public.floor_alerts()) = 0, 'every alert can be switched off';
end $$;
reset role;
update app_settings set value = '{"idle_minutes": 10, "long_call_minutes": 15, "pace_pct": 80, "callback_overdue_minutes": 15, "celebrate": true, "spam": true}'
 where key = 'alerts';

\echo '28 · Recycling: parked leads come back when the manager says (or after N days when switched on); "has a provider" returns as a win-back'
select t.reset() \g /dev/null
set role authenticated;
do $$
declare att bigint;
begin
  att := t.dial('A', 'X'); perform t.log('A', att, 'has_provider');
  att := t.dial('A', 'Y'); perform t.log('A', att, 'not_interested_soft');
  att := t.dial('A', 'Z'); perform t.log('A', att, 'has_provider');
end $$;
reset role;
-- X said "we have someone" 200 days ago, Z 40 days ago; Y said no 20 days ago and still rests
update attempts set clicked_at = now() - interval '200 days', disposed_at = now() - interval '200 days' where lead_id = t.lead('X');
update attempts set clicked_at = now() - interval '40 days', disposed_at = now() - interval '40 days' where lead_id = t.lead('Z');
update attempts set clicked_at = now() - interval '20 days', disposed_at = now() - interval '20 days' where lead_id = t.lead('Y');
set role authenticated;
do $$
declare p jsonb; r jsonb;
begin
  perform t.as_user('A');
  perform t.fails('select public.recycle_pools()', 'manager only');
  perform t.fails('select public.recycle(''provider'', 0)', 'manager only');
  perform t.as_user('M');
  p := public.recycle_pools();
  assert p->'pools'->0->>'pool' = 'provider' and (p->'pools'->0->>'total')::int = 2
     and (p->'pools'->0->'ages'->>'30')::int = 2 and (p->'pools'->0->'ages'->>'180')::int = 1, format('provider pool: %s', p->'pools'->0);
  assert (p->'pools'->1->>'total')::int = 1 and (p->'pools'->1->'outcomes'->>'not_interested_soft')::int = 1, format('resting pool: %s', p->'pools'->1);
  assert (p->>'auto_provider_days')::int = 0, 'automatic recycling starts off';
  assert (public.recycle_preview('provider', 180)->>'count')::int = 1 and public.recycle_preview('provider', 180)->'sample'->0->>'name' = 'X';
  assert (public.recycle_preview('provider', 365)->>'count')::int = 0;
  perform t.fails('select public.recycle(''everyone'', 0)', 'unknown pool');

  r := public.recycle('provider', 180, true);
  assert (r->>'recycled')::int = 1 and (r->>'listed')::int = 1, format('recycled: %s', r);
  assert (select state from lead_state where lead_id = t.lead('X')) = 'queued', 'X is back in the queue';
  assert exists (select 1 from lead_intents where lead_id = t.lead('X') and intent_key = 'provider_winback'), 'as a win-back';
  assert (select kind = 'recycle' and agent_id is null from lists where id = (r->>'list_id')::bigint), 'on a shared list';
  assert (select state from lead_state where lead_id = t.lead('Z')) = 'provider_list', 'Z (40 days) stays parked';

  r := public.recycle('resting', 0);
  assert (r->>'recycled')::int = 1 and r->>'list_id' is null, format('resting: %s', r);
  assert (select state = 'queued' and rest_until is null from lead_state where lead_id = t.lead('Y')), 'Y is back before its rest ends';
end $$;
reset role;
-- in season: a resting lead whose trade's season is open (group 23's all-year siding season)
update leads set category_key = 'siding' where name = 'W';
update lead_state set reserved_by = null, reserved_until = null;  -- A's logged calls hold A's next lead
set role authenticated;
do $$
declare att bigint; r jsonb;
begin
  att := t.dial('B', 'W'); perform t.log('B', att, 'not_interested_hard');
  perform t.as_user('M');
  assert (public.recycle_preview('season', 0)->>'count')::int = 1, 'W rests in an open season';
  r := public.recycle('season', 0);  -- its own statement: a query reads from before its own writes
  assert (r->>'recycled')::int = 1 and (select state from lead_state where lead_id = t.lead('W')) = 'queued', format('season: %s', r);
end $$;
reset role;
-- automatic: off, Z stays parked; at 30 days, the next lead request brings it back
set role authenticated;
do $$ begin perform t.next('B'); end $$;
reset role;
do $$ begin
  assert (select state from lead_state where lead_id = t.lead('Z')) = 'provider_list', 'nothing comes back on its own by default';
end $$;
update app_settings set value = '30' where key = 'recycle_provider_days';
set role authenticated;
do $$ begin perform t.next('B'); end $$;
reset role;
do $$ begin
  assert (select state from lead_state where lead_id = t.lead('Z')) = 'queued', 'switched on, the 40-day-old provider lead comes back';
  assert exists (select 1 from lead_intents where lead_id = t.lead('Z') and intent_key = 'provider_winback');
end $$;
update app_settings set value = '0' where key = 'recycle_provider_days';

\echo '29 · Best time: learned by trade and the lead''s hour, pulled toward the average until the data is there; an optional lean in the pool'
select t.reset() \g /dev/null
update app_settings set value = '{"days": 90, "min_dials": 30, "min_total": 100, "prior": 20, "use_in_queue": false}' where key = 'best_time';
update leads set category_key = 'roofing' where name in ('X', 'Y');
update leads set category_key = 'plumbing' where name in ('Z', 'W');
-- roofers pick up at 8am their time (20 of 40), rarely at 2pm (4 of 40); plumbers the same at both (8 of 40)
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition)
select t.lead(b.lead), t.uid('A'), ((business_date() - 1) + b.at) at time zone 'America/New_York', i <= b.hits,
       case when i <= b.hits then 'not_interested_soft' else 'no_answer' end
  from (values ('X', time '08:30', 20), ('X', time '14:30', 4), ('Z', time '08:30', 8), ('Z', time '14:30', 8)) b(lead, at, hits),
       generate_series(1, 40) i;
do $$
declare st jsonb;
begin
  st := public.best_time_refresh();
  assert (st->>'total')::int = 160 and (st->>'rate')::numeric = 0.25, format('state: %s', st);
  assert (select lift > 1.4 and reliable from best_time_cells where trade = 'roofing' and hour = 8), 'roofers: 8am is well above their day';
  assert (select lift < 0.6 and reliable from best_time_cells where trade = 'roofing' and hour = 14), 'and 2pm well below';
  assert (select lift between 0.8 and 1.2 from best_time_cells where trade = 'plumbing' and hour = 8)
     and (select lift between 0.8 and 1.2 from best_time_cells where trade = 'plumbing' and hour = 14),
    'a flat trade stays near its average (only the floor-wide hour effect leans in)';
  assert (select rate < 20.0 / 40 from best_time_cells where trade = 'roofing' and hour = 8), 'estimates are pulled toward the average, not taken raw';
end $$;
set role authenticated;
do $$
declare b jsonb;
begin
  perform t.as_user('A');
  b := public.best_times();
  assert (b->>'ready')::boolean and not (b->>'use_in_queue')::boolean, format('ready, not in the queue: %s', b->'state');
  assert (select (x->'cells'->0->>'hour')::int from jsonb_array_elements(b->'trades') x where x->>'trade' = 'roofing') = 8, 'roofing''s best hour first';
end $$;
reset role;
-- too little data: nothing is reliable
update app_settings set value = jsonb_set(value, '{min_total}', '1000') where key = 'best_time';
do $$ begin
  perform public.best_time_refresh();
  assert not exists (select 1 from best_time_cells where reliable), 'under min_total nothing counts';
end $$;
set role authenticated;
do $$ begin perform t.as_user('A'); assert not (public.best_times()->>'ready')::boolean; end $$;
reset role;
-- the queue lean: at this hour of their day plumbers pick up, roofers don't
delete from best_time_cells;
insert into best_time_cells (trade, hour, dials, connects, rate, lift, reliable) values
  ('plumbing', extract(hour from now() at time zone 'America/New_York')::int, 100, 40, 0.4, 1.6, true),
  ('roofing', extract(hour from now() at time zone 'America/New_York')::int, 100, 10, 0.1, 0.5, true);
set role authenticated;
do $$ begin assert t.name(t.next('A')) = 'X', 'switched off, the pool keeps its order (X scores 95)'; end $$;
reset role;
update lead_state set reserved_by = null, reserved_until = null;
update app_settings set value = jsonb_set(value, '{use_in_queue}', 'true') where key = 'best_time';
set role authenticated;
do $$ begin
  assert t.name(t.next('A')) = 'Z', 'switched on: Z (85 × 1.3) edges out X (95 × 0.7); the lean is held to 0.7–1.3';
end $$;
reset role;
update app_settings set value = '{"days": 90, "min_dials": 30, "min_total": 1000, "prior": 20, "use_in_queue": false}' where key = 'best_time';
update lead_state set reserved_by = null, reserved_until = null;

\echo '30 · Leaderboard: dials and conversations only; streaks at the daily target; a power hour with a first-to-N winner; one vote a day for someone else''s call'
select t.reset() \g /dev/null
update kpi_targets set target = 2 where metric = 'dials_per_day';
update app_settings set value = '{"start":"00:00","end":"23:59:59","days":[1,2,3,4,5,6,7]}' where key = 'business_hours';
-- A dialed 2 on each of the last two days; B once yesterday (short of the target)
insert into attempts (lead_id, agent_id, clicked_at, disposition)
select t.lead('D1'), t.uid(v.w), (business_date() - v.d)::timestamp at time zone business_tz() + interval '10 hours', 'no_answer'
  from (values ('A', 1), ('A', 1), ('A', 2), ('A', 2), ('B', 1)) v(w, d);
set role authenticated;
do $$
declare s jsonb; lb jsonb; a1 bigint; a2 bigint; b1 bigint; b2 bigint;
begin
  perform t.as_user('A');
  perform t.fails('select public.start_sprint(''x'', ''conversations'', 30)', 'manager only');
  perform t.as_user('M');
  perform t.fails('select public.start_sprint(''x'', ''talk'', 30)', 'dials or conversations');
  perform t.fails('select public.start_sprint(''x'', ''dials'', 1)', '5 to 240 minutes');
  s := public.start_sprint('', 'conversations', 60, 2);
  assert s->>'name' = 'Power hour', 'a sprint without a name is a power hour';

  -- A: a conversation and a no-answer; B: two conversations
  a1 := t.dial('A', 'X'); perform t.log('A', a1, 'callback', jsonb_build_object('due_at', now() + interval '1 day'));
  b1 := t.dial('B', 'Z'); perform t.log('B', b1, 'not_interested_soft');
  a2 := t.dial('A', 'Y'); perform t.log('A', a2, 'no_answer');
  b2 := t.dial('B', 'W'); perform t.log('B', b2, 'email_requested', '{"email": "w@test"}');

  s := public.sprint_board();
  assert (s->>'running')::boolean and s->'winner'->>'agent_id' = t.uid('B')::text, format('B is first to 2 conversations: %s', s);
  assert (s->'rows'->0->>'count')::int = 2 and (s->'rows'->1->>'count')::int = 1, format('standings: %s', s->'rows');

  lb := public.leaderboard('today');
  assert lb->'rows'->0->>'agent_id' = t.uid('B')::text, 'most conversations first';
  assert (select (r->>'streak')::int from jsonb_array_elements(lb->'rows') r where r->>'agent_id' = t.uid('A')::text) = 3,
    format('A: two days at target, and today: %s', lb->'rows');
  assert (select (r->>'streak')::int from jsonb_array_elements(lb->'rows') r where r->>'agent_id' = t.uid('B')::text) = 1,
    'B: short yesterday, at target today';
  assert (select (r->>'dials')::int from jsonb_array_elements(public.leaderboard('week')->'rows') r where r->>'agent_id' = t.uid('A')::text) >= 2,
    'the week adds up too';

  -- call of the day
  perform t.as_user('A');
  perform t.fails(format('select public.vote_call(%s)', a1), 'someone else');
  perform t.fails(format('select public.vote_call(%s)', a2), 'conversation from today');
  assert (public.vote_call(b2)->>'votes')::int = 1;
  assert (public.vote_call(b1)->>'votes')::int = 1;
  assert (select count(*) from call_votes) = 1, 'a second vote moves the first';
  perform t.as_user('M');
  perform public.vote_call(b1);
  lb := public.leaderboard('today');
  assert (lb->'call_of_the_day'->>'attempt_id')::bigint = b1 and (lb->'call_of_the_day'->>'votes')::int = 2, format('call of the day: %s', lb->'call_of_the_day');
  assert (lb->'votes'->>(b1::text))::int = 2 and (lb->>'my_vote')::bigint = b1;
  assert jsonb_typeof(public.vote_call(null)->'voted') = 'null';
  assert (public.leaderboard('today')->'votes'->>(b1::text))::int = 1, 'a vote can be taken back';
end $$;
-- a later transaction: the calls above were made before this race
do $$
declare s jsonb;
begin
  perform t.as_user('M');
  -- one race at a time; ending it early settles it
  s := public.start_sprint('Dial sprint', 'dials', 30);
  assert (select count(*) from sprints where ends_at > now()) = 1, 'a new race ends the one running';
  perform public.end_sprint();
  s := public.sprint_board();
  assert not (s->>'running')::boolean and s->>'name' = 'Dial sprint' and jsonb_typeof(s->'winner') = 'null', format('ended, no dials in it: %s', s);
  assert public.floor_pulse() ? 'sprint' and public.floor_pulse() ? 'wins';
end $$;
reset role;
update kpi_targets set target = 400 where metric = 'dials_per_day';

\echo '31 · Scorecards: the week against the floor over four weeks, with the handoffs and the long conversations that still ended in a no'
select t.reset() \g /dev/null
-- this week: A 10 dials (4 conversations: a 5-minute no, a handoff, two callbacks); B 20 dials, 2 conversations
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition, call_result, duration_seconds, matched)
select t.lead('X'), t.uid('A'), now(), i <= 4,
       case i when 1 then 'not_interested_hard' when 2 then 'chance_website' when 3 then 'callback' when 4 then 'callback' else 'no_answer' end,
       case when i <= 4 then 'answered' end, case when i = 1 then 300 when i <= 4 then 90 else 0 end, true
  from generate_series(1, 10) i;
insert into attempts (lead_id, agent_id, clicked_at, connected, disposition)
select t.lead('Y'), t.uid('B'), now(), i <= 2, case when i <= 2 then 'callback' else 'no_answer' end from generate_series(1, 20) i;
-- last week: A 6 dials
insert into attempts (lead_id, agent_id, clicked_at, disposition)
select t.lead('Z'), t.uid('A'), now() - interval '7 days', 'no_answer' from generate_series(1, 6);
insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
  values (t.lead('X'), '{"name": "X"}', 'chance_website', 'build the homepage', 5, t.uid('A'));
set role authenticated;
do $$
declare sc jsonb; w jsonb;
begin
  perform t.as_user('A');
  sc := public.scorecard(t.uid('A'));
  assert jsonb_array_length(sc->'weeks') = 4, 'four weeks';
  w := sc->'weeks'->3;
  assert (w->'me'->>'dials')::int = 10 and (w->'me'->>'conversations')::int = 4 and (w->'me'->>'won')::int = 1
     and (w->'me'->>'kept')::int = 3, format('this week: %s', w->'me');
  assert (w->'floor'->>'agents')::int = 2 and (w->'floor'->>'dials')::int = 30 and (w->'floor'->>'conversations')::int = 6,
    format('the floor: %s', w->'floor');
  assert (sc->'weeks'->2->'me'->>'dials')::int = 6, 'last week';
  assert jsonb_array_length(sc->'handoffs') = 1 and sc->'handoffs'->0->>'summary' = 'build the homepage';
  assert jsonb_array_length(sc->'review') = 1 and (sc->'review'->0->>'duration')::int = 300,
    format('the 5-minute no is worth talking through: %s', sc->'review');
  assert jsonb_array_length(sc->'saved') = 0, 'agents don''t see the library';
  perform t.as_user('B');
  perform t.fails(format('select public.scorecard(%L)', t.uid('A')), 'their own scorecard');
  perform t.as_user('M');
  assert (public.scorecard(t.uid('A'))->'weeks'->3->'me'->>'dials')::int = 10, 'managers see everyone''s';
end $$;
reset role;

\echo '32 · Referrals: a new lead (or the one on file) marked warm, at the top of the agent''s own list; do-not-call numbers refused'
select t.reset() \g /dev/null
set role authenticated;
do $$
declare att bigint; r jsonb; n jsonb; v bigint;
begin
  att := t.dial('A', 'X');
  perform t.fails(format('select public.add_referral(%s, ''Mike'', ''305-555'')', att), '10-digit');
  perform t.fails(format('select public.add_referral(%s, '' '', ''3055557777'')', att), 'who they are');
  perform t.fails(format('select public.add_referral(%s, ''X again'', ''(305) 555-0001'')', att), 'the number you are calling');
  perform t.as_user('B');
  perform t.fails(format('select public.add_referral(%s, ''Mike'', ''3055557777'')', att), 'not your call');
  perform t.as_user('A');
  r := public.add_referral(att, 'Mike''s Gutters', '(305) 555-7777', 'Gutters', null, null, 'his cousin; mention Joe');
  assert (r->>'created')::boolean, format('a new lead: %s', r);
  v := (r->>'lead_id')::bigint;
  assert (select source = 'referral' and source_id is null and addr_state = 'FL' and tz is not null and category = 'Gutters'
            and phone_display = '(305) 555-7777' from leads where id = v), 'a dialer-only lead in the referrer''s area';
  assert (select state from lead_state where lead_id = v) = 'queued';
  assert exists (select 1 from lead_intents where lead_id = v and intent_key = 'warm_referral'), 'marked warm';
  assert (select kind = 'referrals' and agent_id = t.uid('A') from lists where id = (r->>'list_id')::bigint), 'on A''s own Referrals list';
  n := t.log('A', att, 'not_interested_soft');
  assert t.name(n->'next') = 'Mike''s Gutters' and n->'next'->>'reason' = 'list', format('the referral is next: %s', t.name(n->'next'));
  assert n->'next'->'referral'->>'from' = 'X' and n->'next'->'referral'->>'note' = 'his cousin; mention Joe',
    format('the agent sees who sent us: %s', n->'next'->'referral');
  assert n->'next'->'intents'->0->>'key' = 'warm_referral', 'the warm referral leads the intents';
end $$;
do $$
declare att bigint; r jsonb;
begin
  -- Y rests after a no; referred to us again, it comes back rather than being duplicated
  att := t.dial('B', 'Y'); perform t.log('B', att, 'not_interested_hard');
  att := t.dial('B', 'Z');
  r := public.add_referral(att, 'Y, another name', '3055550002');
  assert not (r->>'created')::boolean and (r->>'lead_id')::bigint = t.lead('Y'), format('the number on file is linked: %s', r);
  assert (select state from lead_state where lead_id = t.lead('Y')) = 'queued', 'a parked lead comes back for the warm call';
  assert (select count(*) from leads where phone_norm = '3055550002') = 1, 'no second record';
  -- do-not-call
  perform t.log('B', att, 'dnc');
  att := t.dial('B', 'W');
  perform t.fails(format('select public.add_referral(%s, ''Z'', ''3055550003'')', att), 'do-not-call');
  perform t.log('B', att, 'no_answer');
end $$;
reset role;

\echo 'queue tests passed'
