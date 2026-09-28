// Dial Floor · Zoom webhook ingest (Supabase Edge Function)
// Handles: endpoint.url_validation, phone.caller_ended / phone.callee_ended,
// phone.ai_call_summary_changed. Verifies Zoom's v0 HMAC signature, dedupes,
// stores the raw event, then matches it to the click-to-dial attempt.
//
// Required function secrets:
//   ZOOM_WEBHOOK_SECRET_TOKEN  (from the Zoom app's Features > Event Subscriptions)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "npm:@supabase/supabase-js@2";

const supa = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const SECRET = Deno.env.get("ZOOM_WEBHOOK_SECRET_TOKEN") ?? "";

async function hmacHex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function norm(p?: string | null): string {
  const d = (p ?? "").replace(/\D/g, "");
  return d.length === 11 && d.startsWith("1") ? d.slice(1) : d;
}

Deno.serve(async (req) => {
  const body = await req.text();
  let evt: any;
  try { evt = JSON.parse(body); } catch { return new Response("bad json", { status: 400 }); }

  // Zoom's URL validation handshake
  if (evt.event === "endpoint.url_validation") {
    const plain = evt.payload?.plainToken ?? "";
    return Response.json({ plainToken: plain, encryptedToken: await hmacHex(SECRET, plain) });
  }

  // Signature check on every real event
  const ts = req.headers.get("x-zm-request-timestamp") ?? "";
  const sig = req.headers.get("x-zm-signature") ?? "";
  const expect = "v0=" + await hmacHex(SECRET, `v0:${ts}:${body}`);
  if (!SECRET || sig !== expect) return new Response("bad signature", { status: 401 });

  // Dedupe on Zoom's tracking id (fallback: event + ts + call id)
  const eventId = req.headers.get("x-zm-trackingid") ??
    `${evt.event}:${evt.event_ts}:${evt.payload?.object?.call_id ?? ""}`;

  const { data: ins, error: insErr } = await supa
    .from("webhook_events")
    .insert({ event_id: eventId, event_type: evt.event, payload: evt })
    .select("id")
    .maybeSingle();
  if (insErr) {
    // duplicate delivery — ack so Zoom stops retrying
    return new Response("dup", { status: 200 });
  }

  try {
    await process(evt);
    await supa.from("webhook_events")
      .update({ processed: true, processed_at: new Date().toISOString() })
      .eq("id", ins!.id);
  } catch (e) {
    await supa.from("webhook_events").update({ error: String(e) }).eq("id", ins!.id);
  }
  return new Response("ok");
});

async function process(evt: any) {
  const type: string = evt.event;
  const obj = evt.payload?.object ?? {};

  if (type === "phone.caller_ended" || type === "phone.callee_ended") {
    // Outbound calls: caller is our seat, callee is the lead.
    const callee = norm(obj.callee?.phone_number ?? obj.callee?.did_number);
    const callerNum = norm(obj.caller?.phone_number ?? obj.caller?.did_number);
    if (!callee) return;

    const answered = !!obj.answer_start_time;
    const endT = obj.call_end_time ? Date.parse(obj.call_end_time) : Date.now();
    const ansT = obj.answer_start_time ? Date.parse(obj.answer_start_time) : null;
    const duration = ansT ? Math.max(0, Math.round((endT - ansT) / 1000)) : 0;

    const { data: leads } = await supa.from("leads").select("id").eq("phone_norm", callee).limit(1);
    if (!leads?.length) return;
    const leadId = leads[0].id;

    // Latest unmatched attempt for this lead in the last 20 minutes
    const cutoff = new Date(Date.now() - 20 * 60 * 1000).toISOString();
    const { data: atts } = await supa
      .from("attempts")
      .select("id, disposition")
      .eq("lead_id", leadId)
      .eq("matched", false)
      .gte("clicked_at", cutoff)
      .order("clicked_at", { ascending: false })
      .limit(1);
    if (!atts?.length) return;
    const att = atts[0];

    const patch: Record<string, unknown> = {
      matched: true,
      zoom_call_id: obj.call_id ?? obj.id ?? null,
      number_used: callerNum || null,
      duration_seconds: duration,
      call_result: answered ? "answered" : "not_answered",
    };
    // If the agent never logged it (rare — they one-key most calls),
    // auto-log the obvious non-connects so the record is complete.
    if (!att.disposition && !answered) {
      patch.disposition = "no_answer";
      patch.auto_logged = true;
      patch.connected = false;
      patch.disposed_at = new Date().toISOString();
    }
    await supa.from("attempts").update(patch).eq("id", att.id);

    if (callerNum) {
      await supa.rpc("bump_number_stats", { p_number: callerNum, p_connect: answered });
    }
  }

  if (type === "phone.ai_call_summary_changed") {
    // Fork 1-B is gated: only ingest when the tenant test proved silence and
    // the manager flipped ai_summaries_enabled to true.
    const { data: s } = await supa.from("app_settings").select("value")
      .eq("key", "ai_summaries_enabled").maybeSingle();
    const enabled = s?.value === true || s?.value === "true";
    if (!enabled) return;

    const callId = obj.call_id ?? obj.call_log_id ?? null;
    if (!callId) return;
    const summary = {
      summary: obj.call_summary ?? obj.summary ?? null,
      next_steps: obj.next_steps ?? null,
      detail: obj.detailed_summary ?? null,
      raw: obj,
      at: new Date().toISOString(),
    };
    await supa.from("attempts")
      .update({ ai_summary: summary })
      .eq("zoom_call_id", callId);
  }
}
