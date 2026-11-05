-- 0044: teaching the AI floor. Roofers in New York and Florida, siding in Texas;
-- the manager teaches it about Florida roofers, judges single leads, corrects
-- its analysis, talks to it, and reviews where it went wrong.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

select t.reset() \g /dev/null
insert into leads (source_id, name, phone_norm, phone_display, addr_state, score, review_count, category_key, phone_type, website_type, source, tier) values
  (5301, 'NY Roof Hist',  '7185550301', '(718) 555-0301', 'NY', 50, 12, 'roofing',        'mobile',   'none', 'angi',  'A'),
  (5302, 'TX Side Hist',  '5125550302', '(512) 555-0302', 'TX', 50, 12, 'siding',         'landline', 'site', 'gmaps', 'B'),
  (5303, 'FL Roof Fresh', '3055550303', '(305) 555-0303', 'FL', 50, 12, 'roofing,siding', 'mobile',   'none', 'angi',  'A'),
  (5304, 'NY Roof Fresh', '7185550304', '(718) 555-0304', 'NY', 50, 12, 'roofing',        'mobile',   'none', 'angi',  'A'),
  (5305, 'TX Side Fresh', '5125550305', '(512) 555-0305', 'TX', 50, 0,  'siding',         'landline', 'site', 'gmaps', 'B'),
  (5306, 'FL Roof Hist',  '3055550306', '(305) 555-0306', 'FL', 50, 12, 'roofing',        'mobile',   'none', 'angi',  'A');
do $$ begin perform refresh_lead(id) from leads where source_id between 5301 and 5306; end $$;
do $$
begin
  -- roofers: plenty of conversations and some wins; siding: little of either
  for i in 1..30 loop perform t.att('A', 'NY Roof Hist', case when i <= 4 then 'chance_website' else 'not_interested_soft' end,
                                    true, 90, null, now() - interval '5 days'); end loop;
  for i in 1..30 loop perform t.att('B', 'TX Side Hist', case when i <= 3 then 'not_interested_soft' else 'no_answer' end,
                                    i <= 3, null, null, now() - interval '5 days'); end loop;
  for i in 1..10 loop perform t.att('B', 'FL Roof Hist', 'not_interested_soft', true, 60, null, now() - interval '5 days'); end loop;
  perform public.ai_score_refresh();
end $$;

\echo '53.1 · A lesson is checked and tidied; a lesson''s traits match a lead exactly as the model sees it'
do $$
declare r jsonb; l leads; k record;
begin
  perform t.as_user('M');
  r := public.ai_lesson_save(null, '{"trade": " Roofing, siding ", "state": "fl"}', 2, 1, 'Storm season: Florida roofers buy');
  assert r->'conditions' = '{"state": "FL", "trade": "roofing,siding"}'::jsonb, format('tidied: %s', r->'conditions');
  perform t.fails($q$select public.ai_lesson_save(null, '{"city": "Miami"}', 2, 1, 'why not')$q$, 'cannot use the trait');
  perform t.fails($q$select public.ai_lesson_save(null, '{"state": "Florida"}', 2, 1, 'why not')$q$, 'is not a state');
  perform t.fails($q$select public.ai_lesson_save(null, '{}', 2, 1, 'why not')$q$, 'at least one trait');
  perform t.fails($q$select public.ai_lesson_save(null, '{"state": "FL"}', 2, 1, 'no')$q$, 'say why');
  perform t.fails($q$select public.ai_lesson_save(null, '{"state": "FL"}', 1, 1, 'nothing changes')$q$, 'has to change something');
  perform t.fails($q$select public.ai_lesson_save(null, '{"state": "FL"}', 9, 1, 'far too much')$q$, 'between 0.05');
  -- every trait the model gives a lead is one a lesson can name and match
  for l in select * from leads where source_id between 5301 and 5306 loop
    for k in select * from public.ai_lead_keys(l) loop
      assert public.ai_lesson_match(jsonb_build_object(k.kind, k.value), l), format('%s matches its own %s=%s', l.name, k.kind, k.value);
    end loop;
    assert not public.ai_lesson_match('{"state": "ZZ"}', l), 'and not another state';
  end loop;
  select * into l from leads where name = 'FL Roof Fresh';
  assert public.ai_lesson_match('{"trade": "siding"}', l), 'a trade lesson matches any of a lead''s trades, not only the first';
  assert not public.ai_lesson_match('{"trade": "siding", "state": "TX"}', l), 'every trait must match';
  assert public.ai_lesson_match('{"state": "NY,FL"}', l), 'any of a trait''s values';
  perform t.as_user('A');
  perform t.fails($q$select public.ai_lesson_save(null, '{"state": "FL"}', 2, 1, 'agents cannot')$q$, 'manager only');
