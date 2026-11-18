-- 0051: one list, leads from several states.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

select t.reset() \g /dev/null
update leads set tier = 'B';
insert into leads (source_id, name, phone_norm, phone_display, addr_state, category_key, source, tier) values
  (5901, 'LA Roofing',      '2135550901', '(213) 555-0901', 'CA', 'roofing', 'angi', 'A'),
  (5902, 'SF Roofing',      '4155550902', '(415) 555-0902', 'CA', 'roofing', 'yelp', 'A'),
  (5903, 'Seattle Roofing', '2065550903', '(206) 555-0903', 'WA', 'roofing', 'angi', 'A'),
  (5904, 'Portland Siding', '5035550904', '(503) 555-0904', 'OR', 'siding',  'angi', 'A'),
  (5905, 'Austin Roofing',  '5125550905', '(512) 555-0905', 'TX', 'roofing', 'angi', 'A');
do $$ begin perform refresh_lead(id) from leads where source_id between 5901 and 5905; end $$;

\echo '59.1 · California and Washington in one list; the counts agree with what is built'
do $$
declare c jsonb; r jsonb;
begin
  c := public.builder_counts('{"tier": "A", "state": "CA,WA"}');
  assert (c->>'total')::int = 3, format('two in California, one in Washington: %s', c);
  assert jsonb_array_length(c->'states') = 4, 'every state still on offer, so another can be added';
  assert (public.builder_counts('{"tier": "A", "state": " ca , wa "}')->>'total')::int = 3, 'spaces and case forgiven';
  perform t.as_user('M');
  r := public.build_list('West coast roofers', null, '{"tier": "A", "state": "CA,WA", "category": "roofing"}', 50);
  assert (select array_agg(l.name order by l.name) from list_items li join leads l on l.id = li.lead_id
           where li.list_id = (r->>'list_id')::bigint) = array['LA Roofing', 'SF Roofing', 'Seattle Roofing'],
    format('both states, roofers only, and nothing from Oregon or Texas: %s', r);
  assert (select rules->>'state' from lists where id = (r->>'list_id')::bigint) = 'CA,WA', 'the list keeps the states it was built from';
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  -- three states, the pickups counted under them
  assert (public.builder_counts('{"tier": "A", "state": "CA,WA,OR"}')->>'total')::int = 4, 'three states: four leads';
end $$;

\echo '59.2 · One state reads as it always did; a rule that is not state codes is refused'
do $$
declare r jsonb;
begin
  perform t.as_user('M');
  r := public.build_list('Texas', null, '{"tier": "A", "state": "tx"}', 50);
  assert (select array_agg(l.name) from list_items li join leads l on l.id = li.lead_id where li.list_id = (r->>'list_id')::bigint)
       = array['Austin Roofing'], format('one state, lower case as old lists may hold it: %s', r);
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  r := public.build_list('No state rule', null, '{"tier": "A", "state": ""}', 50);
  assert (r->>'count')::int = 5, format('an empty state rule is no rule: %s', r);
  update lists set status = 'done' where id = (r->>'list_id')::bigint;
  perform t.fails($q$select public.build_list('x', null, '{"state": "California"}', 10)$q$, 'two-letter code, or several');
  perform t.fails($q$select public.build_list('x', null, '{"state": "CA,,WA"}', 10)$q$, 'two-letter code, or several');
  perform t.fails($q$select public.build_list('x', null, '{"state": "CA;WA"}', 10)$q$, 'two-letter code, or several');
end $$;

select t.reset() \g /dev/null
do $$ begin
  delete from list_items where lead_id in (select id from leads where source_id between 5901 and 5905);
  delete from lead_intents where lead_id in (select id from leads where source_id between 5901 and 5905);
  delete from lead_state where lead_id in (select id from leads where source_id between 5901 and 5905);
  delete from leads where source_id between 5901 and 5905;
end $$;
