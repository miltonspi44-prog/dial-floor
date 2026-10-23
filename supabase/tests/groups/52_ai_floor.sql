-- 0043: the AI floor. A floor where roofers in New York answer and convert and
-- siding companies in Texas do not, with one agent who wins roofing jobs.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '52.1 · Traits that answer and convert lift a lead; traits that do not, sink it; thin evidence stays near average'
select t.reset() \g /dev/null
insert into leads (source_id, name, phone_norm, phone_display, addr_state, score, review_count, category_key, phone_type, website_type, source) values
  (5201, 'Roof One',   '7185550201', '(718) 555-0201', 'NY', 50, 12, 'roofing', 'mobile', 'none', 'angi'),
  (5202, 'Roof Two',   '7185550202', '(718) 555-0202', 'NY', 50, 12, 'roofing', 'mobile', 'none', 'angi'),
  (5203, 'Side One',   '5125550203', '(512) 555-0203', 'TX', 50, 12, 'siding', 'landline', 'site', 'gmaps'),
  (5204, 'Side Two',   '5125550204', '(512) 555-0204', 'TX', 50, 12, 'siding', 'landline', 'site', 'gmaps'),
  (5205, 'Roof Fresh A', '7185550205', '(718) 555-0205', 'NY', 50, 12, 'roofing', 'mobile', 'none', 'angi'),
  (5206, 'Roof Fresh B', '7185550206', '(718) 555-0206', 'NY', 50, 12, 'roofing', 'mobile', 'none', 'angi'),
  (5207, 'Side Fresh A', '5125550207', '(512) 555-0207', 'TX', 50, 12, 'siding', 'landline', 'site', 'gmaps'),
  (5208, 'Side Fresh B', '5125550208', '(512) 555-0208', 'TX', 50, 12, 'siding', 'landline', 'site', 'gmaps'),
  (5209, 'Odd Trade',  '3055550209', '(305) 555-0209', 'FL', 50, 12, 'chimney', 'mobile', 'none', 'angi');
do $$ begin perform refresh_lead(id) from leads where source_id between 5201 and 5209; end $$;
do $$
declare s jsonb;
begin
  -- roofing: 80 dials, 50 conversations; A wins 8 of their 25, B none of theirs
  for i in 1..25 loop perform t.att('A', case when i % 2 = 0 then 'Roof One' else 'Roof Two' end,
                                    case when i <= 8 then 'chance_website' else 'not_interested_soft' end, true, 90,
                                    null, now() - interval '3 days'); end loop;
  for i in 1..25 loop perform t.att('B', case when i % 2 = 0 then 'Roof One' else 'Roof Two' end, 'not_interested_soft', true, 60,
                                    null, now() - interval '3 days'); end loop;
  for i in 1..30 loop perform t.att('B', 'Roof One', 'no_answer', false, null, null, now() - interval '3 days'); end loop;
  -- siding: 80 dials, 8 conversations, two callbacks
  for i in 1..8 loop perform t.att('B', 'Side One', case when i <= 2 then 'callback' else 'not_interested_soft' end, true, 40,
                                   null, now() - interval '3 days'); end loop;
  for i in 1..72 loop perform t.att('A', case when i % 2 = 0 then 'Side One' else 'Side Two' end, 'no_answer', false, null,
                                    null, now() - interval '3 days'); end loop;

  s := public.ai_score_refresh();
  assert (s->>'dials')::int = 160 and (s->>'convos')::int = 58 and (s->>'wins')::int = 8, format('the model saw the floor: %s', s);
  assert (select answer_lift from ai_features where kind = 'trade' and value = 'roofing') > 1.2, 'roofers answer';
  assert (select answer_lift from ai_features where kind = 'trade' and value = 'siding') < 0.8, 'siding companies do not';
  assert (select win_lift from ai_features where kind = 'trade' and value = 'roofing')
       > (select win_lift from ai_features where kind = 'trade' and value = 'siding'), 'roofers convert better';
  assert (select s.p_answer > t2.p_answer and s.p_win > t2.p_win
            from lead_scores s, lead_scores t2
           where s.lead_id = t.lead('Roof Fresh A') and t2.lead_id = t.lead('Side Fresh A')), 'a fresh roofer outranks a fresh siding lead';
  assert jsonb_array_length((select reasons from lead_scores where lead_id = t.lead('Roof Fresh A'))) between 1 and 3,
    'with its reasons';
  -- a trade never dialed moves only on the traits it shares with the roofers (phone, website, source)
  assert (select s.answer_lift from lead_scores s where s.lead_id = t.lead('Odd Trade'))
       < (select s.answer_lift from lead_scores s where s.lead_id = t.lead('Roof Fresh A'))
     and (select s.answer_lift from lead_scores s where s.lead_id = t.lead('Odd Trade'))
       > (select s.answer_lift from lead_scores s where s.lead_id = t.lead('Side Fresh A')),
    'a trade never dialed lands between: its shared traits lift it, its own trade does not';
  assert not exists (select 1 from lead_scores s join lead_state ls on ls.lead_id = s.lead_id where ls.state in ('suppressed', 'handoff')),
    'nothing out of play is scored';
end $$;

