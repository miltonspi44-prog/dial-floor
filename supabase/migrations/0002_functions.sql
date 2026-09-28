-- Dial Floor · 0002 functions
-- The queue engine and disposition machine. All RPCs are SECURITY DEFINER and
-- validate the caller; the app never writes core tables directly.

create or replace function public.norm_phone(p text)
returns text language sql immutable as $$
  select case
    when length(d) = 11 and left(d, 1) = '1' then substr(d, 2)
    else d
  end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) s
$$;

create or replace function public.derive_tz(p_phone_norm text, p_state text)
returns text language sql stable as $$
  select coalesce(
    (select tz from public.area_code_tz where area_code = substr(p_phone_norm, 1, 3)),
    (select tz from public.state_tz where state = upper(coalesce(p_state, ''))),
    'America/New_York')
$$;

create or replace function public.setting(p_key text)
returns jsonb language sql stable as $$
  select value from public.app_settings where key = p_key
$$;

-- Is it a lawful/civil hour at the lead's local time?
create or replace function public.local_ok(p_tz text)
returns boolean language plpgsql stable as $$
declare
  w jsonb := coalesce(public.setting('call_window'), '{"start":"08:00","end":"20:30"}'::jsonb);
  lt time := (now() at time zone coalesce(p_tz, 'America/New_York'))::time;
begin
  return lt >= (w->>'start')::time and lt <= (w->>'end')::time;
end $$;

-- ------------------------------------------------------------ refresh_lead --
-- Called by the sync worker (service role) after each upsert, and by radar
-- jobs. Ensures state row, timezone, and recomputes automatic intents.
create or replace function public.refresh_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  l leads%rowtype;
  st lead_state%rowtype;
begin
  select * into l from leads where id = p_lead_id;
  if not found then return; end if;

  update leads set tz = derive_tz(l.phone_norm, l.addr_state) where id = l.id;

  insert into lead_state (lead_id, state)
  values (l.id, 'queued')
  on conflict (lead_id) do nothing;
  select * into st from lead_state where lead_id = l.id;

  -- suppression wins over everything, forever
  if exists (select 1 from suppression s where s.phone_norm = l.phone_norm) then
    update lead_state set state = 'suppressed', updated_at = now() where lead_id = l.id;
    return;
  end if;

  delete from lead_intents where lead_id = l.id and source = 'auto';
  insert into lead_intents (lead_id, intent_key, confidence, source)
  select l.id, k, c, 'auto' from (values
    ('no_website',      case when l.website_type = 'none' then 1.0 end),
    ('social_only',     case when l.website_type = 'social' then 1.0 end),
    ('free_subdomain',  case when l.platform_detail like 'free-subdomain%' then 1.0 end),
    ('cheap_builder',   case when l.platform in ('wix','godaddy','weebly','duda') then 0.9 end),
    ('broken_site',     case when l.platform = 'unreachable' or l.website_type = 'unreachable' then 0.9 end),
    ('fresh_listing',   case when l.first_seen > now() - interval '30 days' then 0.8 end),
    ('review_rich',     case when l.review_count between 20 and 150 and coalesce(l.rating, 0) >= 4 then 0.9 end),
    ('reputation_risk', case when l.review_count >= 10 and l.rating < 3.8 then 0.8 end),
    ('owner_mobile',    case when l.phone_type = 'mobile' then 0.9 end),
    ('multi_trade',     case when coalesce(array_length(l.categories, 1), 0) >= 3 then 0.7 end),
    ('ad_spend',        case when (l.extras->>'sponsored') in ('true','1') then 0.8 end),
    ('badge_holder',    case when (l.extras->>'guaranteed') in ('true','1') then 0.7 end),
    ('never_answers',   case when st.attempts_total >= 4 and st.connects_total = 0 then 0.9 end)
  ) v(k, c)
  where c is not null
  on conflict (lead_id, intent_key) do update set confidence = excluded.confidence, computed_at = now();
end $$;