end $$;

\echo '53.2 · A lesson multiplies the scores of the leads it fits, leads the reasons, and is checked against the record'
do $$
declare base numeric; other numeric; s jsonb; lid bigint; r jsonb;
begin
  -- the lesson saved above asked for a rescore; the minute job does it
  base := (select p_win from lead_scores where lead_id = t.lead('FL Roof Fresh'));
  other := (select p_win from lead_scores where lead_id = t.lead('NY Roof Fresh'));
  s := public.ai_rescore_tick();
  assert (s->>'ran')::boolean, format('a wanted rescore runs: %s', s);
  assert abs((select p_win from lead_scores where lead_id = t.lead('FL Roof Fresh')) / base - 2) < 0.001, 'the Florida roofer''s chance doubled';
  assert (select p_win from lead_scores where lead_id = t.lead('NY Roof Fresh')) = other, 'the New York roofer is untouched';
  assert (select reasons->0->>'kind' = 'lesson' and reasons->0->>'value' like 'Storm season%'
            from lead_scores where lead_id = t.lead('FL Roof Fresh')), 'the lesson is the first reason';
  lid := (select id from ai_lessons where note like 'Storm season%');
  s := (select stats from ai_lessons where id = lid);
  assert (s->>'leads')::int = (select count(*) from leads l join lead_state ls on ls.lead_id = l.id
                                where ls.state not in ('suppressed', 'handoff')
                                  and public.ai_lesson_match('{"state": "FL", "trade": "roofing,siding"}', l))
     and (s->>'leads')::int >= 2 and (s->>'dials')::int = 10 and (s->>'wins')::int = 0,
    format('it moves every Florida roofer in play, and their record is 10 dials, no wins: %s', s);
  assert not (public.ai_rescore_tick()->>'ran')::boolean, 'nothing wanted, and scored this hour: no rescore';

  perform t.as_user('M');
  r := public.ai_lesson_set(lid, false);
  perform public.ai_rescore_tick();
  assert abs((select p_win from lead_scores where lead_id = t.lead('FL Roof Fresh')) - base) < 0.000001, 'paused, the score is the data''s again';
  assert (select (stats->>'leads')::int from ai_lessons where id = lid) = 0, 'and it moves no lead';
  r := public.ai_lesson_set(lid, true);
  perform public.ai_rescore_tick();
  assert (select p_win from lead_scores where lead_id = t.lead('FL Roof Fresh')) > base, 'resumed';
  assert jsonb_array_length(public.ai_teach()->'lessons') = 1, 'the teach panel lists it';
  r := public.ai_lesson_set(lid, false, true);
  assert jsonb_array_length(public.ai_teach()->'lessons') = 0 and (select removed_at is not null from ai_lessons where id = lid),
    'removed: off the panel, kept on record';
  perform t.fails(format('select public.ai_lesson_set(%s, true)', lid), 'that lesson is gone');
  perform public.ai_rescore_tick();
end $$;

\echo '53.3 · A verdict on one lead: good doubles its chance, bad quarters it, cleared it is the data''s again'
do $$
declare base numeric; r jsonb;
begin
  perform t.as_user('M');
  base := (select p_win from lead_scores where lead_id = t.lead('NY Roof Fresh'));
  r := public.ai_mark_lead(t.lead('NY Roof Fresh'), 'bad', 'Owner hung up on three of us');
  perform public.ai_rescore_tick();
  assert abs((select p_win from lead_scores where lead_id = t.lead('NY Roof Fresh')) / base - 0.25) < 0.001, 'quartered';
  assert (select reasons->0 @> '{"kind": "mark", "value": "bad"}' from lead_scores where lead_id = t.lead('NY Roof Fresh')), 'and says why';
  r := public.ai_mark_lead(t.lead('NY Roof Fresh'), 'good', null);
  perform public.ai_rescore_tick();
  assert abs((select p_win from lead_scores where lead_id = t.lead('NY Roof Fresh')) / base - 2) < 0.001, 'good doubles it';
  r := public.ai_mark_lead(t.lead('NY Roof Fresh'), null, null);
  perform public.ai_rescore_tick();
  assert abs((select p_win from lead_scores where lead_id = t.lead('NY Roof Fresh')) - base) < 0.000001, 'cleared';
  perform t.fails($q$select public.ai_mark_lead(1, 'maybe', null)$q$, 'good or bad');
