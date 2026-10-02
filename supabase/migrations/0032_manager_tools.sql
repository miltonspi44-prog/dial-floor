-- Dial Floor · 0032 the manager's day moves into the app
-- Focus items 36–40 and 44–46 (the database half), reproduced in
-- supabase/tests/groups/43_manager_tools.sql:
--   · 36 one Settings page: every tunable that needed the SQL editor is now a
--     whitelisted registry — read in one call, written with its own validation.
--   · 37/38 lists grow hands: assign a list to an agent, see what is on one,
--     put a lead on by hand, take one off.
--   · 39 "push back to queue" refuses a lead whose agent is on the call right
--     now (the rest of 39 — confirmations — lives in the page).
--   · 44 lists and their items were readable by any signed-in agent; they are
--     the manager's planning surface, so they read manager-only now. Everything
--     an agent needs arrives through the queue RPCs.
--   · 45 the callback alert said the time in business time; it now says it on
--     the lead's own clock, which is the clock the promise was made on.
--   · 46 the handoff outcome can be corrected, and the do-not-call list has a
--     view and a by-hand add.

-- ---------------------------------------------------------------- settings --
-- The whitelist is the contract: only these keys, each with its own kind and
-- bounds. Internal state (best_time_state, radar_last_run) is deliberately
-- absent, as are the kpi targets, which have their own editor on the Funnel.
create or replace function public.settings_registry()
returns jsonb language sql immutable set search_path = public as $$
select jsonb_build_array(
  jsonb_build_object('key','call_window','kind','window','grp','Calling window','label','Calling hours (lead''s local time)','help','No lead is served or dialed outside these hours on its own clock.','def','{"start":"08:00","end":"20:30"}'::jsonb),
  jsonb_build_object('key','business_hours','kind','window_days','grp','Calling window','label','Business hours (for never-answers proof)','help','The hours and days that count as "they should have picked up".','def','{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}'::jsonb),
  jsonb_build_object('key','business_tz','kind','tz','grp','Calling window','label','Business timezone','help','The clock the floor''s day, streaks and reports run on.','def',to_jsonb('America/Los_Angeles'::text)),
  jsonb_build_object('key','max_attempts_per_day','kind','int','grp','Queue','label','Calls per business per day','min',1,'max',6,'def',to_jsonb(2)),
  jsonb_build_object('key','min_redial_minutes','kind','int','grp','Queue','label','Redial gap (minutes)','min',15,'max',720,'def',to_jsonb(120)),
  jsonb_build_object('key','reserve_minutes','kind','int','grp','Queue','label','Lead held on screen (minutes)','min',3,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','reclaim_minutes','kind','int','grp','Queue','label','Abandoned call reclaimed after (minutes)','min',10,'max',120,'def',to_jsonb(30)),
  jsonb_build_object('key','skip_rest_minutes','kind','int','grp','Queue','label','Rest after a skip (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','reclaim_sweep_max','kind','int','grp','Queue','label','Stranded calls finished per check','min',5,'max',100,'def',to_jsonb(25)),
  jsonb_build_object('key','allow_general_pool','kind','bool','grp','Queue','label','Serve from the general pool','help','Off = agents only dial callbacks and lists.','def',to_jsonb(true)),
  jsonb_build_object('key','callback_retry_minutes','kind','int','grp','Callbacks','label','Unanswered callback retried after (minutes)','min',10,'max',480,'def',to_jsonb(60)),
  jsonb_build_object('key','callback_max_tries','kind','int','grp','Callbacks','label','Tries before a callback is unreached','min',1,'max',6,'def',to_jsonb(3)),
  jsonb_build_object('key','callback_missed_hours','kind','int','grp','Callbacks','label','Overdue hours before a callback is missed','min',4,'max',72,'def',to_jsonb(24)),
  jsonb_build_object('key','rest_soft_days','kind','int','grp','Rests','label','"Not interested — soft" rest (days)','min',1,'max',60,'def',to_jsonb(10)),
  jsonb_build_object('key','rest_hard_days','kind','int','grp','Rests','label','"Not interested — hard" rest (days)','min',1,'max',120,'def',to_jsonb(20)),
  jsonb_build_object('key','recycle_provider_days','kind','int','grp','Rests','label','"Has provider" auto-return (days, 0 = off)','min',0,'max',365,'def',to_jsonb(0)),
  jsonb_build_object('key','shift_hours','kind','num','grp','Pace','label','Shift length (hours)','min',1,'max',16,'def',to_jsonb(8)),
  jsonb_build_object('key','wrapup_seconds','kind','int','grp','Pace','label','Wrap-up countdown (seconds, 0 = off)','min',0,'max',300,'def',to_jsonb(20)),
  jsonb_build_object('key','alerts','kind','json','grp','Alerts','label','Alert thresholds','help','idle_minutes, long_call_minutes, pace_pct, callback_overdue_minutes, celebrate, spam.','def','{}'::jsonb),
  jsonb_build_object('key','spam_alert_drop_pts','kind','num','grp','Alerts','label','Spam alert: connect-rate drop (points)','min',1,'max',50,'def',to_jsonb(10)),
  jsonb_build_object('key','radar_deal_per_agent','kind','int','grp','Radar','label','Radar leads dealt per agent per day','min',0,'max',500,'def',to_jsonb(100)),
  jsonb_build_object('key','missed_call_threshold','kind','int','grp','Radar','label','Missed tries before "never answers"','min',2,'max',10,'def',to_jsonb(4)),
  jsonb_build_object('key','seasons','kind','json','grp','Radar','label','Seasonal windows','help','A list of {label, keys, months, states}.','def','[]'::jsonb),
  jsonb_build_object('key','best_time','kind','json','grp','Model','label','Best-time-to-call model','help','use_in_queue, days, min_dials, min_total, prior.','def','{}'::jsonb),
  jsonb_build_object('key','ai_summaries_enabled','kind','bool','grp','Model','label','Fetch Zoom AI call summaries','def',to_jsonb(false))
)
$$;

create or replace function public.settings_all()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.is_manager() then null else (
    select jsonb_agg(r || jsonb_build_object('value', coalesce(s.value, r->'def')) order by r->>'grp', r->>'label')
      from jsonb_array_elements(public.settings_registry()) r
      left join app_settings s on s.key = r->>'key')
  end
$$;

create or replace function public.settings_set(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
  v_kind text;
  v_num numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  select x into r from jsonb_array_elements(public.settings_registry()) x where x->>'key' = p_key;
  if r is null then raise exception 'not a setting the app manages: %', p_key; end if;
  v_kind := r->>'kind';

  if v_kind in ('int', 'num') then
    if jsonb_typeof(p_value) <> 'number' then raise exception '% wants a number', p_key; end if;
    v_num := (p_value #>> '{}')::numeric;
    if v_kind = 'int' and v_num <> round(v_num) then raise exception '% wants a whole number', p_key; end if;
    if r ? 'min' and v_num < (r->>'min')::numeric then
      raise exception '% must be at least %', p_key, r->>'min';
    end if;
    if r ? 'max' and v_num > (r->>'max')::numeric then
      raise exception '% must be at most %', p_key, r->>'max';
    end if;
  elsif v_kind = 'bool' then
    if jsonb_typeof(p_value) <> 'boolean' then raise exception '% wants true or false', p_key; end if;
  elsif v_kind = 'tz' then
    if jsonb_typeof(p_value) <> 'string' then raise exception '% wants a timezone name', p_key; end if;
    begin
      perform now() at time zone (p_value #>> '{}');
    exception when others then
      raise exception '"%" is not a timezone the database knows', p_value #>> '{}';
    end;
  elsif v_kind in ('window', 'window_days') then
    if jsonb_typeof(p_value) <> 'object'
       or (p_value->>'start') is null or (p_value->>'end') is null then
      raise exception '% wants {"start":"HH:MM","end":"HH:MM"%"}', p_key,
        case when v_kind = 'window_days' then ',"days":[1..7]' else '' end;
    end if;
    begin
      if (p_value->>'start')::time >= (p_value->>'end')::time then
        raise exception 'the window has to open before it closes';
      end if;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception '% wants times like "08:00"', p_key;
    end;
    if v_kind = 'window_days' then
      if jsonb_typeof(p_value->'days') <> 'array'
         or exists (select 1 from jsonb_array_elements_text(p_value->'days') d
                     where d !~ '^[1-7]$') then
        raise exception '%: days are 1 (Monday) to 7 (Sunday)', p_key;
      end if;
    end if;
  elsif v_kind = 'json' then
    if jsonb_typeof(p_value) not in ('object', 'array') then
      raise exception '% wants a JSON object or list', p_key;
    end if;
  end if;

  insert into app_settings (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('key', p_key, 'value', p_value);
end $$;

-- ---------------------------------------------------- lists are the manager's --
-- 44: planning surfaces read manager-only. The queue RPCs run as their owner, so
-- agents keep being served from lists without ever reading the tables.
alter policy lists_read on public.lists using (public.is_manager());
alter policy list_items_read on public.list_items using (public.is_manager());

-- 37: a list changes hands without the SQL editor
create or replace function public.set_list_agent(p_list bigint, p_agent uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_agent is not null and not exists (select 1 from profiles where id = p_agent and active) then
    raise exception 'that login is switched off';
  end if;
  update lists set agent_id = p_agent where id = p_list;
  if not found then raise exception 'list not found'; end if;
end $$;

-- 38: what is on a list, and a lead put on or taken off by hand
create or replace function public.list_leads(p_list bigint, p_limit int default 500)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.is_manager() then null else (
    select coalesce(jsonb_agg(jsonb_build_object(
             'lead_id', l.id, 'name', l.name, 'phone', l.phone_display,
             'city', l.addr_city, 'state', l.addr_state,
             'lead_state', ls.state, 'position', li.position, 'served_at', li.served_at)
           order by li.position, li.id), '[]'::jsonb)
      from list_items li
      join leads l on l.id = li.lead_id
      join lead_state ls on ls.lead_id = l.id
     where li.list_id = p_list
     limit greatest(1, least(coalesce(p_limit, 500), 2000)))
  end
$$;

create or replace function public.list_add_lead(p_list bigint, p_lead bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_state text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if not exists (select 1 from lists where id = p_list and status in ('draft', 'active')) then
    raise exception 'that list is closed';
  end if;
  select state into v_state from lead_state where lead_id = p_lead;
  if v_state is null then raise exception 'lead not found'; end if;
  if v_state in ('suppressed', 'handoff') then
    raise exception 'this lead can no longer be dialed';
  end if;
  -- re-adding a lead the list already served means "serve it again"
  insert into list_items (list_id, lead_id, position)
  values (p_list, p_lead, coalesce((select max(position) from list_items where list_id = p_list), 0) + 1)
  on conflict (list_id, lead_id) do update set served_at = null;
  return jsonb_build_object('list_id', p_list, 'lead_id', p_lead);
end $$;

-- HAND-APPLY AT LIVE TIME: the one remove is a real delete, which the management
-- API's confirmation scanner stalls on (see 0022). Dashboard SQL editor.
create or replace function public.list_remove_lead(p_list bigint, p_lead bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  delete from list_items where list_id = p_list and lead_id = p_lead;
end $$;

-- ------------------------------------------------------------ handoff ledger --
-- 46: the outcome can be corrected. The row keeps who settled it last and when.
create or replace function public.update_handoff(p_id bigint, p_outcome text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_outcome is not null and p_outcome not in ('closed', 'not_closed') then
    raise exception 'the outcome is closed, not_closed, or cleared with null';
  end if;
  update handoff_ledger set
      outcome = p_outcome,
      outcome_note = p_note,
      outcome_at = case when p_outcome is null then null else now() end,
      outcome_by = case when p_outcome is null then null else auth.uid() end
    where id = p_id;
  if not found then raise exception 'handoff not found'; end if;
  return jsonb_build_object('id', p_id, 'outcome', p_outcome);
end $$;

-- ------------------------------------------------------------- suppression --
-- 46: a view of the do-not-call list, and a number added by hand. Adding one
-- suppresses every lead record carrying it through the same refresh the sync
-- uses, so the console hears about it too.
create or replace function public.suppression_list(p_query text default null, p_limit int default 100)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.is_manager() then null else (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', s.id, 'phone_norm', s.phone_norm, 'reason', s.reason, 'at', s.created_at,
             'leads', (select coalesce(jsonb_agg(l.name order by l.id), '[]'::jsonb)
                         from leads l where l.phone_norm = s.phone_norm))
           order by s.created_at desc), '[]'::jsonb)
      from (select * from suppression s0
             where p_query is null or p_query = ''
                or s0.phone_norm like '%' || regexp_replace(p_query, '\D', '', 'g') || '%'
             order by s0.created_at desc
             limit greatest(1, least(coalesce(p_limit, 100), 1000))) s)
  end
$$;

create or replace function public.add_suppression(p_phone text, p_reason text default 'dnc')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_phone text := public.norm_phone(p_phone);
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if length(coalesce(v_phone, '')) <> 10 then raise exception 'a 10-digit number'; end if;
  if p_reason not in ('dnc', 'wrong_number', 'disconnected') then
    raise exception 'the reason is dnc, wrong_number or disconnected';
  end if;
  insert into suppression (phone_norm, reason) values (v_phone, p_reason)
  on conflict (phone_norm, reason) do nothing;
  -- the same path a synced twin of an excluded number takes
  perform refresh_lead(l.id) from leads l where l.phone_norm = v_phone;
  return jsonb_build_object('phone_norm', v_phone, 'reason', p_reason,
    'leads_suppressed', (select count(*) from leads l join lead_state ls on ls.lead_id = l.id
                          where l.phone_norm = v_phone and ls.state = 'suppressed'));
end $$;

-- ---------------------------------------------------------------- push back --
-- 39: a manager's push-back refuses a lead whose agent is on the call right now.
-- The button exists for stuck leads; mid-call it would yank a live conversation
-- out from under the person having it.
create or replace function public.release_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  perform 1 from lead_state
    where lead_id = p_lead_id and (owner_agent = v_uid or reserved_by = v_uid or is_manager());
  if not found then raise exception 'not allowed'; end if;
  if is_manager() and exists (
       select 1 from lead_state ls
       join agent_status s on s.agent_id = ls.owner_agent
      where ls.lead_id = p_lead_id and ls.owner_agent is distinct from v_uid
        and s.lead_id = p_lead_id and s.status in ('dialing', 'on_call')
        and s.updated_at > now() - interval '2 minutes') then
    raise exception 'they are on this call right now — ask them to log it, or wait for the tile to go quiet';
  end if;
  update callbacks set status = 'requeued', requeued_by = v_uid
    where lead_id = p_lead_id and status = 'scheduled' and is_manager();
  update lead_state set
      state = case when state in ('in_progress','callback_locked') then 'queued' else state end,
      owner_agent = case when state in ('in_progress','callback_locked') then null else owner_agent end,
      in_progress_since = case when state in ('in_progress','callback_locked') then null else in_progress_since end,
      reserved_by = null,
      reserved_until = null,
      updated_at = now()
    where lead_id = p_lead_id;
end $$;

-- -------------------------------------------------------------- API surface --
revoke execute on function public.settings_registry(), public.settings_all(), public.settings_set(text, jsonb),
  public.set_list_agent(bigint, uuid), public.list_leads(bigint, int),
  public.list_add_lead(bigint, bigint), public.list_remove_lead(bigint, bigint),
  public.update_handoff(bigint, text, text), public.suppression_list(text, int),
  public.add_suppression(text, text), public.release_lead(bigint)
  from public, anon;
grant execute on function public.settings_registry(), public.settings_all(), public.settings_set(text, jsonb),
  public.set_list_agent(bigint, uuid), public.list_leads(bigint, int),
  public.list_add_lead(bigint, bigint), public.list_remove_lead(bigint, bigint),
  public.update_handoff(bigint, text, text), public.suppression_list(text, int),
  public.add_suppression(text, text), public.release_lead(bigint)
  to authenticated;
