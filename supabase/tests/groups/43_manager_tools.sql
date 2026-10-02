\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '43.1 · Settings: a whitelisted registry, each key validating its own value (item 36)'
select t.reset() \g /dev/null
do $$
declare a jsonb;
begin
  perform t.as_user('M');
  a := public.settings_all();
  assert jsonb_array_length(a) >= 20, format('the registry covers the tunables: %s keys', jsonb_array_length(a));
  assert (select x->'value' from jsonb_array_elements(a) x where x->>'key' = 'max_attempts_per_day') is not null,
    'every key arrives with its current value or its default';

  perform public.settings_set('max_attempts_per_day', '3'::jsonb);
  assert (public.setting('max_attempts_per_day'))::text = '3', 'a valid write lands';
  perform t.fails('select public.settings_set(''max_attempts_per_day'', ''99''::jsonb)', 'at most');
  perform t.fails('select public.settings_set(''max_attempts_per_day'', ''"three"''::jsonb)', 'wants a number');
  perform t.fails('select public.settings_set(''shift_hours'', ''0.5''::jsonb)', 'at least');
  perform t.fails('select public.settings_set(''business_tz'', ''"Mars/Olympus"''::jsonb)', 'not a timezone');
  perform public.settings_set('business_tz', '"America/Chicago"'::jsonb);
  assert public.business_tz() = 'America/Chicago', 'and a real one takes effect';
  perform public.settings_set('business_tz', '"America/Los_Angeles"'::jsonb);
  perform t.fails('select public.settings_set(''call_window'', ''{"start":"20:00","end":"08:00"}''::jsonb)', 'open before it closes');
  perform t.fails('select public.settings_set(''business_hours'', ''{"start":"08:00","end":"17:00","days":[1,9]}''::jsonb)', 'Monday');
  perform t.fails('select public.settings_set(''service_key'', ''"x"''::jsonb)', 'not a setting');
  perform public.settings_set('allow_general_pool', 'true'::jsonb);
  perform public.settings_set('max_attempts_per_day', '2'::jsonb);
  -- agents get nothing: it is the manager's panel
  perform t.as_user('A');
  assert public.settings_all() is null, 'agents do not read the registry';
  perform t.fails('select public.settings_set(''max_attempts_per_day'', ''2''::jsonb)', 'manager only');
end $$;

\echo '43.2 · Lists read manager-only; the queue still serves agents from them (item 44)'
select t.reset() \g /dev/null
do $$
declare v_list bigint; n jsonb;
begin
  perform t.as_user('M');
  insert into lists (name, agent_id, rules) values ('A''s morning', t.uid('A'), '{}') returning id into v_list;
  insert into list_items (list_id, lead_id, position) values (v_list, t.lead('Z'), 1);
  perform set_config('role', 'authenticated', true);
  perform t.as_user('A');
  assert (select count(*) from lists) = 0, 'an agent sees no lists';
  assert (select count(*) from list_items) = 0, 'and no list items';
  perform set_config('role', 'postgres', true);
  n := t.next('A');
  assert t.name(n) = 'Z' and n->>'reason' = 'list', 'but the queue serves their list all the same';
end $$;