end $$;

\echo '53.4 · A chance given recorded by hand counts as a win on the lead''s last dial'
do $$
declare before int; after int; r jsonb;
begin
  before := (select count(*) from public.ai_dials(90) where win);
  perform t.as_user('M');
  r := public.record_handoff(t.lead('FL Roof Hist'), 'chance_website', 'called back after the storm', t.uid('B'));
  after := (select count(*) from public.ai_dials(90) where win);
  assert after = before + 1, format('one more win: %s then %s', before, after);
  assert (select d.attempt_id = (select max(a.id) from attempts a where a.lead_id = t.lead('FL Roof Hist'))
            from public.ai_dials(90) d where d.lead_id = t.lead('FL Roof Hist') and d.win), 'on its last dial';
  r := public.ai_score_refresh();
  assert (r->>'wins')::int = 5, format('the model counts it: %s', r);
end $$;

\echo '53.5 · Every dial keeps the score its lead had; the review shows wins rated low and hard noes rated high'
do $$
declare att bigint; r jsonb; rows jsonb; lid bigint;
begin
  att := t.att('B', 'TX Side Fresh', 'not_interested_soft', true, 30);
  assert (select ai_p_win = (select p_win from lead_scores where lead_id = t.lead('TX Side Fresh')) from attempts where id = att),
    'the dial is stamped with the lead''s score';
  perform t.as_user('M');
  -- a siding lead the AI rated low gives a chance; a roofer it rated high says no, hard
  r := public.record_handoff(t.lead('TX Side Fresh'), 'chance_website', null, t.uid('B'));
  lid := (select id from ai_lessons where note like 'Storm season%');
  r := public.ai_lesson_save(null, '{"state": "NY", "trade": "roofing"}', 4, 1, 'New York roofers are the best we have');
  perform public.ai_rescore_tick();
  att := t.att('A', 'NY Roof Fresh', 'not_interested_hard', true, 40);
  r := public.ai_review(30);
  rows := r->'rows';
  assert exists (select 1 from jsonb_array_elements(rows) x where x->>'kind' = 'underrated' and x->>'name' = 'TX Side Fresh'
                   and (x->>'at_dial')::boolean and x->>'outcome' = 'chance_website'),
    format('the siding win it rated low is there: %s', rows);
  assert exists (select 1 from jsonb_array_elements(rows) x where x->>'kind' = 'overrated' and x->>'name' = 'NY Roof Fresh'
                   and x->>'outcome' = 'not_interested_hard' and (x->>'win_x')::numeric >= 2 and x->'traits'->>'state' = 'NY'),
    'the hard no on the roofer it rated high is there, with its traits to teach from';
  assert not exists (select 1 from jsonb_array_elements(rows) x where x->>'name' = 'NY Roof Hist'), 'its fair wins are not mistakes';
  assert jsonb_array_length(r->'calibration') >= 1 and r->>'stamped_since' is not null, format('calibration: %s', r->'calibration');
  assert (select sum((b->>'dials')::int) from jsonb_array_elements(r->'calibration') b) = 2, 'only dials scored before they happened';
  r := public.ai_memory();
  assert jsonb_array_length(r->'misses_30d') >= 2, 'Gemini reads the misses';
  assert r::text not like '%TX Side Fresh%' and r::text not like '%(512)%', 'traits only: no names, no numbers';
end $$;

