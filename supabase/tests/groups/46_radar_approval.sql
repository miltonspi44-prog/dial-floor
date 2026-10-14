-- 0037: radar lists wait for a manager's approval. The radar proposes, a person
-- approves, and no agent is dealt a second list while one of theirs is waiting
-- for approval or still being dialed.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

-- An item is served when its lead is dialed (start_attempt), so "dialed through"
-- means every lead on the list was called. This dials what is left on a list,
-- as no-answers, waiving the redial gap: the cooling-off is not what is under test.
create or replace function t.dial_list(p text, p_list bigint) returns int language plpgsql as $$
declare r record; n int := 0; att bigint;
begin
  for r in select li.lead_id, l.name from list_items li join leads l on l.id = li.lead_id
            where li.list_id = p_list and li.served_at is null order by li.position loop
    update lead_state set last_attempt_at = null, attempts_today = 0, attempts_today_date = null, rest_until = null,
                          reserved_by = null, reserved_until = null
     where lead_id = r.lead_id;
    att := t.dial(p, r.name);
    perform t.log(p, att, 'no_answer');
    n := n + 1;
  end loop;
  return n;
end $$;

\echo '46.1 · The radar proposes; nothing is served from a proposal until a manager approves it'
select t.reset() \g /dev/null
update app_settings set value = '2' where key = 'radar_deal_per_agent';
delete from app_settings where key = 'radar_last_run';
-- the twin records (one number, two leads) sit this one out: four leads, two agents, two each
update lead_state set rest_until = now() + interval '30 days' where lead_id in (t.lead('D1'), t.lead('D2'));
do $$
declare r jsonb; la bigint; lb bigint; n jsonb; a jsonb; att bigint;
begin
  perform t.as_user('A');
  r := public.radar_daily();
  assert (r->>'ran')::boolean and (r->>'lists')::int = 2,
    format('the morning run proposes a list for each of the two active agents: %s', r);
  la := (select id from lists where kind = 'radar' and agent_id = t.uid('A'));
  lb := (select id from lists where kind = 'radar' and agent_id = t.uid('B'));
  assert (select status from lists where id = la) = 'draft' and (select status from lists where id = lb) = 'draft',
    'a proposal is a draft';
  assert (select count(*) from list_items where list_id = la) = 2, 'with its leads on it';
  n := t.next('A');
  assert n->>'reason' <> 'list', format('A is not served from a proposal: %s', n->>'reason');
  perform t.fails(format('select public.approve_list(%s)', la), 'manager only');
  perform t.as_user('M');
  a := public.approve_list(la);
  assert (a->>'count')::int = 2 and (a->>'left')::int = 2, format('approved: %s', a);
  assert (select status from lists where id = la) = 'active'
     and (select approved_by from lists where id = la) = t.uid('M')
     and (select approved_at from lists where id = la) is not null, 'approved, by whom and when';
  perform t.fails(format('select public.approve_list(%s)', la), 'waiting for approval');
  n := t.next('A');
  assert n->>'reason' = 'list', format('approved, A is served from it: %s', n->>'reason');
  att := t.dial('A', t.name(n));
  perform t.log('A', att, 'no_answer');
  assert (select served_at from list_items where list_id = la and lead_id = t.lead(t.name(n))) is not null,
    'and dialing it marks the item served';
end $$;

\echo '46.2 · No new list while one is waiting or being dialed; a list dialed through closes itself and frees its agent'
update app_settings set value = jsonb_set(value, '{date}', to_jsonb((business_date() - 1)::text)) where key = 'radar_last_run';
do $$
declare la bigint; r jsonb; n jsonb; att bigint;
begin
  la := (select id from lists where kind = 'radar' and agent_id = t.uid('A') and status = 'active');
  perform t.as_user('B');
  r := public.radar_daily();
  assert (r->>'ran')::boolean and (r->>'lists')::int = 0,
    format('a new day runs the radar, but A is still dialing and B is still waiting, so nothing new is proposed: %s', r);
  assert (select count(*) from lists where kind = 'radar') = 2, 'the two lists stand';
  assert public.list_outstanding(la) = 1, 'one lead left on A''s list';
  n := t.next('A');
  assert n->>'reason' = 'list', format('the second lead comes off the list: %s', n->>'reason');
  att := t.dial('A', t.name(n));
  perform t.log('A', att, 'no_answer');
  assert public.list_outstanding(la) = 0, 'dialed, nothing is left on it';
  n := t.next('A');
  assert coalesce(n->>'reason', '') <> 'list', format('and then the pool: %s', n->>'reason');
  perform t.as_user('M');
  r := public.radar_deal_now();
  assert (r->>'closed')::int = 1 and (select status from lists where id = la) = 'done',
    format('the list dialed through closes itself: %s', r);
  assert jsonb_array_length(r->'dealt') = 1 and (r->'dealt'->0->>'agent_id')::uuid = t.uid('A')
     and r->'dealt'->0->>'status' = 'draft',
    format('A, free again, is proposed a fresh list; B, still waiting, is not: %s', r);
  assert (select count(*) from lists where kind = 'radar' and agent_id = t.uid('B')) = 1, 'B has the one proposal';
end $$;

