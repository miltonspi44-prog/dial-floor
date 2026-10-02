// Dial Floor · Zoom webhook ingest (Supabase Edge Function)
// Handles: endpoint.url_validation, phone.caller_ended / phone.callee_ended,
// phone.ai_call_summary_changed. Verifies Zoom's v0 HMAC signature, refuses
// stale (replayed) requests, dedupes, stores the raw event, then matches it to
// the click-to-dial attempt and counts the call towards number health.
//
// A delivery that fails for a reason that might not fail next time answers 500
// so Zoom retries it; a delivery we deliberately do nothing with answers 200
// and keeps a short sentence about it next to the stored event.
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
// today would still verify next year, and refusing anything signed long enough
// ago is what stops a captured request being replayed.
//
// This window is deliberately loose rather than tight. We cannot see how Zoom
// signs a retry: if it replays the original signed request rather than signing a
// fresh one, a tight window would turn away every retry, and asking Zoom to try
// again is the only way a delivery that failed on a database error ever gets
// done. An hour buys back that whole retry path, and it gives up very little,
// because a captured request can no longer pretend to be a new event — the
// dedupe key is built from the signed body, so a replay can only ever land on
// the duplicate branch below, where the most it can do is finish an event we
// failed to finish. It can never add a call to the stats or invent an event.
const SIGNATURE_MAX_AGE_MS = 60 * 60 * 1000;

// How far apart the click and Zoom's ringing start may be and still be the same
// call. The window is lopsided on purpose: the click row is written the instant
// the agent presses dial and Zoom only then starts the call, so the click ALWAYS
// comes first — usually by a second, but a cold Zoom client or a browser "open
// Zoom?" prompt can hold it for minutes. Reaching a long way back costs almost
// nothing in wrong matches, because the closest click wins: a different dial of
// the same number would have to have been clicked nearer to this ring than the
// real one to beat it. Reaching forward is only to absorb clock skew between
// Zoom's clock and ours, so it stays at seconds.
const MATCH_BEFORE_MS = 10 * 60 * 1000;
const MATCH_AFTER_MS = 30 * 1000;

// How far a ringing start may sit either side of our own clock and still be
// believable for a call that just ended: see callStartMs.
//
// Backwards it has to cover the longest call we are willing to credit plus the
// longest a delivery can be held up before it reaches us — and that hold is
// exactly what the signature window above allows. So it is written as that
// window plus a call length rather than as a number of its own: a bound smaller
// than the window we accept deliveries in would call a legitimately retried
// delivery unbelievable, and written this way the two cannot drift apart again.
// Forwards is only clock skew between Zoom's clock and ours, so it stays small.
const LONGEST_CALL_MS = 2 * 60 * 60 * 1000;
const START_MAX_AGE_MS = SIGNATURE_MAX_AGE_MS + LONGEST_CALL_MS;
const START_MAX_AHEAD_MS = 2 * 60 * 1000;

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