\echo '53.6 · Corrections: one per finding, the latest word wins, removable; Gemini reads them with the lessons and verdicts'
do $$
declare b bigint; r jsonb; m jsonb;
begin
  insert into ai_briefs (source, ok, model, brief) values ('cron', true, 'gemini-test', '{"headline": "h"}') returning id into b;
  perform t.as_user('M');
  r := public.ai_correct(b, 'Washington leads outperform the floor', 'wrong', 'That was one lucky week');
  r := public.ai_correct(b, 'Washington leads outperform the floor', 'right', null);
  assert (select count(*) from ai_corrections where brief_id = b and removed_at is null) = 1, 'one per finding';
  assert (select verdict from ai_corrections where brief_id = b and removed_at is null) = 'right', 'the latest word';
  r := public.ai_correct(b, 'Remodelers convert best', 'wrong', 'Only in summer');
  perform public.ai_mark_lead(t.lead('NY Roof Fresh'), 'bad', 'Rude owner');
  m := public.ai_memory();
  assert jsonb_array_length(m->'corrections') = 2, format('corrections: %s', m->'corrections');
  assert exists (select 1 from jsonb_array_elements(m->'lessons') x where x->>'why' like 'New York roofers%'), 'lessons';
  assert not exists (select 1 from jsonb_array_elements(m->'lessons') x where x->>'why' like 'Storm season%'), 'not removed ones';
  assert exists (select 1 from jsonb_array_elements(m->'lead_verdicts') x where x->>'why' = 'Rude owner' and x->'traits'->>'trade' = 'roofing'),
    'verdicts with traits';
  perform public.ai_correction_remove((select id from ai_corrections where item = 'Remodelers convert best'));
  assert jsonb_array_length(public.ai_teach()->'corrections') = 1, 'removed';
  perform t.fails(format($q$select public.ai_correct(%s, 'x', 'maybe')$q$, b), 'right or wrong');
end $$;

\echo '53.7 · A conversation: sent, answered (or said why not), one reply at a time, a fresh thread on request'
do $$
declare r jsonb; th jsonb;
begin
  perform t.as_user('M');
  r := public.ai_chat_send('Why are Florida roofers ranked so high?');
  assert not (r->>'ok')::boolean and r->>'why' like '%no scheduler%', format('without pg_net it says so: %s', r);
  th := public.ai_chat_thread();
  assert jsonb_array_length(th->'messages') = 2 and th->'messages'->0->>'role' = 'manager' and th->'messages'->1->>'error' like '%no scheduler%',
    format('the message and why it went nowhere: %s', th);
  assert not (th->>'waiting')::boolean, 'nothing is pending';
  -- a message still waiting for its reply holds the next one back
  insert into ai_chat (thread, role, author, text) values ((th->>'thread')::int, 'manager', t.uid('M'), 'still waiting');
  r := public.ai_chat_send('And Texas?');
  assert r->>'why' like '%still answering%', format('one at a time: %s', r);
  assert (public.ai_chat_thread()->>'waiting')::boolean, 'the thread says a reply is due';
  r := public.ai_chat_send('Start over: what converts best?', true);
  assert (r->>'thread')::int = (th->>'thread')::int + 1, 'a new conversation';
  perform t.fails($q$select public.ai_chat_send('   ')$q$, 'say something');
  perform t.fails(format('select public.ai_chat_send(%L)', repeat('x', 2001)), 'under 2,000');
end $$;

\echo '53.8 · Only managers teach; the machinery stays with the server'
set role authenticated;
do $$
begin
  perform t.as_user('A');
  perform t.fails('select public.ai_teach()', 'manager only');
  perform t.fails('select public.ai_review(30)', 'manager only');
  perform t.fails($q$select public.ai_mark_lead(1, 'good')$q$, 'manager only');
  perform t.fails($q$select public.ai_chat_send('hi')$q$, 'manager only');
  perform t.fails('select public.ai_chat_thread()', 'manager only');
  assert (select count(*) from ai_lessons) = 0 and (select count(*) from ai_chat) = 0 and (select count(*) from ai_lead_marks) = 0,
    'agents read none of it';
  perform t.as_user('M');
  perform t.fails('select public.ai_memory()', 'permission denied');
  perform t.fails('select public.ai_rescore_tick()', 'permission denied');
  perform t.fails('select count(*) from public.ai_dials(90)', 'permission denied');
  assert (select count(*) from ai_lessons) > 0, 'managers read the lessons';
end $$;
reset role;

-- clean up
select t.reset() \g /dev/null
do $$ begin
  update ai_lessons set removed_at = coalesce(removed_at, now()), active = false;
  update ai_lead_marks set verdict = null;
  delete from ai_chat;
  delete from ai_corrections;
  delete from ai_briefs where model = 'gemini-test';
  delete from app_settings where key in ('ai_rescore_wanted', 'ai_brief_requested');
  delete from lead_scores where lead_id in (select id from leads where source_id between 5301 and 5306);
  delete from ai_lead_marks where lead_id in (select id from leads where source_id between 5301 and 5306);
  delete from lead_state where lead_id in (select id from leads where source_id between 5301 and 5306);
  delete from leads where source_id between 5301 and 5306;
end $$;