\echo '43.3 · A list changes hands, shows its leads, takes one on and off by hand (items 37–38)'
select t.reset() \g /dev/null
do $$
declare v_list bigint; rows jsonb; att bigint;
begin
  perform t.as_user('M');
  insert into lists (name, agent_id, rules) values ('hand-picked', null, '{}') returning id into v_list;
  perform public.set_list_agent(v_list, t.uid('B'));
  assert (select agent_id from lists where id = v_list) = t.uid('B'), 'assigned';
  perform public.set_list_agent(v_list, null);
  assert (select agent_id from lists where id = v_list) is null, 'and shared again';
  update profiles set active = false where id = t.uid('B');
  perform t.as_user('M');
  perform t.fails(format('select public.set_list_agent(%s, %L::uuid)', v_list, t.uid('B')), 'switched off');
  update profiles set active = true where id = t.uid('B');

  perform t.as_user('M');
  perform public.list_add_lead(v_list, t.lead('X'));
  perform public.list_add_lead(v_list, t.lead('Y'));
  rows := public.list_leads(v_list, 10);
  assert jsonb_array_length(rows) = 2 and rows->0->>'name' = 'X',
    format('the list shows its leads in order: %s', rows);

  -- a served lead re-added is to be served again
  att := t.dial('A', 'X');
  perform t.log('A', att, 'no_answer');
  assert (select served_at is not null from list_items where list_id = v_list and lead_id = t.lead('X')),
    'dialed means served';
  perform t.as_user('M');
  perform public.list_add_lead(v_list, t.lead('X'));
  assert (select served_at is null from list_items where list_id = v_list and lead_id = t.lead('X')),
    're-adding clears served';

  perform public.list_remove_lead(v_list, t.lead('Y'));
  assert jsonb_array_length(public.list_leads(v_list, 10)) = 1, 'taken off by hand';

  -- a dead lead cannot be hand-picked
  insert into suppression (phone_norm, reason) values ((select phone_norm from leads where id = t.lead('W')), 'dnc');
  perform refresh_lead(t.lead('W'));
  perform t.as_user('M');
  perform t.fails(format('select public.list_add_lead(%s, %s)', v_list, t.lead('W')), 'no longer be dialed');
end $$;

\echo '43.4 · The handoff outcome can be corrected (item 46)'
select t.reset() \g /dev/null
do $$
declare att bigint; v_id bigint;
begin
  att := t.dial('A', 'X');
  perform t.log('A', att, 'sale_closed', '{"summary":"sold","rating":5}');
  select id into v_id from handoff_ledger;
  perform t.as_user('M');
  perform public.update_handoff(v_id, 'closed', 'paid in full');
  assert (select outcome = 'closed' and outcome_by = t.uid('M') from handoff_ledger where id = v_id), 'settled';
  perform public.update_handoff(v_id, 'not_closed', 'fell through after all');
  assert (select outcome = 'not_closed' from handoff_ledger where id = v_id), 'and correctable';
  perform t.fails(format('select public.update_handoff(%s, ''maybe'', null)', v_id), 'closed, not_closed');
end $$;

\echo '43.5 · The do-not-call list has a view and a by-hand add (item 46)'
select t.reset() \g /dev/null
do $$
declare r jsonb;
begin
  insert into callbacks (lead_id, agent_id, due_at) values (t.lead('D2'), t.uid('B'), now() + interval '1 hour');
  perform t.as_user('M');
  r := public.add_suppression('(305) 555-0099', 'dnc');
  assert (r->>'leads_suppressed')::int = 2, format('both records of the business go dark: %s', r);
  assert (select status from callbacks where lead_id = t.lead('D2')) = 'cancelled',
    'the promise on it is cancelled';
  assert (select writeback_status from lead_state where lead_id = t.lead('D1')) = 'do_not_call',
    'and the console will hear do-not-call';
  r := public.suppression_list('0099', 10);
  assert jsonb_array_length(r) = 1 and (r->0->'leads') @> '["D1"]'::jsonb,
    format('the view finds it with its lead names: %s', r);
  perform t.fails('select public.add_suppression(''12345'', ''dnc'')', '10-digit');
  perform t.fails('select public.add_suppression(''3055550001'', ''because'')', 'reason');
end $$;

\echo '43.6 · Push back refuses a lead whose agent is on the call right now (item 39)'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  att := t.dial('A', 'X');  -- the tile says dialing, updated seconds ago
  perform t.as_user('M');
  perform t.fails(format('select public.release_lead(%s)', t.lead('X')), 'on this call right now');
  -- the tile goes quiet: now the button does its job
  update agent_status set updated_at = now() - interval '3 minutes' where agent_id = t.uid('A');
  perform t.as_user('M');
  perform public.release_lead(t.lead('X'));
  assert (select state = 'queued' and owner_agent is null from lead_state where lead_id = t.lead('X')),
    'a stuck lead still comes back';
  -- and the agent can always hand back their own call
  perform t.reset();
  att := t.dial('A', 'Y');
  perform t.as_user('A');
  perform public.release_lead(t.lead('Y'));
  assert (select state = 'queued' from lead_state where lead_id = t.lead('Y')), 'their own, mid-call included';
end $$;
\echo 'manager tool tests passed'
