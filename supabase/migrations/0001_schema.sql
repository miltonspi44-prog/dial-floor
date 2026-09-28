-- Dial Floor · 0001 schema
-- Tables + RLS. Functions live in 0002, seeds in 0003.

-- ---------------------------------------------------------------- profiles --
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  role text not null default 'agent' check (role in ('agent','manager')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_manager()
returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'manager' and active) $$;

-- ------------------------------------------------------------------- leads --
-- Mirror of the lead store (console MySQL / leads.db). The sync worker owns
-- inserts/updates here (service role); the app only reads.
create table public.leads (
  id bigint generated always as identity primary key,
  source_id bigint unique,                 -- console lead id
  place_id text,
  name text not null,
  phone_norm text not null,                -- 10 digits
  phone_display text,
  phone_type text,
  phone_carrier text,
  category text,
  category_key text,
  categories text[],
  tier text,
  score int,
  rating numeric,
  review_count int,
  website text,
  website_type text,                       -- none | social | proper | ...
  platform text,
  platform_detail text,
  email text,
  address text,
  addr_city text,
  addr_state text,
  zip text,
  tz text,                                 -- IANA, derived: area code override else state default
  extras jsonb,
  source text,
  search_query text,
  maps_url text,
  first_seen timestamptz,
  synced_at timestamptz not null default now()
);
create index leads_phone_idx on public.leads (phone_norm);
create index leads_state_idx on public.leads (addr_state);
create index leads_score_idx on public.leads (score desc nulls last);

-- -------------------------------------------------------------- lead_state --
create table public.lead_state (
  lead_id bigint primary key references public.leads(id) on delete cascade,
  state text not null default 'queued'
    check (state in ('fresh','queued','in_progress','callback_locked','resting','provider_list','suppressed','handoff')),
  owner_agent uuid references public.profiles(id),
  rest_until timestamptz,
  attempts_total int not null default 0,
  attempts_today int not null default 0,
  attempts_today_date date,
  connects_total int not null default 0,
  last_attempt_at timestamptz,
  in_progress_since timestamptz,
  writeback_status text,                   -- console contact_status to push (null = nothing pending)
  writeback_note text,
  writeback_done boolean not null default true,
  updated_at timestamptz not null default now()
);
create index lead_state_state_idx on public.lead_state (state);
create index lead_state_writeback_idx on public.lead_state (writeback_done) where not writeback_done;

-- ---------------------------------------------------------------- attempts --
create table public.attempts (
  id bigint generated always as identity primary key,
  lead_id bigint not null references public.leads(id) on delete cascade,
  agent_id uuid not null references public.profiles(id),
  clicked_at timestamptz not null default now(),
  number_used text,                        -- our outbound caller number (from webhook)
  zoom_call_id text,
  zoom_history_id text,
  call_result text,                        -- zoom's result string, verbatim
  duration_seconds int,
  connected boolean,
  disposition text check (disposition in (
    'no_answer','busy_failed','disconnected','voicemail','wrong_number','gatekeeper_end',
    'not_interested_soft','not_interested_hard','has_provider','dm_not_in','callback',
    'email_requested','dnc','chance_website','sale_closed','language_barrier','skipped')),
  voicemail_left boolean,
  note text,
  ab_variant text,
  ai_summary jsonb,                        -- zoom ai companion summary, when enabled + silent-verified
  matched boolean not null default false,  -- webhook found + attached zoom data
  auto_logged boolean not null default false,
  disposed_at timestamptz
);
create index attempts_lead_idx on public.attempts (lead_id, clicked_at desc);
create index attempts_agent_idx on public.attempts (agent_id, clicked_at desc);
create index attempts_unmatched_idx on public.attempts (clicked_at desc) where not matched;