// What went wrong, in words a person can act on. Most of what is thrown in here
// is a Supabase error, which is a plain object and not an Error, so String() on
// one gives "[object Object]" — a row that records a failure and says nothing
// about it is no better than the silence this column was added to end.
function describeError(e: unknown): string {
  if (e instanceof Error) return e.message || String(e);
  if (e && typeof e === "object") {
    const o = e as Record<string, unknown>;
    // Postgres codes come through as strings ("23505") and HTTP-ish ones as
    // numbers, so take either rather than dropping half of them.
    const str = (v: unknown) =>
      typeof v === "number" ? String(v) : typeof v === "string" && v.trim() ? v.trim() : "";
    const bits = [
      str(o.code ?? o.status) && `[${str(o.code ?? o.status)}]`,
      str(o.message),
      str(o.details),
      str(o.hint) && `(${str(o.hint)})`,
    ].filter(Boolean);
    if (bits.length) return bits.join(" ").slice(0, 800);
    // Something object-shaped we do not recognise: the whole thing beats nothing.
    try { return JSON.stringify(o).slice(0, 800); } catch { /* circular */ }
  }
  return String(e).slice(0, 800);
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

  // The signature goes first: it is the check that says this came from Zoom at
  // all, and a caller who cannot produce one has no business learning anything
  // about the timestamps we accept.
  const ts = req.headers.get("x-zm-request-timestamp") ?? "";
  const sig = req.headers.get("x-zm-signature") ?? "";
  const expect = "v0=" + await hmacHex(SECRET, `v0:${ts}:${body}`);
  if (!sameSignature(sig, expect)) return new Response("bad signature", { status: 401 });

  // Genuinely from Zoom, but the timestamp inside the signed message still has to
  // be recent enough: see SIGNATURE_MAX_AGE_MS.
  const signedAt = requestTimeMs(ts);
  if (!Number.isFinite(signedAt) || Math.abs(Date.now() - signedAt) > SIGNATURE_MAX_AGE_MS) {
    return new Response("request timestamp missing or too old", { status: 401 });
  }

  const eventId = await dedupeKey(evt, body);

  let rowId: number;
  // Winning this insert is what makes a delivery the first one. The unique index
  // on event_id lets exactly one delivery of an event in, however many arrive at
  // once and whatever order they arrive in, and Postgres decides that for us. So
  // the one thing that must happen at most once per call — adding a dial to the
  // number's health — is tied to winning here, and nothing else in the file has
  // to work out who is allowed to count (see onCallEnded). A delivery that loses
  // still finishes whatever is left to attach.
  let firstDelivery = true;
  const { data: ins, error: insErr } = await supa
    .from("webhook_events")
    .insert({ event_id: eventId, event_type: evt.event, payload: evt })
    .select("id")
    .maybeSingle();
  if (insErr) {
    // anything but a duplicate: fail so Zoom retries, rather than dropping the event
    if (insErr.code !== "23505") return new Response("could not store the event", { status: 500 });
    // We have this event already. If the earlier delivery finished with it there
    // is nothing left to do, and saying so with a 200 is what stops Zoom
    // retrying an event we handled perfectly well. If it did not finish, it
    // failed on something that might work now and we asked Zoom to try again —
    // so this delivery is that second chance and runs the work again.
    const { data: prior, error: priorErr } = await supa
      .from("webhook_events").select("id, processed").eq("event_id", eventId).maybeSingle();
    // A read that fails, or finds nothing where the unique index just said there
    // was something, tells us nothing about whether the event was handled; ask
    // Zoom again rather than guess.
    if (priorErr || !prior) return new Response("could not read the earlier delivery", { status: 500 });
    if (prior.processed) return new Response("duplicate, this event was already handled");
    rowId = prior.id;
    firstDelivery = false;
  } else {
    rowId = ins!.id;
  }

  try {
    const outcome = await process(evt, firstDelivery);
    // processed = false is how a row says "this still needs doing", so it only
    // turns true once the work is really done, and a failure left over from an
    // earlier try is cleared now that the event is handled.
    //
    // A note about what we did goes next to the event, not in error: error is how
    // someone finds the deliveries that need a person ("where error is not
    // null"), and filling it with sentences about events we handled perfectly
    // well would bury them. Every field Zoom sent stays where it was. The payload
    // is written whether or not there is a note, so a note from a delivery that
    // failed earlier cannot stay there contradicting the finished row.
    const { error: doneErr } = await supa.from("webhook_events").update({
      processed: true,
      processed_at: new Date().toISOString(),
      error: null,
      payload: outcome ? { ...evt, dial_floor_outcome: outcome } : evt,
    }).eq("id", rowId);
    if (doneErr) throw doneErr;
    return new Response(outcome ?? "ok");
  } catch (e) {
    // This might work on a later try (a database error, Zoom's API down), so
    // leave processed = false and answer 500: Zoom retries anything that isn't
    // 2xx, the row stays visible as unfinished for a later sweep, and the retry
    // carries on from wherever this delivery stopped.
    await supa.from("webhook_events").update({ error: describeError(e) }).eq("id", rowId);
    return new Response("could not handle this event yet", { status: 500 });
  }
});

// What became of one delivery. Null means the call was attached to a dial and
// counted with nothing worth remarking on. A short sentence means anything else
// — deliberately nothing to do, or done but not the whole job — and it gets kept
// next to the event so a manager can see why. Anything that might work on a
// later try throws instead, and the caller turns that into a retry rather than a
// silent "ok".
//
// firstDelivery is false when an earlier delivery of this same event got here
// first and did not finish; everything that can safely be done twice is done
// again, and the one thing that cannot — counting the call — is not.
async function process(evt: any, firstDelivery: boolean): Promise<string | null> {
  const type: string = evt.event;
  const obj = evt.payload?.object ?? {};

  if (type === "phone.caller_ended" || type === "phone.callee_ended") return await onCallEnded(type, obj, firstDelivery);
  if (type === "phone.ai_call_summary_changed") return await onCallSummary(obj);
  return "we do not act on this kind of event";
}

