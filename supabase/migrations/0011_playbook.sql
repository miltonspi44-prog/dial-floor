-- Dial Floor · 0011 playbook (Phase 1.5)
--   · D1 battlecards: tapping a counter records the words the agent used, and
--     battlecard_stats ranks objections and counters by the calls they kept alive
--   · A6 call log (Fork 1-A, metadata only): each call in a lead's history carries
--     the objections heard and the counters used, next to outcome, talk time, note
--   · D5 library: talk tracks and saved calls, managers only
--   · D6 A/B lab: opener variants, one test at a time, behind a lab-wide switch
--     that is off by default (the D6 note: "not the default")

-- a call "kept alive" ended with a next step: a callback, an email, or a W/S handoff
create or replace function public.kept_alive(p_dispo text)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(p_dispo in ('callback', 'email_requested', 'chance_website', 'sale_closed'), false)
$$;

-- ---------------------------------------------------------- battlecards (D1) --
-- counter is null for the objection tap itself
alter table public.card_taps add column if not exists counter text;
create index if not exists card_taps_attempt_idx on public.card_taps (attempt_id);

create or replace function public.battlecard_stats(p_days int default 90)
returns jsonb language sql stable security invoker set search_path = public as $$
  with t as (
    select ct.card_id, ct.attempt_id, ct.counter, a.disposition
      from card_taps ct join attempts a on a.id = ct.attempt_id
     where ct.tapped_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 90), 3650)))
       and a.disposition is not null
  ),
  heard as (  -- one row per call the objection came up in
    select card_id, attempt_id, bool_or(kept_alive(disposition)) as kept,
           bool_or(disposition in ('chance_website', 'sale_closed')) as won
      from t group by card_id, attempt_id
  ),
  used as (   -- one row per call a counter was used in
    select card_id, counter, attempt_id, bool_or(kept_alive(disposition)) as kept,
           bool_or(disposition in ('chance_website', 'sale_closed')) as won
      from t where counter is not null group by card_id, counter, attempt_id
  ),
  per_card as (
    select card_id, count(*) as calls, count(*) filter (where kept) as kept, count(*) filter (where won) as won
      from heard group by card_id
  ),
  per_counter as (
    select card_id, jsonb_agg(jsonb_build_object('text', counter, 'uses', uses, 'kept', kept, 'won', won)
                              order by kept::numeric / uses desc, uses desc, counter) as counters
      from (select card_id, counter, count(*) as uses, count(*) filter (where kept) as kept,
                   count(*) filter (where won) as won
              from used group by card_id, counter) x
     group by card_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'card_id', b.id, 'objection', b.objection, 'active', b.active,
      'calls', coalesce(pc.calls, 0), 'kept', coalesce(pc.kept, 0), 'won', coalesce(pc.won, 0),
      'counters', coalesce(pk.counters, '[]'::jsonb)) order by b.sort, b.id), '[]'::jsonb)
  from battlecards b
  left join per_card pc on pc.card_id = b.id
  left join per_counter pk on pk.card_id = b.id
$$;

-- ----------------------------------------------------------------- A/B lab (D6) --
-- the per-test `enabled` flag is superseded by the lab-wide switch below (still off
-- by default) plus each test's status; one test runs at a time
alter table public.ab_tests drop column if exists enabled;
alter table public.ab_tests
  add column if not exists status text not null default 'draft' check (status in ('draft', 'running', 'stopped')),
  add column if not exists started_at timestamptz,
  add column if not exists stopped_at timestamptz;
alter table public.ab_tests add constraint ab_tests_variants_shape
  check (jsonb_typeof(variants) = 'array' and jsonb_array_length(variants) <= 4);
create unique index if not exists ab_tests_one_running on public.ab_tests (status) where status = 'running';

-- attempts.ab_variant was reserved by the Phase 0 schema; ab_test_id says which test
alter table public.attempts
  add column if not exists ab_test_id bigint references public.ab_tests(id) on delete set null,
  add column if not exists ab_variant text;

insert into public.app_settings (key, value) values ('ab_lab_enabled', 'false') on conflict (key) do nothing;

