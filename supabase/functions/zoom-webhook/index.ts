// Dial Floor · Zoom webhook ingest (Supabase Edge Function)
// Handles: endpoint.url_validation, phone.caller_ended / phone.callee_ended,
// phone.ai_call_summary_changed. Verifies Zoom's v0 HMAC signature, refuses
// stale (replayed) requests, dedupes, stores the raw event, then matches it to
// the click-to-dial attempt and counts the call towards number health.
//
// A delivery that fails for a reason that might not fail next time answers 500
// so Zoom retries it; a delivery we deliberately do nothing with answers 200
// with the reason kept on the row.
//
// Required function secrets:
//   ZOOM_WEBHOOK_SECRET_TOKEN  (from the Zoom app's Features > Event Subscriptions)
//   ZOOM_ACCOUNT_ID / ZOOM_CLIENT_ID / ZOOM_CLIENT_SECRET  (the S2S OAuth app; only
//     needed for AI call summaries, whose text is fetched from the Phone API)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "npm:@supabase/supabase-js@2";

const supa = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const SECRET = Deno.env.get("ZOOM_WEBHOOK_SECRET_TOKEN") ?? "";
const ZOOM_ACCOUNT_ID = Deno.env.get("ZOOM_ACCOUNT_ID") ?? "";
const ZOOM_CLIENT_ID = Deno.env.get("ZOOM_CLIENT_ID") ?? "";
const ZOOM_CLIENT_SECRET = Deno.env.get("ZOOM_CLIENT_SECRET") ?? "";
// overridable only so tests can point them at a stand-in
const ZOOM_OAUTH_URL = Deno.env.get("ZOOM_OAUTH_URL") ?? "https://zoom.us/oauth/token";
const ZOOM_API = Deno.env.get("ZOOM_API_BASE") ?? "https://api.zoom.us/v2";

// A signature stays valid for as long as the secret does, so a request captured
// today would still verify next year. Refusing anything signed longer ago than
// this is what stops a captured request being replayed.
const SIGNATURE_MAX_AGE_MS = 5 * 60 * 1000;

// How far apart the click and Zoom's ringing start may be and still be the same
// call. The click writes the attempt row a moment before Zoom starts ringing, so
// this stays small on purpose: a wider window would start attaching a call to
// some earlier dial of the same number.
const MATCH_TOLERANCE_MS = 2 * 60 * 1000;

// Only used when an event carries no call times at all (see findAttempt).
const FALLBACK_WINDOW_MS = 20 * 60 * 1000;

