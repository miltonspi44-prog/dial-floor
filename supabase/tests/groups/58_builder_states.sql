-- 0050: the list builder offers every state the scraper has leads in.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

select t.reset() \g /dev/null
update leads set tier = 'B';
insert into leads (source_id, name, phone_norm, phone_display, addr_state, category_key, source, tier) values
  (5801, 'Portland Roofing',   '5035550801', '(503) 555-0801', 'OR', 'roofing',  'angi',     'A'),
  (5802, 'Tulsa Concrete',     '9185550802', '(918) 555-0802', 'OK', 'concrete', 'registry', 'A'),
  (5803, 'Capitol Painting',   '9995550803', '(999) 555-0803', 'DC', 'painting', 'yelp',     'A'),
  (5804, 'Miami Roofing',      '3055550804', '(305) 555-0804', 'FL', 'roofing',  'angi',     'A'),
  (5805, 'Tampa Roofing',      '8135550805', '(813) 555-0805', 'FL', 'roofing',  'yelp',     'A'),
  (5806, 'Salem Roofing',      '9715550806', '(971) 555-0806', 'OR', 'roofing',  'angi',     'A');
do $$ begin perform refresh_lead(id) from leads where source_id between 5801 and 5806; end $$;
-- one Oregon lead's number is on the do-not-call list: it is in no menu
insert into suppression (phone_norm, reason) values ('9715550806', 'dnc');
do $$ begin perform refresh_lead(id) from leads where source_id = 5806; end $$;
-- the Tulsa lead has been tried once with nobody picking up
update lead_state set attempts_total = 1 where lead_id = (select id from leads where source_id = 5802);

\echo '58.1 · The State menu is every state with leads, counted under the other rules, picked state or not'
do $$
declare c jsonb; states jsonb;
begin
  c := public.builder_counts('{"tier": "A"}');
  states := (select jsonb_agg(x order by x->>'key') from jsonb_array_elements(c->'states') x);
  assert c->'states' = states, 'in alphabetical order';
  assert (select jsonb_object_agg(x->>'key', (x->>'n')::int) from jsonb_array_elements(c->'states') x)
       = '{"DC": 1, "FL": 2, "OK": 1, "OR": 1}'::jsonb,
    format('Oregon, Oklahoma and DC are offered beside Florida; the do-not-call Oregon lead is not counted: %s', c->'states');
  -- picking a state narrows everything else, not the State menu itself
  c := public.builder_counts('{"tier": "A", "state": "OR"}');
  assert (c->>'total')::int = 1 and jsonb_array_length(c->'states') = 4, format('Oregon picked: one lead, still four states on offer: %s', c);
  -- the other rules narrow it
  c := public.builder_counts('{"tier": "A", "category": "roofing"}');
  assert (select jsonb_object_agg(x->>'key', (x->>'n')::int) from jsonb_array_elements(c->'states') x) = '{"FL": 2, "OR": 1}'::jsonb,
    format('roofers: Florida and Oregon: %s', c->'states');
  c := public.builder_counts('{"tier": "A", "source": "yelp"}');
  assert (select jsonb_object_agg(x->>'key', (x->>'n')::int) from jsonb_array_elements(c->'states') x) = '{"DC": 1, "FL": 1}'::jsonb,
    format('from Yelp: DC and Florida: %s', c->'states');
  c := public.builder_counts('{"tier": "A", "tries": "1"}');
  assert (select jsonb_object_agg(x->>'key', (x->>'n')::int) from jsonb_array_elements(c->'states') x) = '{"OK": 1}'::jsonb,
    format('tried once, nobody picked up: Oklahoma: %s', c->'states');
  -- the rest of the counts are as they were
  c := public.builder_counts('{"tier": "A"}');
  assert (c->>'total')::int = 5 and c ? 'trades' and c ? 'sources' and c ? 'tries', format('trades, sources, pickups and the total as before: %s', c);
end $$;

\echo '58.2 · A list can be built in a newly offered state; DC knows its own clock'
do $$
declare r jsonb;
begin
  perform t.as_user('M');
  r := public.build_list('Oklahoma', null, '{"tier": "A", "state": "OK"}', 50);
  assert (select array_agg(l.name) from list_items li join leads l on l.id = li.lead_id where li.list_id = (r->>'list_id')::bigint)
       = array['Tulsa Concrete'], format('the Oklahoma lead, and only it: %s', r);
  assert (select tz from state_tz where state = 'DC') = 'America/New_York', 'DC has a row';
  -- 999 is no area code anyone knows, so the state is what tells the lead's clock
  assert (select tz from leads where source_id = 5803) = 'America/New_York', 'the DC lead on an unknown area code is on Eastern time';
end $$;

select t.reset() \g /dev/null
do $$ begin
  delete from suppression where phone_norm = '9715550806';
  delete from list_items where lead_id in (select id from leads where source_id between 5801 and 5806);
  delete from lead_intents where lead_id in (select id from leads where source_id between 5801 and 5806);
  delete from lead_state where lead_id in (select id from leads where source_id between 5801 and 5806);
  delete from leads where source_id between 5801 and 5806;
end $$;
