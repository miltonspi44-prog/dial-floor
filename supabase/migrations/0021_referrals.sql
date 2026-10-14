-- Dial Floor · 0021 referrals (Phase 2 · G6)
--   "Talk to my buddy who does gutters": the agent saves it from the outcome
--   popup while the call is fresh. It becomes a new lead (or, when the number is
--   already on file, is linked to that lead, and a parked lead comes back),
--   marked as a warm referral with who sent us, and goes to the top of that
--   agent's own Referrals list: the agent with the context makes the call. A
--   number on the do-not-call list, or one already handed off, is refused.
--   Referral leads live in the dialer only: the console sync neither pulls nor
--   writes back leads without a console id.

insert into public.intents_catalog (key, label, description, priority) values
  ('warm_referral', 'Warm referral', 'Someone we called sent us: open with who referred them', 4)
on conflict (key) do nothing;

create table public.referrals (
  id bigint generated always as identity primary key,
  lead_id bigint not null references public.leads(id) on delete cascade,
  from_lead bigint references public.leads(id) on delete set null,
  from_attempt bigint references public.attempts(id) on delete set null,
  agent_id uuid references public.profiles(id) on delete set null,
  note text,
  created_lead boolean not null,        -- false: the number was already on file
  created_at timestamptz not null default now()
);
create index referrals_lead_idx on public.referrals (lead_id, created_at desc);
alter table public.referrals enable row level security;
create policy referrals_read on public.referrals for select to authenticated using (true);

create or replace function public.add_referral(p_attempt_id bigint, p_name text, p_phone text,
                                               p_category text default null, p_city text default null,
                                               p_state text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_phone text := public.norm_phone(p_phone);
  a attempts%rowtype;
  src leads%rowtype;
  v_lead bigint;
  v_state text;
  v_created boolean := false;
  v_list bigint;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into a from attempts where id = p_attempt_id;
  if not found then raise exception 'call not found'; end if;
  if a.agent_id <> v_uid and not is_manager() then raise exception 'not your call'; end if;
  if nullif(btrim(p_name), '') is null then raise exception 'enter who they are'; end if;
  if length(v_phone) <> 10 then raise exception 'enter a 10-digit phone number'; end if;
  select * into src from leads where id = a.lead_id;
  if v_phone = src.phone_norm then raise exception 'that is the number you are calling'; end if;
  if exists (select 1 from suppression s where s.phone_norm = v_phone) then
    raise exception 'that number is on the do-not-call list';
  end if;

  -- already on file: link that lead instead of making a second record
  select l.id, ls.state into v_lead, v_state
    from leads l join lead_state ls on ls.lead_id = l.id
   where l.phone_norm = v_phone
   order by (ls.state in ('suppressed', 'handoff')), l.id limit 1;
  if v_lead is not null then
    if v_state = 'handoff' then raise exception 'that business was already handed off'; end if;
    -- a warm introduction is a fresh reason to call: a parked lead comes back
    if v_state in ('resting', 'provider_list') then
      update lead_state set state = 'queued', rest_until = null, updated_at = now() where lead_id = v_lead;
    end if;
  else
    insert into leads (name, phone_norm, phone_display, category, addr_city, addr_state, source, first_seen, extras)
    values (btrim(p_name), v_phone,
            '(' || substr(v_phone, 1, 3) || ') ' || substr(v_phone, 4, 3) || '-' || substr(v_phone, 7),
            nullif(btrim(p_category), ''),
            coalesce(nullif(btrim(p_city), ''), src.addr_city),
            upper(coalesce(nullif(btrim(p_state), ''), src.addr_state)),
            'referral', now(), jsonb_build_object('referred_by', src.name))
    returning id into v_lead;
    v_created := true;
    perform public.refresh_lead(v_lead);  -- timezone, queue state, the automatic intents
  end if;

  insert into lead_intents (lead_id, intent_key, confidence, source)
    values (v_lead, 'warm_referral', 1, 'referral')
    on conflict (lead_id, intent_key) do update set confidence = 1, source = 'referral', computed_at = now();
  insert into referrals (lead_id, from_lead, from_attempt, agent_id, note, created_lead)
    values (v_lead, a.lead_id, a.id, a.agent_id, nullif(btrim(p_note), ''), v_created);

  -- the top of that agent's own Referrals list: today's date and position 0 put it
  -- ahead of the morning's radar list
  select id into v_list from lists
   where kind = 'referrals' and agent_id = a.agent_id and status = 'active' order by id limit 1;
  if v_list is null then
    insert into lists (name, agent_id, rules, created_by, kind, list_date)
      values ('Referrals · ' || coalesce((select name from profiles where id = a.agent_id), 'agent'),
              a.agent_id, '{"referrals": true}', v_uid, 'referrals', public.business_date())
      returning id into v_list;
  else
    update lists set list_date = public.business_date() where id = v_list;
  end if;
  insert into list_items (list_id, lead_id, position) values (v_list, v_lead, 0)
    on conflict (list_id, lead_id) do update set served_at = null, position = 0;

  return jsonb_build_object('lead_id', v_lead, 'created', v_created, 'list_id', v_list,
                            'name', (select name from leads where id = v_lead));
end $$;

create or replace function public.build_workspace(p_lead_id bigint, p_reason text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l jsonb; st jsonb; ints jsonb; hist jsonb; ab jsonb; missed jsonb; ref jsonb;
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
  -- C4 proof: the tries they didn't pick up, on their clock (latest first)
  if exists (select 1 from lead_intents where lead_id = p_lead_id and intent_key = 'never_answers') then
    select jsonb_build_object('count', (select count(*) from missed_tries(p_lead_id)),
                              'times', coalesce(jsonb_agg(m.clicked_at order by m.clicked_at desc), '[]'::jsonb))
      into missed
      from (select clicked_at from missed_tries(p_lead_id) order by clicked_at desc limit 6) m;
  end if;
  -- G6: who sent us to them, and what the agent noted
  select jsonb_build_object('from', fl.name, 'agent', p.name, 'at', r.created_at, 'note', r.note)
    into ref
    from referrals r left join leads fl on fl.id = r.from_lead left join profiles p on p.id = r.agent_id
   where r.lead_id = p_lead_id order by r.created_at desc limit 1;
  return jsonb_build_object('reason', p_reason, 'lead', l, 'state', st, 'intents', ints, 'history', hist)
      || case when ab is null then '{}'::jsonb else jsonb_build_object('ab', ab) end
      || case when missed is null then '{}'::jsonb else jsonb_build_object('missed', missed) end
      || case when ref is null then '{}'::jsonb else jsonb_build_object('referral', ref) end;
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.add_referral(bigint, text, text, text, text, text, text) from public, anon;
grant execute on function public.add_referral(bigint, text, text, text, text, text, text) to authenticated;