-- --------------------------------------------------------------- callbacks --
create table public.callbacks (
  id bigint generated always as identity primary key,
  lead_id bigint not null references public.leads(id) on delete cascade,
  agent_id uuid not null references public.profiles(id),
  due_at timestamptz not null,
  status text not null default 'scheduled' check (status in ('scheduled','done','missed','requeued')),
  requeued_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index callbacks_due_idx on public.callbacks (status, due_at);

-- ------------------------------------------------------------- suppression --
create table public.suppression (
  id bigint generated always as identity primary key,
  phone_norm text not null,
  place_id text,
  reason text not null check (reason in ('dnc','handoff_website','handoff_sale','disconnected','wrong_number')),
  source_attempt bigint references public.attempts(id),
  created_at timestamptz not null default now(),
  unique (phone_norm, reason)
);
create index suppression_phone_idx on public.suppression (phone_norm);

-- ------------------------------------------------------- lists / list_items --
create table public.lists (
  id bigint generated always as identity primary key,
  name text not null,
  list_date date not null default current_date,
  agent_id uuid references public.profiles(id),
  rules jsonb,
  status text not null default 'active' check (status in ('draft','active','done','archived')),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create table public.list_items (
  id bigint generated always as identity primary key,
  list_id bigint not null references public.lists(id) on delete cascade,
  lead_id bigint not null references public.leads(id) on delete cascade,
  position int not null default 0,
  served_at timestamptz,
  unique (list_id, lead_id)
);
create index list_items_list_idx on public.list_items (list_id, position);

-- ---------------------------------------------------------- handoff_ledger --
-- Leads that gave a chance / closed: they exit dialing here (your Q8 flow).
create table public.handoff_ledger (
  id bigint generated always as identity primary key,
  lead_id bigint not null references public.leads(id),
  lead_snapshot jsonb not null,
  kind text not null check (kind in ('chance_website','sale_closed')),
  summary text,                            -- what was said
  rating int check (rating between 1 and 5),
  agent_id uuid not null references public.profiles(id),
  handed_at timestamptz not null default now(),
  outcome text check (outcome in ('closed','not_closed')),
  outcome_note text,
  outcome_at timestamptz,
  outcome_by uuid references public.profiles(id)
);

-- ------------------------------------------------------------- email_queue --
create table public.email_queue (
  id bigint generated always as identity primary key,
  lead_id bigint not null references public.leads(id),
  email text not null,
  template text,
  status text not null default 'flagged' check (status in ('flagged','sent','skipped')),
  flagged_by uuid references public.profiles(id),
  sent_by uuid references public.profiles(id),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------- intents --
create table public.intents_catalog (
  key text primary key,
  label text not null,
  description text,
  priority int not null default 100
);
create table public.lead_intents (
  lead_id bigint not null references public.leads(id) on delete cascade,
  intent_key text not null references public.intents_catalog(key),
  confidence numeric not null default 1,
  source text,
  computed_at timestamptz not null default now(),
  primary key (lead_id, intent_key)
);

-- ------------------------------------------------------------ number_stats --
-- Observation only: you assign numbers manually in Zoom; this watches health.
create table public.number_stats (
  id bigint generated always as identity primary key,
  number text not null,
  stat_date date not null default current_date,
  dials int not null default 0,
  connects int not null default 0,
  unique (number, stat_date)
);

-- ------------------------------------------------------------- radar_items --
create table public.radar_items (
  id bigint generated always as identity primary key,
  radar_date date not null default current_date,
  audience text not null default 'manager' check (audience in ('manager','agent')),
  agent_id uuid references public.profiles(id),
  type text not null,
  title text not null,
  payload jsonb,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------- battlecards / taps --
create table public.battlecards (
  id bigint generated always as identity primary key,
  objection text not null,
  counters jsonb not null default '[]',    -- ["counter 1", "counter 2", ...]
  sort int not null default 100,
  active boolean not null default true
);
create table public.card_taps (
  id bigint generated always as identity primary key,
  attempt_id bigint references public.attempts(id) on delete set null,
  card_id bigint not null references public.battlecards(id) on delete cascade,
  agent_id uuid references public.profiles(id),
  tapped_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- ab_tests --
create table public.ab_tests (
  id bigint generated always as identity primary key,
  name text not null,
  variants jsonb not null default '[]',
  enabled boolean not null default false,  -- master switch OFF by default (your D6 note)
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------- kpi_targets --
create table public.kpi_targets (
  metric text primary key,
  target numeric not null,
  scope text not null default 'agent_day',
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------- webhook_events --
create table public.webhook_events (
  id bigint generated always as identity primary key,
  event_id text unique,
  event_type text not null,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  processed boolean not null default false,
  processed_at timestamptz,
  error text
);

-- ------------------------------------------------------------ agent_status --
-- The floor board. Each agent upserts their own row; everyone reads.
create table public.agent_status (
  agent_id uuid primary key references public.profiles(id) on delete cascade,
  status text not null default 'offline' check (status in ('idle','dialing','on_call','wrap','break','offline')),
  lead_id bigint references public.leads(id) on delete set null,
  lead_name text,
  phone_display text,
  since timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------ app_settings --
create table public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

-- --------------------------------------------------------------- sync_runs --
create table public.sync_runs (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('pull_leads','push_status','csv_import')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  rows int not null default 0,
  ok boolean,
  detail text
);

-- ------------------------------------------------------- timezone mapping --
create table public.state_tz (
  state text primary key,
  tz text not null
);
create table public.area_code_tz (
  area_code text primary key,
  tz text not null
);

-- ========================================================================
-- RLS. The app uses the anon/authenticated key; sync worker + edge functions
-- use the service role (bypasses RLS). Fine-grained hardening is a Phase 1
-- polish task; v1 policy: signed-in users read, writes go through RPCs
-- (security definer) except the few direct writes below.
-- ========================================================================
alter table public.profiles enable row level security;
alter table public.leads enable row level security;
alter table public.lead_state enable row level security;
alter table public.attempts enable row level security;
alter table public.callbacks enable row level security;
alter table public.suppression enable row level security;
alter table public.lists enable row level security;
alter table public.list_items enable row level security;
alter table public.handoff_ledger enable row level security;
alter table public.email_queue enable row level security;
alter table public.intents_catalog enable row level security;
alter table public.lead_intents enable row level security;
alter table public.number_stats enable row level security;
alter table public.radar_items enable row level security;
alter table public.battlecards enable row level security;
alter table public.card_taps enable row level security;
alter table public.ab_tests enable row level security;
alter table public.kpi_targets enable row level security;
alter table public.webhook_events enable row level security;
alter table public.agent_status enable row level security;
alter table public.app_settings enable row level security;
alter table public.sync_runs enable row level security;
alter table public.state_tz enable row level security;
alter table public.area_code_tz enable row level security;

-- read for every signed-in user
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','leads','lead_state','attempts','callbacks','suppression','lists','list_items',
    'handoff_ledger','email_queue','intents_catalog','lead_intents','number_stats','radar_items',
    'battlecards','card_taps','ab_tests','kpi_targets','agent_status','app_settings','sync_runs',
    'state_tz','area_code_tz']
  loop
    execute format('create policy %I on public.%I for select to authenticated using (true)', t || '_read', t);
  end loop;
end $$;

-- direct writes
create policy agent_status_upsert on public.agent_status
  for insert to authenticated with check (agent_id = auth.uid());
create policy agent_status_update on public.agent_status
  for update to authenticated using (agent_id = auth.uid());
create policy card_taps_insert on public.card_taps
  for insert to authenticated with check (agent_id = auth.uid());
create policy profiles_self_update on public.profiles
  for update to authenticated using (id = auth.uid());

-- manager writes
create policy lists_manager on public.lists
  for all to authenticated using (public.is_manager()) with check (public.is_manager());
create policy list_items_manager on public.list_items
  for all to authenticated using (public.is_manager()) with check (public.is_manager());
create policy battlecards_manager on public.battlecards
  for all to authenticated using (public.is_manager()) with check (public.is_manager());
create policy kpi_manager on public.kpi_targets
  for all to authenticated using (public.is_manager()) with check (public.is_manager());
create policy settings_manager on public.app_settings
  for all to authenticated using (public.is_manager()) with check (public.is_manager());
create policy ab_manager on public.ab_tests
  for all to authenticated using (public.is_manager()) with check (public.is_manager());
create policy ledger_manager_update on public.handoff_ledger
  for update to authenticated using (public.is_manager());
create policy email_queue_manager_update on public.email_queue
  for update to authenticated using (public.is_manager());

-- realtime on the floor board
alter publication supabase_realtime add table public.agent_status;