// Server-to-server OAuth: one account-level token, reused until it nears expiry.
let zoomToken: { value: string; until: number } | null = null;
async function zoomApi(path: string): Promise<any> {
  if (!ZOOM_ACCOUNT_ID || !ZOOM_CLIENT_ID || !ZOOM_CLIENT_SECRET) {
    throw new Error("ZOOM_ACCOUNT_ID / ZOOM_CLIENT_ID / ZOOM_CLIENT_SECRET are not set, so the summary text can't be fetched");
  }
  if (!zoomToken || zoomToken.until < Date.now() + 60_000) {
    const res = await fetch(`${ZOOM_OAUTH_URL}?grant_type=account_credentials&account_id=${encodeURIComponent(ZOOM_ACCOUNT_ID)}`, {
      method: "POST",
      headers: { Authorization: "Basic " + btoa(`${ZOOM_CLIENT_ID}:${ZOOM_CLIENT_SECRET}`) },
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok || !j.access_token) throw new Error(`Zoom token: HTTP ${res.status} ${j.reason ?? j.error ?? ""}`.trim());
    zoomToken = { value: j.access_token, until: Date.now() + (Number(j.expires_in) || 3600) * 1000 };
  }
  const res = await fetch(`${ZOOM_API}${path}`, { headers: { Authorization: `Bearer ${zoomToken.value}` } });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Zoom API ${path}: HTTP ${res.status} ${j.message ?? ""}`.trim());
  return j;
}

async function hmacHex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(msg: string): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(msg));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// A plain !== gives up at the first character that differs, and how long that
// takes tells an attacker how much of a guessed signature was right. Looking at
// every character costs the same whatever the input.
function sameSignature(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Zoom's x-zm-request-timestamp is a Unix time: seconds in Zoom's own examples,
// milliseconds on some deliveries. Accept either rather than calling every event
// stale because the unit surprised us. NaN means the header was missing or was
// not a number, which fails the freshness check.
function requestTimeMs(raw: string): number {
  const n = Number(raw);
  if (!raw || !Number.isFinite(n) || n <= 0) return NaN;
  return n > 1e11 ? n : n * 1000;
}

function norm(p?: string | null): string {
  const d = (p ?? "").replace(/\D/g, "");
  return d.length === 11 && d.startsWith("1") ? d.slice(1) : d;
}

// Dedupe on something Zoom signed. The x-zm-trackingid header this used to key
// on sits outside the signed message, so anyone replaying a captured request
// could put a fresh tracking id on it and it would look like a brand new event.
// The event name, the call it is about and Zoom's own event_ts are all inside
// the signed body.
async function dedupeKey(evt: any, body: string): Promise<string> {
  const obj = evt.payload?.object ?? {};
  const call = obj.call_id ?? obj.call_log_id ?? obj.id ?? "";
  // Nothing in the event names a call, which we don't expect: a hash of the body
  // still tells two events apart where the name and timestamp alone might not.
  return `${evt.event}:${evt.event_ts ?? ""}:${call || await sha256Hex(body)}`;
}

Deno.serve(async (req) => {
  // Nothing can be validated or verified until the secret is set (an empty
  // HMAC key throws, which used to surface as a 500 on every request)
  if (!SECRET) return new Response("ZOOM_WEBHOOK_SECRET_TOKEN is not set", { status: 503 });

  const body = await req.text();
  let evt: any;
  try { evt = JSON.parse(body); } catch { return new Response("bad json", { status: 400 }); }

  // Zoom's URL validation handshake
  if (evt.event === "endpoint.url_validation") {
    const plain = evt.payload?.plainToken ?? "";
    return Response.json({ plainToken: plain, encryptedToken: await hmacHex(SECRET, plain) });
  }

  // Signature check on every real event, and the timestamp inside the signed
  // message has to be recent: see SIGNATURE_MAX_AGE_MS.
  const ts = req.headers.get("x-zm-request-timestamp") ?? "";
  const signedAt = requestTimeMs(ts);
  if (!Number.isFinite(signedAt) || Math.abs(Date.now() - signedAt) > SIGNATURE_MAX_AGE_MS) {
    return new Response("request timestamp missing or too old", { status: 401 });
  }
  const sig = req.headers.get("x-zm-signature") ?? "";
  const expect = "v0=" + await hmacHex(SECRET, `v0:${ts}:${body}`);
  if (!sameSignature(sig, expect)) return new Response("bad signature", { status: 401 });

  const eventId = await dedupeKey(evt, body);

  let rowId: number;
  const { data: ins, error: insErr } = await supa
    .from("webhook_events")
    .insert({ event_id: eventId, event_type: evt.event, payload: evt })
    .select("id")
    .maybeSingle();
  if (insErr) {
    // anything but a duplicate: fail so Zoom retries, rather than dropping the event
    if (insErr.code !== "23505") return new Response("could not store the event", { status: 500 });
    // We have this event already. If the earlier delivery finished with it, this
    // is a plain duplicate and we ack it so Zoom stops. If it didn't finish —
    // it failed on something that might work now, and we asked Zoom to try
    // again — then this delivery is that second chance, so pick the row up and
    // run it. Without this the retry we asked for would be turned away here.
    const { data: seen, error: seenErr } = await supa
      .from("webhook_events").select("id, processed").eq("event_id", eventId).maybeSingle();
    if (seenErr || !seen) return new Response("could not read the earlier delivery", { status: 500 });
    if (seen.processed) return new Response("duplicate, already handled");
    rowId = seen.id;
  } else {
    rowId = ins!.id;
  }

  try {
    const nothingToDo = await process(evt);
    // processed = false is how a row says "this still needs doing", so it only
    // turns true once the work is really done. A plain sentence in error next to
    // processed = true means we read the event and deliberately did nothing.
    const { error: doneErr } = await supa.from("webhook_events")
      .update({ processed: true, processed_at: new Date().toISOString(), error: nothingToDo })
      .eq("id", rowId);
    if (doneErr) throw doneErr;
    return new Response(nothingToDo ?? "ok");
  } catch (e) {
    // This might work on a later try (a database error, Zoom's API down), so
    // leave processed = false and answer 500: Zoom retries anything that isn't
    // 2xx, and the row stays visible as unfinished for a later sweep.
    await supa.from("webhook_events").update({ error: String(e) }).eq("id", rowId);
    return new Response("could not handle this event yet", { status: 500 });
  }
});

// What became of one delivery. Null means the work is done. A short sentence
// means we read the event and there was deliberately nothing to do, and it gets
// kept on the row so a manager can see why nothing happened. Anything that
// might work on a later try throws instead, and the caller turns that into a
// retry rather than a silent "ok".
async function process(evt: any): Promise<string | null> {
  const type: string = evt.event;
  const obj = evt.payload?.object ?? {};

  if (type === "phone.caller_ended" || type === "phone.callee_ended") return await onCallEnded(type, obj);
  if (type === "phone.ai_call_summary_changed") return await onCallSummary(obj);
  return "we do not act on this kind of event";
}

async function onCallEnded(type: string, obj: any): Promise<string | null> {
  // Zoom reports both halves of a call and this floor also takes calls IN on
  // extension 800, so which way the call went has to be worked out from the
  // call itself rather than assumed from the event name. On a call we placed the
  // caller is one of our Zoom seats and the callee is the lead's outside line;
  // on a call that came to us Zoom marks the caller extension_type 'pstn' (an
  // outside line) and the callee is one of our own extensions. Only calls we
  // placed can belong to a dial, and only they say anything about whether a
  // carrier has started labelling our number.
  //
  // The callee test also insists Zoom is not calling that side an outside line:
  // if Zoom ever puts an extension number on an external callee, a call we
  // placed must still read as ours rather than silently stop matching.
  const callerIsOutsideLine = String(obj.caller?.extension_type ?? "").toLowerCase() === "pstn";
  const calleeIsOneOfOurs = !!obj.callee?.extension_number &&
    String(obj.callee?.extension_type ?? "").toLowerCase() !== "pstn";
  if (callerIsOutsideLine || calleeIsOneOfOurs) {
    return "this was a call to us, not one we placed, so there was nothing to record";
  }

  // Outbound calls: caller is our seat, callee is the lead.
  const callee = norm(obj.callee?.phone_number ?? obj.callee?.did_number);
  const callerNum = norm(obj.caller?.phone_number ?? obj.caller?.did_number);

  // Zoom's caller_ended events carry connected_start_time once the far end
  // picks up (person, voicemail or auto-attendant); answer_start_time is the
  // older name. Neither is present when the call rang out or was cancelled.
  const answerAt = obj.connected_start_time ?? obj.answer_start_time ?? null;
  const answered = !!answerAt;
  const endT = obj.call_end_time ? Date.parse(obj.call_end_time) : Date.now();
  const ansT = answerAt ? Date.parse(answerAt) : null;
  const duration = ansT ? Math.max(0, Math.round((endT - ansT) / 1000)) : 0;

  let matchedDial = false;
  if (callee) {
    // Every lead record with this number: the scrape can list one business twice
    const { data: leads, error: leadErr } = await supa.from("leads").select("id").eq("phone_norm", callee);
    if (leadErr) throw leadErr;
    const att = leads?.length ? await findAttempt(obj, leads.map((l) => l.id)) : null;
    if (att) {
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
      const { error: updErr } = await supa.from("attempts").update(patch).eq("id", att.id);
      // Attaching the call to the dial is the whole point of this event, so a
      // failed update has to become a retry instead of a quiet "ok".
      if (updErr) throw updErr;
      matchedDial = true;
    }
  }

  // Number health is about the caller number itself — whether carriers have
  // started labelling it — so it has to count every call we place on that
  // number, whether it was dialled from the app or straight from Zoom. Counting
  // only the calls that matched a dial left the spam check looking at three
  // calls in every hundred and seeing nothing.
  //
  // One call must be counted once, and phone.caller_ended is the copy of the
  // event from the seat that placed it; if Zoom ever also reports the callee's
  // side of a call we placed, that copy adds nothing and is left alone. The
  // stats come last so that a retry after a failure above counts the call once.
  let counted = false;
  if (type === "phone.caller_ended" && callerNum) {
    const { error } = await supa.rpc("bump_number_stats", { p_number: callerNum, p_connect: answered });
    if (error) throw error;
    counted = true;
  }

  if (!matchedDial && !counted) {
    return "this call matched no dial of ours and carried no number to count";
  }
  return null;
}

// The dial this call belongs to, or null. Zoom's phone.caller_ended arrives when
// the call ENDS, so "recent" has to mean recent next to when the call STARTED:
// a 25-minute conversation — exactly the call worth having — ends long after the
// click that began it, and looking for a click in the 20 minutes before the
// event arrived missed every one of them. Every event carries
// ringing_start_time, so we take the unmatched dial clicked closest to the
// moment the number started ringing, however long the call then ran.
async function findAttempt(obj: any, leadIds: number[]) {
  const startedAt = obj.ringing_start_time ?? obj.connected_start_time ?? obj.answer_start_time ?? null;
  const startT = startedAt ? Date.parse(startedAt) : NaN;

  const q = supa.from("attempts").select("id, disposition, clicked_at")
    .in("lead_id", leadIds).eq("matched", false);

  // No start time we can use. Rather than guess, do what this did before: the
  // newest unmatched dial of the last twenty minutes, which is right for a short
  // call and wrong for a long one, but never attaches the call to a dial that
  // started at a wholly different time.
  if (!Number.isFinite(startT)) {
    const { data, error } = await q
      .gte("clicked_at", new Date(Date.now() - FALLBACK_WINDOW_MS).toISOString())
      .order("clicked_at", { ascending: false }).limit(1);
    if (error) throw error;
    return data?.[0] ?? null;
  }

  const { data, error } = await q
    .gte("clicked_at", new Date(startT - MATCH_TOLERANCE_MS).toISOString())
    .lte("clicked_at", new Date(startT + MATCH_TOLERANCE_MS).toISOString())
    .order("clicked_at", { ascending: false }).limit(10);
  if (error) throw error;
  if (!data?.length) return null;
  // Two agents can be working the same number minutes apart, so the closest
  // click wins rather than simply the newest.
  return data.reduce((best, c) =>
    Math.abs(Date.parse(c.clicked_at) - startT) < Math.abs(Date.parse(best.clicked_at) - startT) ? c : best);
}

async function onCallSummary(obj: any): Promise<string | null> {
  // Fork 1-B is gated: only ingest when the tenant test proved silence and
  // the manager flipped ai_summaries_enabled to true.
  const { data: s, error: setErr } = await supa.from("app_settings").select("value")
    .eq("key", "ai_summaries_enabled").maybeSingle();
  // A settings read that failed must not pass for "switched off", which would
  // throw the summary away for good.
  if (setErr) throw setErr;
  const enabled = s?.value === true || s?.value === "true";
  if (!enabled) return "AI summaries are switched off, so this one was not kept";

  // A call dialed straight from Zoom has no attempt to attach to: skip it
  // before spending a Phone API request on it.
  const eventCallId = obj.call_id ?? obj.call_log_id ?? null;
  if (eventCallId) {
    const { data: att, error } = await supa.from("attempts").select("id").eq("zoom_call_id", eventCallId).limit(1);
    if (error) throw error;
    if (!att?.length) return "that call was not placed from the dialer, so there is no dial to put a summary on";
  }

  // The event ("Call Summary Changed" in the Marketplace) names the summary; its
  // text comes from the Phone API (scope phone:read:ai_call_summary:admin).
  const summaryId = obj.ai_call_summary_id ?? obj.call_summary_id ?? null;
  let detail = obj;
  if (!obj.call_summary && !obj.summary && summaryId) {
    const zoomUser = obj.user_id ?? obj.owner?.id ?? "me";
    detail = await zoomApi(`/phone/user/${encodeURIComponent(zoomUser)}/ai_call_summary/${encodeURIComponent(summaryId)}`);
  }
  const callId = detail.call_id ?? eventCallId;
  // Nothing names the call, so there is nothing to attach this to and no later
  // try would change that.
  if (!callId) return "this summary does not say which call it belongs to";
  const summary = {
    summary: detail.call_summary ?? detail.summary ?? null,
    next_steps: detail.next_steps ?? null,
    detail: detail.detailed_summary ?? null,
    summary_id: summaryId,
    raw: obj,
    at: new Date().toISOString(),
  };
  const { error } = await supa.from("attempts").update({ ai_summary: summary }).eq("zoom_call_id", callId);
  if (error) throw error;
  return null;
}