\echo '52.2 · Each agent''s record, overall and by trade, and the match it makes'
do $$
begin
  assert (select lift from ai_agent_fit where agent_id = t.uid('A') and kind = 'all')
       > (select lift from ai_agent_fit where agent_id = t.uid('B') and kind = 'all'), 'A keeps more conversations alive';
  assert public.ai_agent_mult(t.uid('A'), 'roofing', 'NY') > public.ai_agent_mult(t.uid('B'), 'roofing', 'NY'),
    'A is the better match for a New York roofer';
  assert public.ai_agent_mult(t.uid('A'), 'roofing', 'NY') <= 1.6 and public.ai_agent_mult(t.uid('B'), 'roofing', 'NY') >= 0.6,
    'and the match is bounded';
  assert public.ai_agent_mult('99999999-0000-0000-0000-000000000099', 'roofing', 'NY') = 1, 'a new agent is average';
end $$;

\echo '52.3 · The radar deals the likeliest wins to the agent likeliest to convert them; with matching off, round-robin as before'
update app_settings set value = '2' where key = 'radar_deal_per_agent';
update lead_state set state = 'queued', rest_until = null, reserved_by = null, reserved_until = null;
do $$
declare r jsonb; la bigint; lb bigint;
begin
  perform t.as_user('M');
  r := public.radar_deal_now();
  assert (r->>'matched')::boolean and jsonb_array_length(r->'dealt') = 2, format('a matched deal: %s', r);
  la := (select id from lists where kind = 'radar' and agent_id = t.uid('A'));
  lb := (select id from lists where kind = 'radar' and agent_id = t.uid('B'));
  assert (select count(*) from list_items where list_id = la) = 2 and (select count(*) from list_items where list_id = lb) = 2, 'two each';
  assert (select l.category_key from list_items li join leads l on l.id = li.lead_id where li.list_id = la and li.position = 1) = 'roofing',
    'A''s first lead is a roofer';
  assert (select (rules->>'ai')::boolean from lists where id = la), 'the list says it was matched';
  assert (select max(s.p_win) from list_items li join lead_scores s on s.lead_id = li.lead_id where li.list_id = la)
       = (select max(s.p_win) from list_items li join lead_scores s on s.lead_id = li.lead_id where li.list_id in (la, lb)),
    'the single likeliest win went to the better match';
  update lists set status = 'archived' where kind = 'radar';
  update app_settings set value = value || '{"match": false}' where key = 'ai';
  r := public.radar_deal_now();
  assert not (r->>'matched')::boolean, format('matching off: %s', r);
  update lists set status = 'archived' where kind = 'radar';
  update app_settings set value = value || '{"match": true}' where key = 'ai';
end $$;
update app_settings set value = '100' where key = 'radar_deal_per_agent';

\echo '52.4 · A list built in AI order puts the likeliest wins first, and a short list takes the top of its order'
do $$
declare r jsonb;
begin
  perform t.as_user('M');
  r := public.build_list('AI first', null, '{"ai_order": true}', 3);
  assert (select l.category_key from list_items li join leads l on l.id = li.lead_id
           where li.list_id = (r->>'list_id')::bigint and li.position = 1) = 'roofing', 'a roofer leads the AI list';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('Top two by score', null, '{}', 2);
  assert (select array_agg(l.name order by li.position) from list_items li join leads l on l.id = li.lead_id
           where li.list_id = (r->>'list_id')::bigint) = array['X', 'Y'], 'the two best scores, not two arbitrary rows';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
end $$;

\echo '52.5 · Managers see the analysis; agents see only their lead''s score; the raw snapshot stays with the server'
set role authenticated;
do $$
declare f jsonb; q jsonb;
begin
  perform t.as_user('M');
  f := public.ai_floor();
  assert f ? 'model' and f ? 'segments' and f ? 'agents' and f ? 'pool' and f ? 'top_leads' and f ? 'settings',
    format('the AI page has its parts: %s', (select string_agg(k, ',') from jsonb_object_keys(f) k));
  assert (f->'top_leads'->0->>'trade') = 'roofing', 'the likeliest lead to call is a roofer';
  assert (f->'segments'->'trade') is not null, 'trades are analysed';
  q := public.ai_brief_request();
  assert not (q->>'ok')::boolean and q->>'why' like '%no scheduler%', format('without pg_net the request says so: %s', q);
  q := public.ai_brief_request();
  assert q->>'why' like '%under two minutes%', 'and a second ask inside two minutes waits';
  perform t.fails('select public.ai_floor_snapshot()', 'permission denied');
  perform t.fails('select public.ai_score_refresh()', 'permission denied');
  perform t.as_user('A');
  assert (select count(*) from lead_scores) > 0, 'an agent reads lead scores (the Dial page shows one)';
  assert (select count(*) from ai_agent_fit) = 0 and (select count(*) from ai_features) = 0, 'but not the floor''s records';
  perform t.fails('select public.ai_floor()', 'manager only');
  perform t.fails('select public.ai_brief_request()', 'manager only');
end $$;
reset role;
delete from app_settings where key = 'ai_brief_requested';
select 1 where exists (select 1 from jsonb_array_elements(public.settings_registry()) x where x->>'key' = 'ai') \g /dev/null

-- clean up
select t.reset() \g /dev/null
do $$ begin
  delete from lead_scores where lead_id in (select id from leads where source_id between 5201 and 5209);
  delete from lead_intents where lead_id in (select id from leads where source_id between 5201 and 5209);
  delete from lead_state where lead_id in (select id from leads where source_id between 5201 and 5209);
  delete from leads where source_id between 5201 and 5209;
end $$;
