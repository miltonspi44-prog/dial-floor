\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '36 · A write-back the console will never accept stops being retried, and a new status forgets it'
select t.reset() \g /dev/null
do $$
declare v_lead bigint := t.lead('X');
begin
  -- the worker queues a status, the console refuses it for good, and the worker gives
  -- up: done so nothing retries it, with the reason left where a manager can see it
  update lead_state set writeback_status = 'do_not_call', writeback_done = false where lead_id = v_lead;
  update lead_state set writeback_done = true, writeback_failed_at = now(),
                        writeback_error = 'console: no such lead (404)' where lead_id = v_lead;
  assert (select writeback_error is not null and writeback_failed_at is not null
            from lead_state where lead_id = v_lead),
    'the refusal is recorded against the lead';

  -- a later status on the same lead is a fresh promise: the old failure must not cling to it
  update lead_state set writeback_status = 'captured', writeback_done = false where lead_id = v_lead;
  assert (select writeback_error is null and writeback_failed_at is null
            from lead_state where lead_id = v_lead),
    'a new status clears the previous refusal';
end $$;

select t.reset() \g /dev/null
do $$
declare v_lead bigint := t.lead('W');
begin
  -- a different status promised while one is still waiting supersedes it, so the
  -- failure recorded against the older one goes too
  update lead_state set writeback_status = 'not_interested', writeback_done = false,
                        writeback_failed_at = now(), writeback_error = 'console: timeout'
    where lead_id = v_lead;
  update lead_state set writeback_status = 'do_not_call' where lead_id = v_lead;
  assert (select writeback_error is null from lead_state where lead_id = v_lead),
    'a status that supersedes a waiting one clears its failure';
end $$;

select t.reset() \g /dev/null
do $$
declare v_lead bigint := t.lead('Y'); att bigint;
begin
  -- the same must hold when the status comes from an agent's own outcome
  update lead_state set writeback_failed_at = now(), writeback_error = 'console: timeout',
                        writeback_done = true where lead_id = v_lead;
  perform t.next('A');
  att := t.dial('A', 'Y');
  perform t.log('A', att, 'dnc');
  assert (select writeback_status = 'do_not_call' and not writeback_done
            from lead_state where lead_id = v_lead),
    'do-not-call is queued for the console';
  assert (select writeback_error is null and writeback_failed_at is null
            from lead_state where lead_id = v_lead),
    'logging a disposition clears a stale failure too';
end $$;

select t.reset() \g /dev/null
do $$
declare v_lead bigint := t.lead('Z');
begin
  -- and an ordinary write must leave a failure the worker has not resolved alone
  update lead_state set writeback_status = 'do_not_call', writeback_done = true,
                        writeback_failed_at = now(), writeback_error = 'console: no such lead (404)'
    where lead_id = v_lead;
  update lead_state set attempts_total = attempts_total + 1 where lead_id = v_lead;
  assert (select writeback_error is not null from lead_state where lead_id = v_lead),
    'an unrelated write leaves the recorded failure alone';
end $$;