-- the opener this lead gets from the running test: fixed per lead (a redial shows
-- the same one), null when the lab is off or nothing is running
create or replace function public.ab_opener(p_lead_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t ab_tests%rowtype; n int; v jsonb;
begin
  if not coalesce((public.setting('ab_lab_enabled'))::boolean, false) then return null; end if;
  select * into t from ab_tests where status = 'running' limit 1;
  if not found then return null; end if;
  n := jsonb_array_length(t.variants);
  if n < 2 then return null; end if;
  v := t.variants -> mod(mod(hashtext(t.id::text || ':' || p_lead_id::text)::bigint, n) + n, n)::int;
  return jsonb_build_object('test_id', t.id, 'test', t.name, 'variant', v->>'key', 'text', v->>'text');
end $$;

-- every dial records the opener it was shown (same function the workspace uses)
create or replace function public.attempts_ab_assign()
returns trigger language plpgsql security definer set search_path = public as $$
declare ab jsonb;
begin
  if new.ab_test_id is null then
    ab := ab_opener(new.lead_id);
    if ab is not null then
      new.ab_test_id := (ab->>'test_id')::bigint;
      new.ab_variant := ab->>'variant';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists attempts_ab_assign on public.attempts;
create trigger attempts_ab_assign before insert on public.attempts
  for each row execute function public.attempts_ab_assign();

-- once a test has run, its openers are fixed: results stay tied to the words used
create or replace function public.ab_tests_freeze()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.started_at is not null and new.variants is distinct from old.variants then
    raise exception 'this test has already run: start a new test to change its openers';
  end if;
  return new;
end $$;
drop trigger if exists ab_tests_freeze on public.ab_tests;
create trigger ab_tests_freeze before update on public.ab_tests
  for each row execute function public.ab_tests_freeze();

create or replace function public.ab_set_status(p_test_id bigint, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t ab_tests%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_status not in ('running', 'stopped') then raise exception 'status must be running or stopped'; end if;
  select * into t from ab_tests where id = p_test_id for update;
  if not found then raise exception 'no such test'; end if;
  if p_status = 'running' then
    if jsonb_array_length(t.variants) < 2
       or exists (select 1 from jsonb_array_elements(t.variants) v where btrim(coalesce(v->>'text', '')) = '') then
      raise exception 'a test needs at least two variants, each with an opener';
    end if;
    update ab_tests set status = 'stopped', stopped_at = now() where status = 'running' and id <> p_test_id;
    update ab_tests set status = 'running', started_at = coalesce(started_at, now()), stopped_at = null
      where id = p_test_id;
  else
    update ab_tests set status = 'stopped', stopped_at = now() where id = p_test_id and status = 'running';
  end if;
  return (select to_jsonb(x) from (select id, name, status, started_at, stopped_at from ab_tests where id = p_test_id) x);
end $$;

create or replace function public.ab_results(p_test_id bigint)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare r jsonb;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  select coalesce(jsonb_agg(x order by x->>'variant'), '[]'::jsonb) into r from (
    select jsonb_build_object('variant', a.ab_variant,
      'dials', count(*),
      'picked_up', count(*) filter (where a.call_result = 'answered' or coalesce(a.connected, false)),
      'conversations', count(*) filter (where a.connected),
      'survived_30s', count(*) filter (where a.connected and a.duration_seconds >= 30),
      'kept', count(*) filter (where kept_alive(a.disposition)),
      'won', count(*) filter (where a.disposition in ('chance_website', 'sale_closed'))) as x
      from attempts a where a.ab_test_id = p_test_id
     group by a.ab_variant) s;
  return r;
end $$;

-- ---------------------------------------------------------------- library (D5) --
create table if not exists public.library_items (
  id bigint generated always as identity primary key,
  title text not null check (length(btrim(title)) > 0),
  scenario text not null default 'Other',
  body text not null default '',
  attempt_id bigint references public.attempts(id) on delete set null,
  lead_name text,
  agent_name text,
  pinned boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.library_items enable row level security;
-- managers only, reading included (the D5 note)
create policy library_manager on public.library_items
  for all to authenticated using (public.is_manager()) with check (public.is_manager());

-- ------------------------------------------------------------ build_workspace --
-- + taps per call (A6) and the opener under test (D6)
create or replace function public.build_workspace(p_lead_id bigint, p_reason text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l jsonb; st jsonb; ints jsonb; hist jsonb; ab jsonb;
begin
  select to_jsonb(x) into l from (select * from leads where id = p_lead_id) x;
  select to_jsonb(x) into st from (select * from lead_state where lead_id = p_lead_id) x;
  select coalesce(jsonb_agg(jsonb_build_object('key', li.intent_key, 'label', ic.label, 'confidence', li.confidence) order by ic.priority), '[]')
    into ints
    from lead_intents li join intents_catalog ic on ic.key = li.intent_key
    where li.lead_id = p_lead_id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'at', a.clicked_at, 'agent', p.name, 'disposition', a.disposition,
      'duration', a.duration_seconds, 'note', a.note,
      'ai_summary', a.ai_summary->>'summary', 'next_steps', a.ai_summary->>'next_steps',
      'taps', (select coalesce(jsonb_agg(jsonb_build_object('objection', x.objection, 'counters', x.counters)
                                         order by x.objection), '[]'::jsonb)
                 from (select b.objection,
                              coalesce(jsonb_agg(distinct ct.counter) filter (where ct.counter is not null), '[]'::jsonb) as counters
                         from card_taps ct join battlecards b on b.id = ct.card_id
                        where ct.attempt_id = a.id
                        group by b.objection) x)) order by a.clicked_at desc), '[]')
    into hist
    from (select * from attempts where lead_id = p_lead_id order by clicked_at desc limit 5) a
    join profiles p on p.id = a.agent_id;
  ab := ab_opener(p_lead_id);
  return jsonb_build_object('reason', p_reason, 'lead', l, 'state', st, 'intents', ints, 'history', hist)
      || case when ab is null then '{}'::jsonb else jsonb_build_object('ab', ab) end;
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.battlecard_stats(int), public.ab_set_status(bigint, text),
  public.ab_results(bigint), public.kept_alive(text) from public, anon;
grant execute on function public.battlecard_stats(int), public.ab_set_status(bigint, text),
  public.ab_results(bigint), public.kept_alive(text) to authenticated;
revoke execute on function public.ab_opener(bigint), public.attempts_ab_assign(), public.ab_tests_freeze()
  from public, anon, authenticated;
