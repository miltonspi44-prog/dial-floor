\set ON_ERROR_STOP 1
set client_min_messages = warning;

\echo '37 · A break or a vote is history too, so removing someone keeps their login'
select t.reset() \g /dev/null
do $$
declare h jsonb;
begin
  -- Nothing on file at all: this is the only shape where a login is deleted outright,
  -- so every table that remembers a person has to be counted here.
  h := public.member_history(t.uid('A'));
  assert not exists (select 1 from jsonb_each(h) e where (e.value)::int > 0),
    format('a fresh agent has nothing on file: %s', h);
end $$;

select t.reset() \g /dev/null
do $$
declare h jsonb;
begin
  -- A break deletes with the person, so it has to count as history or it is lost
  perform t.as_user('A');
  perform public.pause_work('lunch', null);
  perform public.resume_work();
  h := public.member_history(t.uid('A'));
  assert (h->>'breaks')::int = 1, format('a break is on file: %s', h);
  assert exists (select 1 from jsonb_each(h) e where (e.value)::int > 0),
    'so the login is kept rather than deleted';
end $$;

select t.reset() \g /dev/null
do $$
declare att bigint; h jsonb;
begin
  -- a vote for someone else's call deletes with the voter too
  perform t.next('B');
  att := t.dial('B', 'X');
  perform t.log('B', att, 'not_interested_soft');
  perform t.as_user('A');
  perform public.vote_call(att);
  h := public.member_history(t.uid('A'));
  assert (h->>'votes')::int = 1, format('a vote is on file for the voter: %s', h);
end $$;

select t.reset() \g /dev/null
do $$
declare h jsonb;
begin
  -- a power hour someone started, and a referral they took, outlive a delete but are
  -- still theirs: a sprint with nobody who called it is not history worth losing
  perform t.as_user('M');
  perform public.start_sprint('Power hour', 'dials', 30, null);
  h := public.member_history(t.uid('M'));
  assert (h->>'sprints')::int = 1, format('the sprint is on file for the manager who called it: %s', h);
end $$;
