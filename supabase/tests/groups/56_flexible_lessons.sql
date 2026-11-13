-- 0047: lessons that say what the manager means: the calls so far, any number
-- range, more of the business; each past dial judged by the history before it.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

select t.reset() \g /dev/null
insert into leads (source_id, name, phone_norm, phone_display, addr_state, addr_city, score, rating, review_count, category_key, phone_type, website_type, source, tier) values
  (5601, 'Tried Thrice Roofing LLC', '7185550601', '(718) 555-0601', 'NY', 'Brooklyn',  55, 4.6, 30, 'roofing', 'mobile',   'none', 'angi',  'A'),
  (5602, 'Never Called Paving',      '7185550602', '(718) 555-0602', 'NY', 'Queens',    55, 3.9, 8,  'paving',  'mobile',   'none', 'angi',  'A'),
  (5603, 'Picked Up Once Siding',    '5125550603', '(512) 555-0603', 'TX', 'Austin',    70, null, 0, 'siding',  'landline', 'site', 'gmaps', 'B'),
  (5604, 'Soft No Concrete',         '5125550604', '(512) 555-0604', 'TX', 'San Antonio', 40, 5,  60, 'concrete','landline', 'site', 'gmaps', 'B');
do $$ begin perform refresh_lead(id) from leads where source_id between 5601 and 5604; end $$;
insert into lead_intents (lead_id, intent_key) select id, 'owner_mobile' from leads where source_id in (5601, 5602) on conflict do nothing;

do $$
begin
  -- Tried Thrice: three unanswered calls (12, 8 and 4 days ago)
  perform t.att('A', 'Tried Thrice Roofing LLC', 'no_answer', false, null, null, now() - interval '12 days');
  perform t.att('A', 'Tried Thrice Roofing LLC', 'voicemail', false, null, null, now() - interval '8 days');
  perform t.att('A', 'Tried Thrice Roofing LLC', 'no_answer', false, null, null, now() - interval '4 days');
  -- Picked Up Once: a pickup that ended in a callback, then two unanswered
  perform t.att('B', 'Picked Up Once Siding', 'callback', true, 120, null, now() - interval '20 days');
  perform t.att('B', 'Picked Up Once Siding', 'no_answer', false, null, null, now() - interval '10 days');
  perform t.att('B', 'Picked Up Once Siding', 'busy_failed', false, null, null, now() - interval '2 days');
  -- Soft No: picked up once, said no softly yesterday (and a call that never left the dialer)
  perform t.att('B', 'Soft No Concrete', 'not_interested_soft', true, 60, null, now() - interval '1 day');
  perform t.att('B', 'Soft No Concrete', 'not_placed', false, null, null, now() - interval '20 hours');
  -- the counters the dial flow keeps (not_placed is not a dial)
  update lead_state ls set attempts_total = x.n, connects_total = x.c
    from (select lead_id, count(*) filter (where disposition is distinct from 'not_placed') as n,
                 count(*) filter (where connected) as c
            from attempts group by lead_id) x
   where x.lead_id = ls.lead_id;
  update ai_lessons set removed_at = coalesce(removed_at, now()), active = false;
  perform public.ai_score_refresh();
end $$;

\echo '56.1 · Numbers take any range; the old bands still read the same'
do $$
begin
  assert public.ai_in_range(3, '3') and public.ai_in_range(3, '3+') and public.ai_in_range(7, '3+'), 'exactly and at least';
  assert public.ai_in_range(2, '<3') and not public.ai_in_range(3, '<3') and public.ai_in_range(4, '>3'), 'under and over';
  assert public.ai_in_range(4.5, '4-4.5') and not public.ai_in_range(4.6, '4-4.5'), 'a range, both ends in, decimals too';
  assert public.ai_in_range(0, '0,5+') and public.ai_in_range(6, '0,5+') and not public.ai_in_range(2, '0,5+'), 'any of several';
  assert not public.ai_in_range(null, '0+'), 'nothing is in no range';
  -- 0044's bands: 0 · 1-9 · 10-49 · 50+ reviews, <40 · 40-59 · 60-79 · 80+ score
  assert public.ai_in_range(9, '1-9') and public.ai_in_range(50, '50+') and public.ai_in_range(39, '<40') and public.ai_in_range(79, '60-79'),
    'the old bands are ranges';
end $$;

