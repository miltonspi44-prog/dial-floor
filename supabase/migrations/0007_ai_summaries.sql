-- Dial Floor · 0007 AI call summaries in the portal
-- The webhook attaches Zoom's AI call summary to the attempt it belongs to
-- (attempts.ai_summary). The lead's history now carries it, so the Dial page
-- shows what was said on earlier calls.

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
      'duration', a.duration_seconds, 'note', a.note,
      'ai_summary', a.ai_summary->>'summary', 'next_steps', a.ai_summary->>'next_steps') order by a.clicked_at desc), '[]')
    into hist
    from (select * from attempts where lead_id = p_lead_id order by clicked_at desc limit 5) a
    join profiles p on p.id = a.agent_id;
  return jsonb_build_object('reason', p_reason, 'lead', l, 'state', st, 'intents', ints, 'history', hist);
end $$;
