\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '42.1 · A language barrier flags the lead for lists, and the flag survives a refresh (item 30)'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  perform t.next('A');
  att := t.dial('A', 'X');
  perform t.log('A', att, 'language_barrier');
  assert exists (select 1 from lead_intents
                  where lead_id = t.lead('X') and intent_key = 'language_barrier' and source = 'manual'),
    'the call flags the lead';
  perform refresh_lead(t.lead('X'));
  assert exists (select 1 from lead_intents
                  where lead_id = t.lead('X') and intent_key = 'language_barrier'),
    'and the sync''s refresh does not wash it off';
  assert exists (select 1 from intents_catalog where key = 'language_barrier'),
    'the catalog knows the flag, so the list builder can filter on it';
end $$;

\echo '42.2 · The tile can say dialing and on_call again after a reload, and offline on sign-out (item 32)'
select t.reset() \g /dev/null
do $$
begin
  perform t.as_user('A');
  perform public.heartbeat('on_call');
  assert (select status from agent_status where agent_id = t.uid('A')) = 'on_call', 'mid-call says so';
  perform public.heartbeat('offline');
  assert (select status from agent_status where agent_id = t.uid('A')) = 'offline', 'signed out says so';
  perform t.fails('select public.heartbeat(''gone_fishing'')', 'bad status');
end $$;
\echo 'dial tests passed'
