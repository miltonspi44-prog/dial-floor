-- Dial Floor · 0046 the AI reads everything on the floor
-- Until now Gemini saw only aggregates and traits. Now it can look anything up
-- while it writes an analysis or answers in the conversation: a lead by name or
-- number, its calls and the agents' notes, Zoom's summaries, callbacks, lists,
-- an agent's day, the settings. floor-ai gives it one tool, run_sql, which
-- runs here as ai_sql():
--   · as ai_reader, a role that can SELECT every table and view in public (and
--     any added later), past row security, and nothing else: not the auth schema
--     (logins and passwords), not Vault (the cron secret), not pg_net or pg_cron;
--   · in a read-only transaction, so nothing it runs, or calls, can write;
--   · one SELECT or WITH query, at most 200 rows back.
-- ai_schema() lists what ai_reader can read, for Gemini's instructions.
-- ai_memory (0044) now names the leads in the verdicts and misses as well.
-- Applies through the management API as it is.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'ai_reader') then
    create role ai_reader nologin noinherit bypassrls;
  end if;
end $$;
-- the migrations' owner must be able to hand functions to it and replace them later
grant ai_reader to postgres with inherit true, set true;

grant usage on schema public to ai_reader;
grant select on all tables in schema public to ai_reader;
alter default privileges for role postgres in schema public grant select on tables to ai_reader;

-- ------------------------------------------------------------------- ai_sql --
-- One read query, run as ai_reader in a read-only transaction; its rows as JSON.
create or replace function public.ai_sql(p_sql text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  -- trimmed of any whitespace (line breaks too) and a trailing semicolon
  q text := regexp_replace(regexp_replace(coalesce(p_sql, ''), '^\s+', ''), '[\s;]+$', '');
  v_rows jsonb;
  v_n int;
begin
  if q !~* '^(select|with)\M' then
    raise exception 'run_sql takes one read query, starting with SELECT or WITH';
  end if;
  -- nothing it runs can write, whatever it calls
  perform set_config('transaction_read_only', 'on', true);
  execute format('select coalesce(jsonb_agg(to_jsonb(r)), ''[]''::jsonb), count(*) from (select * from (%s) q limit 201) r', q)
    into v_rows, v_n;
  return jsonb_build_object('rows', case when v_n > 200 then v_rows - 200 else v_rows end,
                            'count', least(v_n, 200), 'truncated', v_n > 200);
end $$;

-- ---------------------------------------------------------------- ai_schema --
-- Every table and view ai_reader can read, one line each: name(column type, ...).
create or replace function public.ai_schema()
returns text language sql stable security definer set search_path = public as $$
  select string_agg(t.line, E'\n' order by t.tbl)
    from (select c.table_name as tbl,
                 c.table_name || '(' || string_agg(c.column_name || ' ' || c.udt_name, ', ' order by c.ordinal_position) || ')' as line
            from information_schema.columns c
           where c.table_schema = 'public'
           group by c.table_name) t
$$;

revoke execute on function public.ai_sql(text), public.ai_schema() from public, anon, authenticated;
grant execute on function public.ai_sql(text), public.ai_schema() to service_role;
-- A function's new owner must be able to create in its schema, unless a
-- superuser hands it over (Supabase's postgres isn't one): ai_reader may for
-- the hand-over only, and keeps nothing but the two functions.
grant create on schema public to ai_reader;
alter function public.ai_sql(text) owner to ai_reader;
alter function public.ai_schema() owner to ai_reader;
revoke create on schema public from ai_reader;

-- ------------------------------------------------------------------- memory --
-- (0044's, naming the leads: Gemini can now look any of them up)
create or replace function public.ai_memory()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'effects', 'a lesson multiplies the chance of a win by win_x and of a pickup by pickup_x for every lead with all its traits',
    'lessons', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'traits', s.conditions, 'win_x', s.win_mult, 'pickup_x', s.answer_mult, 'why', s.note,
        'active', s.active, 'taught', s.created_at::date, 'from', s.source,
        'leads_it_moves_now', s.stats->'leads',
        'record_90d', jsonb_build_object('dials', s.stats->'dials', 'convos', s.stats->'convos', 'wins', s.stats->'wins',
                                         'win_lift', s.stats->'win_lift', 'answer_lift', s.stats->'answer_lift')) order by s.id)
       from ai_lessons s where s.removed_at is null), '[]'::jsonb),
    'lead_verdicts', coalesce((select jsonb_agg(jsonb_build_object(
        'lead_id', l.id, 'name', l.name, 'verdict', mk.verdict, 'why', mk.note, 'marked', mk.marked_at::date,
        'traits', (select jsonb_object_agg(k.kind, k.value) from public.ai_lead_keys(l) k),
        'last_outcome', (select a.disposition from attempts a where a.lead_id = l.id and a.disposition is not null
                          order by a.clicked_at desc limit 1),
        'won', exists (select 1 from handoff_ledger h where h.lead_id = l.id)) order by mk.marked_at desc)
       from (select * from ai_lead_marks where verdict is not null order by marked_at desc limit 40) mk
       join leads l on l.id = mk.lead_id), '[]'::jsonb),
    'corrections', coalesce((select jsonb_agg(jsonb_build_object('about', c.item, 'verdict', c.verdict, 'why', c.note,
                                                                 'on', c.created_at::date) order by c.id desc)
       from (select * from ai_corrections where removed_at is null order by id desc limit 30) c), '[]'::jsonb),
    'misses_30d', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', r.kind, 'lead_id', l.id, 'name', l.name, 'outcome', r.outcome,
        'rated_x', round(r.p_win / greatest(coalesce((public.setting('ai_model_state')->>'win_rate')::numeric, 0.01), 0.0001), 2),
        'traits', (select jsonb_object_agg(k.kind, k.value) from public.ai_lead_keys(l) k)))
       from (select * from public.ai_review_rows(30) x
              order by x.kind, case when x.kind = 'underrated' then x.p_win else -x.p_win end limit 30) r
       join leads l on l.id = r.lead_id), '[]'::jsonb))
$$;
revoke execute on function public.ai_memory() from public, anon, authenticated;