\echo '56.2 · New traits are checked and tidied; a wrong one says how to write it'
do $$
declare c jsonb;
begin
  c := public.ai_clean_conditions('{"attempts": ">= 3", "connects": "0", "last_outcome": "No_Answer, voicemail",
                                     "days_since": "3 to 7", "rating": "<=4.5", "city": " San  Antonio ", "name_has": "LLC",
                                     "intent": "owner_mobile"}');
  assert c = '{"dials": "3+", "pickups": "0", "last_outcome": "no_answer,voicemail", "days_since": "3-7", "rating": "0-4.5",
               "city": "san antonio", "name_has": "llc", "intent": "owner_mobile"}'::jsonb, format('tidied: %s', c);
  assert public.ai_clean_conditions('{"reviews": "1-9,50+", "score": "<40"}') = '{"reviews": "1-9,50+", "score": "<40"}'::jsonb,
    'the old bands pass as they are';
  perform t.fails($q$select public.ai_clean_conditions('{"dials": "three"}')$q$, 'write a number (3), a range (2-4), at least (3+) or under (<3)');
  perform t.fails($q$select public.ai_clean_conditions('{"dials": "2.5"}')$q$, 'is not a range for dials');
  perform t.fails($q$select public.ai_clean_conditions('{"dials": "5-2"}')$q$, 'runs backwards: write 2-5');
  perform t.fails($q$select public.ai_clean_conditions('{"last_outcome": "hung_up"}')$q$, 'is not a last outcome');
  perform t.fails($q$select public.ai_clean_conditions('{"intent": "rich_owner"}')$q$, 'not a lead signal');
  perform t.fails($q$select public.ai_clean_conditions('{"attempts": "3", "dials": "4"}')$q$, 'given twice');
  perform t.fails($q$select public.ai_clean_conditions('{"zodiac": "leo"}')$q$, 'cannot use the trait');
  perform t.fails($q$select public.ai_clean_conditions('{"state":"NY","trade":"roofing","area":"718","phone":"mobile","website":"none",
                                                      "source":"angi","tier":"A","dials":"3+","pickups":"0"}')$q$, 'at most 8 traits');
end $$;

\echo '56.3 · A lead''s calls so far, and the business''s other traits, match as the manager means them'
do $$
declare
  m jsonb := '{}';
  l leads; h record;
begin
  for l in select * from leads where source_id between 5601 and 5604 loop
    select * into h from public.ai_lead_history() x where x.lead_id = l.id;
    m := m || jsonb_build_object(l.name, jsonb_build_object(
      'thrice_no_pickup', public.ai_lesson_match('{"dials": "3+", "pickups": "0"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'never',            public.ai_lesson_match('{"dials": "0"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'never_by_outcome', public.ai_lesson_match('{"last_outcome": "none"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'soft_no_this_week', public.ai_lesson_match('{"last_outcome": "not_interested_soft", "days_since": "<7"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'last_unanswered',  public.ai_lesson_match('{"last_outcome": "no_answer,busy_failed,voicemail"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'picked_up',        public.ai_lesson_match('{"pickups": "1+"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'well_rated',       public.ai_lesson_match('{"rating": "4.5+"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'llc',              public.ai_lesson_match('{"name_has": "llc"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'san_antonio',      public.ai_lesson_match('{"city": "san antonio"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'owner_mobile',     public.ai_lesson_match('{"intent": "owner_mobile"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents),
      'no_reviews',       public.ai_lesson_match('{"reviews": "0"}', l, h.dials, h.pickups, h.last_outcome, h.days, h.intents)));
  end loop;
  assert m = '{
    "Tried Thrice Roofing LLC": {"thrice_no_pickup": true,  "never": false, "never_by_outcome": false, "soft_no_this_week": false,
                                 "last_unanswered": true,  "picked_up": false, "well_rated": true,  "llc": true,
                                 "san_antonio": false, "owner_mobile": true, "no_reviews": false},
    "Never Called Paving":      {"thrice_no_pickup": false, "never": true,  "never_by_outcome": true,  "soft_no_this_week": false,
                                 "last_unanswered": false, "picked_up": false, "well_rated": false, "llc": false,
                                 "san_antonio": false, "owner_mobile": true, "no_reviews": false},
    "Picked Up Once Siding":    {"thrice_no_pickup": false, "never": false, "never_by_outcome": false, "soft_no_this_week": false,
                                 "last_unanswered": true,  "picked_up": true,  "well_rated": false, "llc": false,
                                 "san_antonio": false, "owner_mobile": false, "no_reviews": true},
    "Soft No Concrete":         {"thrice_no_pickup": false, "never": false, "never_by_outcome": false, "soft_no_this_week": true,
                                 "last_unanswered": false, "picked_up": true,  "well_rated": true,  "llc": false,
                                 "san_antonio": true,  "owner_mobile": false, "no_reviews": false}}'::jsonb,
    format('each lead as the manager means it: %s', jsonb_pretty(m));
  -- the two-argument form reads the same history
  select * into l from leads where name = 'Tried Thrice Roofing LLC';
  assert public.ai_lesson_match('{"dials": "3", "last_outcome": "no_answer"}', l), 'the short form knows its calls too';
  select * into h from public.ai_lead_history() x where x.lead_id = (select id from leads where name = 'Soft No Concrete');
  assert h.dials = 1 and h.days = 1, format('a call that never left the dialer is not a call: %s', to_jsonb(h));
end $$;

\echo '56.4 · Each past dial is judged by the lead''s history before it'
do $$
declare r jsonb;
begin
  select jsonb_object_agg(l.name || ' #' || (h.dials_before + 1), jsonb_build_array(h.dials_before, h.pickups_before, h.last_before, h.days_before))
    into r
    from public.ai_dial_history(90) h join attempts a on a.id = h.attempt_id join leads l on l.id = a.lead_id;
  assert r = '{"Tried Thrice Roofing LLC #1": [0, 0, null, null], "Tried Thrice Roofing LLC #2": [1, 0, "no_answer", 4],
               "Tried Thrice Roofing LLC #3": [2, 0, "voicemail", 4],
               "Picked Up Once Siding #1": [0, 0, null, null], "Picked Up Once Siding #2": [1, 1, "callback", 10],
               "Picked Up Once Siding #3": [2, 1, "no_answer", 8], "Soft No Concrete #1": [0, 0, null, null]}'::jsonb,
    format('the history before each dial: %s', jsonb_pretty(r));
end $$;

\echo '56.5 · A call-count lesson moves the scores of the leads it fits now, and is checked on the dials it describes'
do $$
declare base numeric; other numeric; s jsonb; p jsonb; lid bigint;
begin
  base := (select p_win from lead_scores where lead_id = t.lead('Tried Thrice Roofing LLC'));
  other := (select p_win from lead_scores where lead_id = t.lead('Picked Up Once Siding'));
  perform t.as_user('M');
  -- before saving: what it would fit
  p := public.ai_lesson_preview('{"calls": "2+", "connects": "0"}');
  assert p->'conditions' = '{"dials": "2+", "pickups": "0"}'::jsonb and (p->>'leads')::int = 1 and (p->>'dials')::int = 1,
    format('called twice or more, never picked up: one lead now, and one dial (Tried Thrice''s third) in the record: %s', p);
  perform t.fails($q$select public.ai_lesson_preview('{"dials": "lots"}')$q$, 'is not a range for dials');
  lid := (public.ai_lesson_save(null, '{"attempts": "2+", "pickups": "0"}', 0.4, 0.75, 'Two tries and no pickup: they never answer')->>'id')::bigint;
  perform public.ai_rescore_tick();
  assert abs((select p_win from lead_scores where lead_id = t.lead('Tried Thrice Roofing LLC')) / base - 0.4) < 0.001, 'its chance is cut to 0.4×';
  assert (select p_win from lead_scores where lead_id = t.lead('Picked Up Once Siding')) = other, 'a lead that once picked up is untouched';
  s := (select stats from ai_lessons where id = lid);
  assert (s->>'leads')::int = 1 and (s->>'dials')::int = 1, format('it moves one lead now, and describes one past dial: %s', s);

  -- a signal: gathered only when a lesson asks for it
  base := (select p_win from lead_scores where lead_id = t.lead('Never Called Paving'));
  perform public.ai_lesson_save(null, '{"intent": "owner_mobile", "dials": "0"}', 1.5, 1, 'An owner''s mobile, fresh: worth a first call');
  perform public.ai_rescore_tick();
  assert abs((select p_win from lead_scores where lead_id = t.lead('Never Called Paving')) / base - 1.5) < 0.001, 'the fresh owner mobile is up 1.5×';
  perform t.as_user('A');
  perform t.fails($q$select public.ai_lesson_preview('{"dials": "0"}')$q$, 'manager only');
end $$;

-- clean up
select t.reset() \g /dev/null
do $$ begin
  update ai_lessons set removed_at = coalesce(removed_at, now()), active = false;
  delete from app_settings where key = 'ai_rescore_wanted';
  delete from lead_intents where lead_id in (select id from leads where source_id between 5601 and 5604);
  delete from lead_scores where lead_id in (select id from leads where source_id between 5601 and 5604);
  delete from lead_state where lead_id in (select id from leads where source_id between 5601 and 5604);
  delete from leads where source_id between 5601 and 5604;
end $$;