-- --------------------------------------------------------- workspace shape --
create or replace function public.build_workspace(p_lead_id bigint, p_reason text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l jsonb; st jsonb; ints jsonb; hist jsonb;
begin
  select to_jsonb(x) into l from (select * from leads where id = p_lead_id) x;
  select to_jsonb(x) into st from (select * from lead_state where lead_id = p_lead_id) x;
  select coalesce(jsonb_agg(jsonb_build_object('key', li.intent_key, 'label', ic.label, 'confidence', li.confidence) order by ic.priority), '[]')
    into ints
    from lead_intents li join intents_catalog ic on ic.key = li.intent_key
    where li.lead_id = p_lead_id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'at', a.clicked_at, 'agent', p.name, 'disposition', a.disposition,
      'duration', a.duration_seconds, 'note', a.note) order by a.clicked_at desc), '[]')
    into hist
    from (select * from attempts where lead_id = p_lead_id order by clicked_at desc limit 5) a
    join profiles p on p.id = a.agent_id;
  return jsonb_build_object('reason', p_reason, 'lead', l, 'state', st, 'intents', ints, 'history', hist);
end $$;

-- --------------------------------------------------------------- next_lead --
create or replace function public.next_lead()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_max int := coalesce((public.setting('max_attempts_per_day'))::int, 2);
  v_reclaim interval := make_interval(mins => coalesce((public.setting('reclaim_minutes'))::int, 30));
  r record;
begin
  if v_uid is null then return jsonb_build_object('error', 'not signed in'); end if;

  -- 1. my due callbacks (a promise beats every cold dial)
  select c.lead_id into r
    from callbacks c
    join lead_state ls on ls.lead_id = c.lead_id
    join leads l on l.id = c.lead_id
    where c.agent_id = v_uid and c.status = 'scheduled' and c.due_at <= now() + interval '10 minutes'
      and ls.state <> 'suppressed' and ls.state <> 'handoff'
      and local_ok(l.tz)
    order by c.due_at limit 1;
  if found then return build_workspace(r.lead_id, 'callback_due'); end if;

  -- 2. next from my active lists
  select li.lead_id into r
    from lists ld
    join list_items li on li.list_id = ld.id and li.served_at is null
    join lead_state ls on ls.lead_id = li.lead_id
    join leads l on l.id = li.lead_id
    where ld.agent_id = v_uid and ld.status = 'active'
      and (ls.state in ('fresh','queued')
           or (ls.state = 'in_progress' and ls.in_progress_since < now() - v_reclaim))
      and (ls.rest_until is null or ls.rest_until <= now())
      and (ls.attempts_today_date is distinct from current_date or ls.attempts_today < v_max)
      and local_ok(l.tz)
    order by ld.list_date desc, li.position limit 1;
  if found then return build_workspace(r.lead_id, 'list'); end if;

  -- 3. general pool (manager can turn this off in settings)
  if coalesce((public.setting('allow_general_pool'))::boolean, true) then
    select ls.lead_id into r
      from lead_state ls
      join leads l on l.id = ls.lead_id
      where (ls.state in ('fresh','queued')
             or (ls.state = 'in_progress' and ls.in_progress_since < now() - v_reclaim))
        and (ls.rest_until is null or ls.rest_until <= now())
        and (ls.attempts_today_date is distinct from current_date or ls.attempts_today < v_max)
        and local_ok(l.tz)
      order by l.score desc nulls last, l.review_count desc nulls last limit 1;
    if found then return build_workspace(r.lead_id, 'pool'); end if;
  end if;

  return jsonb_build_object('empty', true,
    'hint', 'No eligible lead right now: lists empty, callbacks not due, or every lead is outside its local calling window.');
end $$;