async function onCallEnded(type: string, obj: any, firstDelivery: boolean): Promise<string | null> {
  // Zoom reports both halves of a call and this floor also takes calls IN on
  // extension 800, so which way the call went has to be worked out from the call
  // itself rather than assumed from the event name. Only a call we placed to an
  // outside number can belong to a dial, and only that call says anything about
  // whether a carrier has started labelling our number.
  //
  // Both sides have to agree before we call it one of ours: the caller is one of
  // our own Zoom seats — Zoom marks those with an extension number and an
  // extension_type that is anything but 'pstn', an outside line — and the other
  // side is not also one of our seats. Testing only the caller let an internal
  // seat-to-seat call, one agent ringing another, read as a call we placed, and it
  // added a dial on a number no carrier ever carried. That is the very signal the
  // spam check and the number-health board are built on.
  //
  // What this gives up: if Zoom puts an extension number on the lead's side of a
  // real outbound call, that call reads as internal and nothing is recorded for
  // it. Nothing in the payload tells those two shapes apart, and a dial left
  // waiting for Zoom costs less than a dial count nobody can trust. The delivery
  // says which way it went next to the stored event, so it stays visible.
  const callerExtType = String(obj.caller?.extension_type ?? "").toLowerCase();
  const callerIsOneOfOurs = !!obj.caller?.extension_number && callerExtType !== "pstn";
  const calleeIsOneOfOurs = !!obj.callee?.extension_number &&
    String(obj.callee?.extension_type ?? "").toLowerCase() !== "pstn";
  if (!callerIsOneOfOurs || calleeIsOneOfOurs) {
    return "this was not a call one of our seats placed to an outside number, so there was nothing to record";
  }

  // Zoom reports a call we placed from both ends, and the two copies describe one
  // call. Whichever arrived first would attach it to the dial and stamp the call
  // id, and the other would then find the work already done — so the outcome
  // depended on an arrival order Zoom does not promise. Everything is done from
  // one copy instead, the one from the seat that placed the call. The price is
  // that a call whose caller_ended delivery never arrives is not recorded at all,
  // which shows as a dial still waiting for Zoom.
  if (type !== "phone.caller_ended") {
    return "this is Zoom's copy of the call from the other side; a call we placed is recorded from the side that placed it";
  }

  // Outbound calls: caller is our seat, callee is the lead.
  const callee = norm(obj.callee?.phone_number ?? obj.callee?.did_number);
  const callerNum = norm(obj.caller?.phone_number ?? obj.caller?.did_number);
  const callId = obj.call_id ?? obj.id ?? null;

  // If a dial already carries this call id then a delivery of this call got as
  // far as attaching it and there is nothing left to attach. This is what keeps
  // one call off two different dials: a second delivery that looked for a match
  // again would find the first dial already matched, take the next closest click
  // instead, and put this call's result on a dial that belongs to another call.
  //
  // It answers that one question and nothing else. It used to return here, which
  // decided the counting as well: in a race the delivery that attaches the call is
  // not always the delivery allowed to count it, so the one that was stopped here
  // and the call ended up counted by nobody. Who may count is settled in one
  // place, by the insert at the top of the file.
  //
  // It runs on every call-ended delivery rather than only on the deliveries that
  // could race, because working out which of those a delivery is takes an
  // argument about arrival orders and this takes a query — an indexed one, now
  // that 0026 gave zoom_call_id its own partial index.
  let alreadyAttached = false;
  if (callId) {
    const { data: prior, error: priorErr } = await supa.from("attempts")
      .select("id").eq("zoom_call_id", callId).limit(1);
    if (priorErr) throw priorErr;
    alreadyAttached = !!prior?.length;
  }

  // Zoom's caller_ended events carry connected_start_time once the far end
  // picks up (person, voicemail or auto-attendant); answer_start_time is the
  // older name. Neither is present when the call rang out or was cancelled.
  const answerAt = obj.connected_start_time ?? obj.answer_start_time ?? null;
  const answered = !!answerAt;
  const endT = obj.call_end_time ? Date.parse(obj.call_end_time) : Date.now();
  const ansT = answerAt ? Date.parse(answerAt) : null;
  const duration = ansT ? Math.max(0, Math.round((endT - ansT) / 1000)) : 0;

  // When the number started ringing, which is what a dial is matched against.
  // NaN means there is no start time we can believe, and then no dial is looked
  // for at all rather than guessed at: see callStartMs.
  const startT = callStartMs(obj);

  let matchedDial = false;
  let noDial = "no dial of ours matched this call";
  if (alreadyAttached) {
    noDial = "a dial of ours already carries this call, so there was nothing left to attach";
  } else if (!callee) {
    noDial = "the event named no number for the other side, so no dial was looked for";
  } else if (!Number.isFinite(startT)) {
    noDial = "the event gave no start time we could place on our own clock, so no dial was looked for";
  } else {
    // Every lead record with this number: the scrape can list one business twice
    const { data: leads, error: leadErr } = await supa.from("leads").select("id").eq("phone_norm", callee);
    if (leadErr) throw leadErr;
    const att = leads?.length ? await findAttempt(startT, leads.map((l) => l.id)) : null;
    if (att) {
      const patch: Record<string, unknown> = {
        matched: true,
        zoom_call_id: callId,
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
  // One call must be counted once, and the delivery that won the insert at the top
  // of the file is the only delivery of this event allowed to do it. A later
  // delivery of the same event cannot tell whether the first one got as far as
  // counting, so it does not count at all: the floor can end up one dial short of
  // a call whose first delivery failed before it counted. That is the right way
  // round to be wrong — a missing dial nudges a rate, an extra one invents an
  // alert about a number nobody has a problem with. The stats come last so that
  // the dial, which is what an agent is actually looking at, is attached before
  // anything else has a chance to fail.
  let counted = false;
  if (firstDelivery && callerNum) {
    const { error } = await supa.rpc("bump_number_stats", { p_number: callerNum, p_connect: answered });
    if (error) throw error;
    counted = true;
  }

  if (matchedDial && counted) return null;
  // Anything short of that is worth a line next to the event. The floor dials
  // plenty straight from Zoom and those calls count towards the number's health
  // without belonging to any dial, so a call with no dial behind it has to be
  // tellable apart from one we simply failed to attach.
  const countPart = counted
    ? "counted towards the number's health"
    : firstDelivery
      ? "the event carried no number of ours to count"
      : "not counted again, because an earlier delivery of this event had it first";
  return `${matchedDial ? "attached to a dial" : noDial}; ${countPart}`;
}

// The moment the number started ringing, or NaN when the event gives no start
// time we can believe.
//
// Zoom renders some times without their zone offset ("2026-10-01 12:17:02").
// Those parse perfectly well and land a whole timezone away from the call they
// describe, and nothing in the payload says it happened. What we can check is
// whether the time is where a call that has just ended has to be: not ahead of
// our clock by more than skew, and not older than the longest call plus the
// longest a delivery can be held up on the way to us.
//
// A time outside that is not used, and then nothing is attached: the dial shows
// as still waiting for Zoom, which is the cheap way to be wrong. Reaching for
// whatever dial of that number happened to be open instead is how one agent's
// result lands on another agent's dial — and that loses the real result for good,
// because the dial it belonged to is now taken.
function callStartMs(obj: any): number {
  const startedAt = obj.ringing_start_time ?? obj.connected_start_time ?? obj.answer_start_time ?? null;
  const startT = startedAt ? Date.parse(startedAt) : NaN;
  if (!Number.isFinite(startT)) return NaN;
  const now = Date.now();
  if (startT > now + START_MAX_AHEAD_MS || startT < now - START_MAX_AGE_MS) return NaN;
  return startT;
}

// The dial this call belongs to, or null. Zoom's phone.caller_ended arrives when
// the call ENDS, so "recent" has to mean recent next to when the call STARTED:
// a 25-minute conversation — exactly the call worth having — ends long after the
// click that began it, and looking for a click in the 20 minutes before the
// event arrived missed every one of them. So we take the unmatched dial clicked
// closest to the moment the number started ringing, however long the call then
// ran. No unmatched dial in that window means there is none to find — the call
// was dialled straight from Zoom — and the answer is honestly nothing.
async function findAttempt(startT: number, leadIds: number[]) {
  // Everything in the window, with no row cap: the closest click is the answer,
  // and keeping only the newest handful would throw it away before the comparison
  // ran. This is one number's unmatched clicks inside a few minutes, so there is
  // nothing here to cap.
  const { data, error } = await supa.from("attempts").select("id, disposition, clicked_at")
    .in("lead_id", leadIds).eq("matched", false)
    .gte("clicked_at", new Date(startT - MATCH_BEFORE_MS).toISOString())
    .lte("clicked_at", new Date(startT + MATCH_AFTER_MS).toISOString());
  if (error) throw error;
  if (!data?.length) return null;
  // Two agents can be working the same number minutes apart, so the closest
  // click wins rather than simply the newest.
  return data.reduce((best, c) => {
    const d = Math.abs(Date.parse(c.clicked_at) - startT);
    const bd = Math.abs(Date.parse(best.clicked_at) - startT);
    if (d < bd) return c;
    // Two clicks the same distance either side of the ring: take the earlier
    // one, because a click always comes before the ring it started.
    if (d === bd && Date.parse(c.clicked_at) < Date.parse(best.clicked_at)) return c;
    return best;
  });
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
