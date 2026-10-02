-- Dial Floor · 0030 a fixed number comes back
-- Focus item 22, reproduced first in supabase/tests/groups/41_unsuppress.sql:
-- a record suppressed for a wrong or
-- disconnected number stayed dead even after the console corrected the number.
-- The plan's loop — "wrong number clears the phone and sends the lead back for
-- re-enrichment" — had no return path. Now refresh_lead, which the sync calls
-- after every import, re-queues a suppressed lead the moment no suppression row
-- matches its current number. A do-not-call stays matched by number, so a DNC
-- only comes back if the number really changed — which is the correct reading:
-- the person at the old number asked, and the new number is somebody else's.
--
-- HAND-APPLY AT LIVE TIME: the body carries a "delete from" (the intents
-- rewrite), which the management API's confirmation scanner stalls on — the same
-- wall this very function hit in 0022. Dashboard SQL editor.
create or replace function public.refresh_lead(p_lead_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  l leads%rowtype;
  st lead_state%rowtype;
  v_reason text;
  v_wb_status text;
  v_wb_note text;
begin
  select * into l from leads where id = p_lead_id;
  if not found then return; end if;

  update leads set tz = derive_tz(l.phone_norm, l.addr_state) where id = l.id;

  insert into lead_state (lead_id, state)
  values (l.id, 'queued')
  on conflict (lead_id) do nothing;
  select * into st from lead_state where lead_id = l.id;

  -- suppression wins over everything, forever (a handoff keeps its own state)
  if exists (select 1 from suppression s where s.phone_norm = l.phone_norm) then
    -- A number can be on the list for more than one reason; the console hears the
    -- most final one. This is the path a freshly synced twin of an excluded number
    -- takes, so it is also where that twin is queued for write-back — only on the
    -- way into suppressed, so a lead already excluded is not pushed again and again.
    select s.reason into v_reason from suppression s
      where s.phone_norm = l.phone_norm
      order by case s.reason when 'dnc' then 1 when 'handoff_sale' then 2 when 'handoff_website' then 3
                             when 'wrong_number' then 4 else 5 end
      limit 1;
    v_wb_status := case v_reason when 'dnc' then 'do_not_call'
                                when 'handoff_sale' then 'captured'
                                when 'handoff_website' then 'captured'
                                else 'wrong_number' end;
    v_wb_note := case v_reason when 'dnc' then 'asked not to be called'
                               when 'disconnected' then 'disconnected number'
                               when 'wrong_number' then 'wrong number'
                               else 'already handed off' end;
    update lead_state set state = 'suppressed', owner_agent = null, reserved_by = null,
        reserved_until = null, writeback_status = v_wb_status,
        writeback_note = v_wb_note, writeback_done = false,
        updated_at = now()
      where lead_id = l.id and state not in ('suppressed', 'handoff');
    update callbacks set status = 'cancelled' where lead_id = l.id and status = 'scheduled';
    return;
  end if;

  -- 22: suppressed, but nothing on the list matches this number any more — the
  -- console fixed the number (or a manager cleared the entry), so the business
  -- is callable again. Back to the queue, rest and counters as they were; the
  -- console is not written to, since the console is where the change came from —
  -- and a write-back still waiting from the old number is dropped for the same
  -- reason: pushing "wrong number" at a record whose number was just fixed would
  -- kill the fix. A handoff is not a suppression: sold stays sold whatever the
  -- number does.
  if st.state = 'suppressed' then
    update lead_state set state = 'queued', owner_agent = null, reserved_by = null,
        reserved_until = null, writeback_status = null, writeback_note = null,
        writeback_done = true, updated_at = now()
      where lead_id = l.id and state = 'suppressed';
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
    -- C4: no pickup on N+ tries during their own business hours, and never a live conversation
    ('never_answers',   case when st.connects_total = 0
                              and (select count(*) from missed_tries(l.id))
                                  >= coalesce((public.setting('missed_call_threshold'))::int, 4) then 0.9 end)
  ) v(k, c)
  where c is not null
  on conflict (lead_id, intent_key) do update set confidence = excluded.confidence, computed_at = now();
end $$;