-- ------------------------------------------------------------ start_attempt --
create or replace function public.start_attempt(p_lead_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  l leads%rowtype;
  v_attempt bigint;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into l from leads where id = p_lead_id;
  if not found then raise exception 'lead not found'; end if;

  perform 1 from lead_state
    where lead_id = p_lead_id
      and state not in ('suppressed','handoff')
      and (owner_agent is null or owner_agent = v_uid
           or state = 'in_progress')          -- reclaim path
    for update;
  if not found then raise exception 'lead is locked'; end if;

  insert into attempts (lead_id, agent_id) values (p_lead_id, v_uid) returning id into v_attempt;

  update lead_state set
    state = 'in_progress',
    owner_agent = v_uid,
    in_progress_since = now(),
    attempts_today = case when attempts_today_date = current_date then attempts_today + 1 else 1 end,
    attempts_today_date = current_date,
    attempts_total = attempts_total + 1,
    last_attempt_at = now(),
    updated_at = now()
  where lead_id = p_lead_id;

  update list_items li set served_at = now()
    from lists ld
    where li.lead_id = p_lead_id and li.list_id = ld.id and ld.agent_id = v_uid and li.served_at is null;

  insert into agent_status (agent_id, status, lead_id, lead_name, phone_display, since, updated_at)
  values (v_uid, 'dialing', p_lead_id, l.name, l.phone_display, now(), now())
  on conflict (agent_id) do update
    set status = 'dialing', lead_id = excluded.lead_id, lead_name = excluded.lead_name,
        phone_display = excluded.phone_display, since = now(), updated_at = now();

  return jsonb_build_object('attempt_id', v_attempt, 'phone', l.phone_norm, 'display', l.phone_display);
end $$;

-- --------------------------------------------------------- log_disposition --
create or replace function public.log_disposition(p_attempt_id bigint, p_dispo text, p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  a attempts%rowtype;
  l leads%rowtype;
  v_connected boolean;
  v_rest interval;
  v_state text := 'queued';
  v_wb_status text;
  v_wb_note text;
  v_note text := nullif(p_args->>'note', '');
begin
  select * into a from attempts where id = p_attempt_id;
  if not found then raise exception 'attempt not found'; end if;
  if a.agent_id <> v_uid and not is_manager() then raise exception 'not your attempt'; end if;
  select * into l from leads where id = a.lead_id;

  v_connected := p_dispo in ('wrong_number','gatekeeper_end','not_interested_soft','not_interested_hard',
                             'has_provider','dm_not_in','callback','email_requested','dnc',
                             'chance_website','sale_closed','language_barrier');

  update attempts set
    disposition = p_dispo,
    connected = v_connected,
    voicemail_left = case when p_dispo = 'voicemail' then coalesce((p_args->>'left_message')::boolean, false) end,
    note = coalesce(v_note, note),
    disposed_at = now()
  where id = p_attempt_id;

  case p_dispo
    when 'not_interested_soft' then
      v_rest := make_interval(days => coalesce((public.setting('rest_soft_days'))::int, 10)); v_state := 'resting';
      v_wb_status := 'not_interested';
    when 'not_interested_hard' then
      v_rest := make_interval(days => coalesce((public.setting('rest_hard_days'))::int, 20)); v_state := 'resting';
      v_wb_status := 'not_interested';
    when 'language_barrier' then
      v_rest := interval '60 days'; v_state := 'resting'; v_wb_status := 'not_interested';
    when 'has_provider' then
      v_state := 'provider_list'; v_wb_status := 'long_term'; v_wb_note := 'has provider';
    when 'gatekeeper_end' then
      v_rest := interval '3 days'; v_state := 'queued';
    when 'dm_not_in' then
      v_rest := coalesce((p_args->>'retry_at')::timestamptz - now(), interval '1 day'); v_state := 'queued';
    when 'voicemail' then
      v_state := 'queued';
    when 'no_answer' then v_state := 'queued';
    when 'busy_failed' then v_state := 'queued';
    when 'skipped' then v_state := 'queued';
    when 'disconnected' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'disconnected', p_attempt_id) on conflict do nothing;
      v_wb_status := 'wrong_number'; v_wb_note := 'disconnected number';
    when 'wrong_number' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'wrong_number', p_attempt_id) on conflict do nothing;
      v_wb_status := 'wrong_number';
    when 'dnc' then
      v_state := 'suppressed';
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'dnc', p_attempt_id) on conflict do nothing;
      v_wb_status := 'do_not_call'; v_wb_note := coalesce(v_note, 'asked not to be called');
    when 'callback' then
      if p_args->>'due_at' is null then raise exception 'callback needs due_at'; end if;
      insert into callbacks (lead_id, agent_id, due_at) values (a.lead_id, a.agent_id, (p_args->>'due_at')::timestamptz);
      v_state := 'callback_locked'; v_wb_status := 'callback';
    when 'email_requested' then
      if p_args->>'email' is null then raise exception 'email_requested needs email'; end if;
      insert into email_queue (lead_id, email, flagged_by) values (a.lead_id, p_args->>'email', v_uid);
      update leads set email = p_args->>'email' where id = a.lead_id;
      v_rest := interval '3 days'; v_state := 'queued'; v_wb_status := 'long_term'; v_wb_note := 'asked for email';
    when 'chance_website' then
      insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
        values (a.lead_id, to_jsonb(l), 'chance_website', p_args->>'summary', (p_args->>'rating')::int, a.agent_id);
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'handoff_website', p_attempt_id) on conflict do nothing;
      v_state := 'handoff'; v_wb_status := 'captured'; v_wb_note := coalesce(p_args->>'summary', 'gave upfront - website');
    when 'sale_closed' then
      insert into handoff_ledger (lead_id, lead_snapshot, kind, summary, rating, agent_id)
        values (a.lead_id, to_jsonb(l), 'sale_closed', p_args->>'summary', (p_args->>'rating')::int, a.agent_id);
      insert into suppression (phone_norm, place_id, reason, source_attempt)
        values (l.phone_norm, l.place_id, 'handoff_sale', p_attempt_id) on conflict do nothing;
      v_state := 'handoff'; v_wb_status := 'captured'; v_wb_note := coalesce(p_args->>'summary', 'sale closed - seo/receptionist');
    else
      raise exception 'unknown disposition %', p_dispo;
  end case;

  update lead_state set
    state = v_state,
    owner_agent = case when v_state in ('callback_locked','in_progress') then a.agent_id else null end,
    rest_until = case when v_rest is not null then now() + v_rest else null end,
    connects_total = connects_total + case when v_connected then 1 else 0 end,
    in_progress_since = null,
    writeback_status = coalesce(v_wb_status, writeback_status),
    writeback_note = coalesce(v_wb_note, v_note, writeback_note),
    writeback_done = case when v_wb_status is null then writeback_done else false end,
    updated_at = now()
  where lead_id = a.lead_id;

  perform refresh_lead(a.lead_id);

  insert into agent_status (agent_id, status, lead_id, lead_name, phone_display, since, updated_at)
  values (v_uid, 'idle', null, null, null, now(), now())
  on conflict (agent_id) do update
    set status = 'idle', lead_id = null, lead_name = null, phone_display = null, since = now(), updated_at = now();

  return jsonb_build_object('ok', true, 'next', next_lead());
