-- 0045: a list by how many times the lead has not picked up.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '54.1 · Not yet dialed, and 1, 2, 3+ dials with nobody ever picking up; a lead someone picked up for is in none'
do $$
begin
  assert public.pickup_bucket(0, 0) = '0' and public.pickup_bucket(1, 0) = '1' and public.pickup_bucket(2, 0) = '2'
     and public.pickup_bucket(3, 0) = '3+' and public.pickup_bucket(9, 0) = '3+', 'the buckets';
  assert public.pickup_bucket(2, 1) is null and public.pickup_bucket(5, 2) is null, 'someone picked up: none of them';
end $$;

\echo '54.2 · The builder counts each option under the other rules, and the list takes only the leads in the options picked'
select t.reset() \g /dev/null
update leads set tier = 'A' where name in ('X', 'Y', 'Z', 'W');
update lead_state set attempts_total = 1 where lead_id = t.lead('X');
update lead_state set attempts_total = 2 where lead_id = t.lead('Y');
update lead_state set attempts_total = 4 where lead_id = t.lead('Z');
update lead_state set attempts_total = 3, connects_total = 1 where lead_id = t.lead('W');   -- picked up once
do $$
declare c jsonb; r jsonb; n0 int;
begin
  n0 := (select count(*) from leads l join lead_state ls on ls.lead_id = l.id
          where ls.state in ('fresh', 'queued') and ls.attempts_total = 0 and l.tier = 'A');
  c := public.builder_counts('{"tier": "A"}');
  assert (select jsonb_object_agg(x->>'key', (x->>'n')::int) from jsonb_array_elements(c->'tries') x)
       = jsonb_build_object('1', 1, '2', 1, '3+', 1) || case when n0 > 0 then jsonb_build_object('0', n0) else '{}'::jsonb end,
    format('one each of 1, 2 and 3+, the rest not yet dialed, and the lead who picked up in none: %s', c->'tries');
  c := public.builder_counts('{"tier": "A", "tries": "3+"}');
  assert (c->>'total')::int = 1, format('3+ is Z alone (4 tries); W picked up once: %s', c);
  assert jsonb_array_length(c->'tries') >= 3, 'and the other options still show their counts';
  perform t.as_user('M');
  r := public.build_list('Tried once or twice', null, '{"tier": "A", "tries": "1, 2"}', 50);
  assert (select array_agg(l.name order by l.name) from list_items li join leads l on l.id = li.lead_id
           where li.list_id = (r->>'list_id')::bigint) = array['X', 'Y'], format('1 and 2: X and Y: %s', r);
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Fresh only', null, '{"tries": "0"}', 50);
  assert not exists (select 1 from list_items li join leads l on l.id = li.lead_id
                      where li.list_id = (r->>'list_id')::bigint and l.name in ('X', 'Y', 'Z', 'W')),
    'not yet dialed leaves out every lead dialed, picked up or not';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  perform t.fails($q$select public.build_list('Bad', null, '{"tries": "four"}', 10)$q$, 'tries: 0 (not yet dialed)');
end $$;

\echo '54.3 · A real dial with no answer moves a lead from not yet dialed to once; a pickup takes it out of every option'
select t.reset() \g /dev/null
do $$
declare att bigint;
begin
  assert public.pickup_bucket((select attempts_total from lead_state where lead_id = t.lead('X')),
                              (select connects_total from lead_state where lead_id = t.lead('X'))) = '0', 'not yet dialed';
  assert t.name(t.next('A')) = 'X';
  att := t.dial('A', 'X');
  perform t.log('A', att, 'no_answer');
  assert (select public.pickup_bucket(attempts_total, connects_total) from lead_state where lead_id = t.lead('X')) = '1',
    'one dial, no pickup';
  assert t.name(t.next('A')) = 'Y';
  att := t.dial('A', 'Y');
  perform t.log('A', att, 'not_interested_soft');
  assert (select public.pickup_bucket(attempts_total, connects_total) from lead_state where lead_id = t.lead('Y')) is null,
    'they picked up: in none of the options';
end $$;

select t.reset() \g /dev/null
update leads set tier = null where name in ('X', 'Y', 'Z', 'W');