\echo '46.3 · A proposal holds its leads: the next proposal and a list built by hand leave them alone'
do $$
declare lb bigint; la2 bigint; v_list bigint;
begin
  lb := (select id from lists where kind = 'radar' and agent_id = t.uid('B') and status = 'draft');
  la2 := (select id from lists where kind = 'radar' and agent_id = t.uid('A') and status = 'draft');
  assert not exists (select 1 from list_items x join list_items y on y.lead_id = x.lead_id where x.list_id = lb and y.list_id = la2),
    'no lead sits on two proposals';
  assert not exists (select 1 from public.radar_rank() rr join list_items li on li.lead_id = rr.lead_id where li.list_id in (lb, la2)),
    'the ranking leaves proposed leads out';
  perform t.as_user('M');
  v_list := (public.build_list('By hand', null, '{}', 50)->>'list_id')::bigint;
  assert not exists (select 1 from list_items x join list_items y on y.lead_id = x.lead_id where x.list_id = v_list and y.list_id in (lb, la2)),
    'a list built by hand leaves them alone too';
  update lists set status = 'done' where id = v_list;
end $$;

\echo '46.4 · Discarding a proposal frees its leads and its agent; a second list is not approved over one still being dialed'
do $$
declare lb bigint; la2 bigint; lb2 bigint; r jsonb;
begin
  lb := (select id from lists where kind = 'radar' and agent_id = t.uid('B') and status = 'draft');
  la2 := (select id from lists where kind = 'radar' and agent_id = t.uid('A') and status = 'draft');
  perform t.as_user('M');
  update lists set status = 'archived' where id = lb;  -- discard, as the Lists page does it
  assert exists (select 1 from public.radar_rank() rr join list_items li on li.lead_id = rr.lead_id where li.list_id = lb),
    'its leads are back in the ranking';
  r := public.radar_deal_now();
  assert jsonb_array_length(r->'dealt') = 1 and (r->'dealt'->0->>'agent_id')::uuid = t.uid('B'),
    format('B is proposed a fresh list: %s', r);
  lb2 := (r->'dealt'->0->>'list_id')::bigint;
  -- the manager moves B's proposal to A, who has one waiting too: one at a time
  perform public.set_list_agent(lb2, t.uid('A'));
  perform public.approve_list(la2);
  perform t.fails(format('select public.approve_list(%s)', lb2), 'close that list first');
  assert t.dial_list('A', la2) = 2, 'A dials the first one through';
  assert public.list_outstanding(la2) = 0, 'nothing left on it';
  perform t.as_user('M');
  perform public.approve_list(lb2);
  assert (select status from lists where id = lb2) = 'active', 'and the next one can be approved';
end $$;

\echo '46.5 · The Floor tells managers a proposal is waiting; the Radar card shows every list in play and what is left'
do $$
declare r jsonb;
begin
  perform t.as_user('M');
  r := public.radar_deal_now();
  assert jsonb_array_length(r->'dealt') = 1 and (r->'dealt'->0->>'agent_id')::uuid = t.uid('B'),
    format('B, whose proposal moved to A, is proposed another: %s', r);
end $$;
set role authenticated;
do $$
declare lid bigint; a jsonb; r jsonb;
begin
  perform t.as_user('M');
  lid := (select id from lists where kind = 'radar' and agent_id = t.uid('B') and status = 'draft');
  a := public.floor_alerts();
  assert exists (select 1 from jsonb_array_elements(a) x
                  where x->>'kind' = 'radar' and x->>'key' = 'radar:' || lid and x->>'title' like '%waiting for approval'),
    format('the proposal is on the board: %s', a);
  r := public.radar();
  assert exists (select 1 from jsonb_array_elements(r->'lists') x
                  where (x->>'list_id')::bigint = lid and x->>'status' = 'draft' and (x->>'left')::int = 2),
    format('and on the Radar card, with what is left: %s', r->'lists');
  assert exists (select 1 from jsonb_array_elements(r->'lists') x
                  where x->>'status' = 'active' and x->>'approved_by' = (select name from profiles where id = t.uid('M'))),
    'an approved list says who approved it';
  insert into app_settings (key, value) values ('alerts', '{"radar_approvals": false}')
    on conflict (key) do update set value = app_settings.value || excluded.value;
  assert not exists (select 1 from jsonb_array_elements(public.floor_alerts()) x where x->>'kind' = 'radar'),
    'switched off, it says nothing';
  update app_settings set value = value - 'radar_approvals' where key = 'alerts';
  perform t.as_user('A');
  assert not exists (select 1 from jsonb_array_elements(public.floor_alerts()) x where x->>'kind' = 'radar'),
    'manager lines stay with managers';
end $$;
reset role;

\echo '46.6 · Off the floor: the proposal is withdrawn, the approved list shared; a lead gone dead keeps no list open'
do $$
declare lb bigint; la bigint; hb jsonb;
begin
  lb := (select id from lists where kind = 'radar' and agent_id = t.uid('B') and status = 'draft');
  la := (select id from lists where kind = 'radar' and agent_id = t.uid('A') and status = 'active' and public.list_outstanding(id) > 0);
  perform t.as_user('M');
  hb := public.hand_back(t.uid('B'), t.uid('M'));
  assert (hb->>'proposals')::int = 1 and (select status from lists where id = lb) = 'archived',
    format('the proposal is withdrawn: %s', hb);
  assert public.list_outstanding(la) = 2, 'two to dial on A''s list';
  insert into suppression (phone_norm, reason)
    select l.phone_norm, 'dnc' from list_items li join leads l on l.id = li.lead_id
     where li.list_id = la and li.served_at is null order by li.position limit 1;
  perform count(public.refresh_lead(lead_id)) from list_items where list_id = la;
  assert public.list_outstanding(la) = 1, 'the dead lead no longer counts as waiting';
  hb := public.hand_back(t.uid('A'), t.uid('M'));
  assert (select agent_id from lists where id = la) is null and (select status from lists where id = la) = 'active',
    'an approved list stays alive, shared with everyone';
end $$;
select t.reset() \g /dev/null
update app_settings set value = '100' where key = 'radar_deal_per_agent';