end $$;

-- ------------------------------------------------------------ release_lead --
-- Agent skip, or manager pushing a locked lead back to the general queue (A7).
create or replace function public.release_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  perform 1 from lead_state where lead_id = p_lead_id and (owner_agent = v_uid or is_manager());
  if not found then raise exception 'not allowed'; end if;
  update callbacks set status = 'requeued', requeued_by = v_uid
    where lead_id = p_lead_id and status = 'scheduled' and is_manager();
  update lead_state set state = 'queued', owner_agent = null, in_progress_since = null, updated_at = now()
    where lead_id = p_lead_id and state in ('in_progress','callback_locked');
end $$;

-- --------------------------------------------------------------- heartbeat --
create or replace function public.heartbeat(p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('idle','wrap','break','offline') then raise exception 'bad status'; end if;
  insert into agent_status (agent_id, status, since, updated_at)
  values (auth.uid(), p_status, now(), now())
  on conflict (agent_id) do update set status = excluded.status, since = now(), updated_at = now();
end $$;

-- -------------------------------------------------------------- build_list --
create or replace function public.build_list(p_name text, p_agent uuid, p_rules jsonb, p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_list bigint; v_count int;
begin
  if not is_manager() then raise exception 'manager only'; end if;
  insert into lists (name, agent_id, rules, created_by)
    values (p_name, p_agent, p_rules, auth.uid()) returning id into v_list;
  insert into list_items (list_id, lead_id, position)
  select v_list, l.id, row_number() over (order by l.score desc nulls last, l.review_count desc nulls last)
    from leads l
    join lead_state ls on ls.lead_id = l.id
    where ls.state in ('fresh','queued')
      and (ls.rest_until is null or ls.rest_until <= now())
      and (p_rules->>'state' is null or l.addr_state = upper(p_rules->>'state'))
      and (p_rules->>'tier' is null or l.tier = upper(p_rules->>'tier'))
      and (p_rules->>'min_score' is null or l.score >= (p_rules->>'min_score')::int)
      and (p_rules->>'intent' is null or exists
            (select 1 from lead_intents li where li.lead_id = l.id and li.intent_key = p_rules->>'intent'))
      and (p_rules->>'phone_type' is null or l.phone_type = p_rules->>'phone_type')
      and not exists (select 1 from list_items li2 join lists ld2 on ld2.id = li2.list_id
                      where li2.lead_id = l.id and ld2.status = 'active' and li2.served_at is null)
    limit p_limit;
  get diagnostics v_count = row_count;
  return jsonb_build_object('list_id', v_list, 'count', v_count);
end $$;

-- ----------------------------------------------------------------- boards --
create or replace view public.v_floor_today with (security_invoker = true) as
select
  p.id as agent_id, p.name, p.role,
  coalesce(s.status, 'offline') as status,
  s.lead_name, s.phone_display, s.since,
  count(a.id) filter (where a.clicked_at::date = current_date) as dials_today,
  count(a.id) filter (where a.clicked_at::date = current_date and a.connected) as connects_today,
  count(a.id) filter (where a.clicked_at::date = current_date and a.disposition in ('chance_website','sale_closed')) as handoffs_today,
  count(a.id) filter (where a.clicked_at::date = current_date and a.disposition = 'email_requested') as emails_today
from profiles p
left join agent_status s on s.agent_id = p.id
left join attempts a on a.agent_id = p.id
where p.active
group by p.id, p.name, p.role, s.status, s.lead_name, s.phone_display, s.since;

create or replace view public.v_number_health with (security_invoker = true) as
select number,
  sum(dials) filter (where stat_date >= current_date - 6) as dials_7d,
  sum(connects) filter (where stat_date >= current_date - 6) as connects_7d,
  round(100.0 * nullif(sum(connects) filter (where stat_date >= current_date - 6), 0)
      / nullif(sum(dials) filter (where stat_date >= current_date - 6), 0), 1) as rate_7d,
  round(100.0 * nullif(sum(connects) filter (where stat_date between current_date - 13 and current_date - 7), 0)
      / nullif(sum(dials) filter (where stat_date between current_date - 13 and current_date - 7), 0), 1) as rate_prev_7d
from number_stats
group by number;

create or replace view public.v_funnel with (security_invoker = true) as
select
  a.clicked_at::date as day,
  count(*) as dials,
  count(*) filter (where a.connected) as connects,
  count(*) filter (where a.disposition in ('not_interested_soft','not_interested_hard')) as rejections,
  count(*) filter (where a.disposition = 'callback') as callbacks,
  count(*) filter (where a.disposition = 'email_requested') as emails,
  count(*) filter (where a.disposition in ('chance_website','sale_closed')) as handoffs
from attempts a
group by 1;
