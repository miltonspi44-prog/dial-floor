// Dial Floor · floor-ai — Gemini's analysis of the floor (migration 0043).
//
// pg_cron (12:35 UTC daily) and a manager's "Ask Gemini" button both go through
// ai_brief_request(), and a message in the AI page's conversation through
// ai_chat_send() (0044); each POSTs here with the shared cron secret in the
// x-cron-secret header, the same gate sync-console uses; verify_jwt is off
// because the call comes from the database, not a browser.
//
// An analysis: the aggregated snapshot (ai_floor_snapshot — rates, counts and
// lifts only, no lead names, numbers or notes) with what the manager has taught
// (ai_memory — lessons, verdicts and misses by traits only, and corrections),
// Gemini's analysis of it, and one row in ai_briefs either way, so the AI page
// can say what happened. A chat message ({"task": "chat", "thread": n}): the
// same snapshot and memory, the conversation so far, and Gemini's reply (with
// any lessons it proposes) as the next row in ai_chat, or why there is none.
// The lead scores it reads are the minute job's: rescoring every lead takes
// longer than the API's statement timeout allows, so it is not done from here.
// The model that answered last is asked first next time (app_settings
// ai_last_good), so a newest model that keeps refusing costs nothing.
//
// Secrets (Supabase → Edge Functions → Secrets; shared by every function):
//   GEMINI_API_KEY  from Google AI Studio (never in the repo)
//   CRON_SECRET     already set for sync-console; the same value is in Vault
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY arrive built in.
import { createClient } from "npm:@supabase/supabase-js@2";
import { generateBrief, generateChat, probe } from "./gemini.mjs";

const supa = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

function sameSecret(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a), y = enc.encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, why: "POST only" }, 405);
  const secret = Deno.env.get("CRON_SECRET") ?? "";
  if (!secret || !sameSecret(req.headers.get("x-cron-secret") ?? "", secret)) {
    return json({ ok: false, why: "unauthorized" }, 401);
  }
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* an empty body is a cron run */ }
  const source = body.source === "manual" ? "manual" : "cron";
  const requestedBy = typeof body.requested_by === "string" && UUID.test(body.requested_by) ? body.requested_by : null;
  const thread = body.task === "chat" && Number.isInteger(body.thread) ? body.thread as number : null;

  async function record(row: Record<string, unknown>) {
    const { error } = await supa.from("ai_briefs").insert({ source, requested_by: requestedBy, ...row });
    if (error) console.error(`floor-ai: could not record the run: ${error.message}`);
  }
  async function reply(row: Record<string, unknown>) {
    const { error } = await supa.from("ai_chat").insert({ thread, role: "ai", ...row });
    if (error) console.error(`floor-ai: could not record the reply: ${error.message}`);
  }
  if (body.task === "chat" && thread == null) return json({ ok: false, why: "a chat needs its thread" }, 400);

  const apiKey = Deno.env.get("GEMINI_API_KEY") ?? "";
  if (!apiKey) {
    const why = "GEMINI_API_KEY is not set. Add it in Supabase → Edge Functions → Secrets, then ask again.";
    if (thread != null) await reply({ error: why }); else await record({ ok: false, error: why });
    return json({ ok: false, why: "no GEMINI_API_KEY" });
  }
  // {"probe": true}: how the key's Flash models respond, for when one will not
  if (body.probe === true) {
    const { data: snapshot } = await supa.rpc("ai_floor_snapshot");
    return json(await probe({ apiKey, snapshot }));
  }

  try {
    // a chat is answered only when the manager spoke last (a repeated call finds it answered)
    let history: Record<string, unknown>[] = [];
    if (thread != null) {
      const { data: rows, error: chatErr } = await supa.from("ai_chat").select("role, text, proposals, error")
        .eq("thread", thread).order("id", { ascending: false }).limit(24);
      if (chatErr) throw new Error(`reading the conversation failed: ${chatErr.message}`);
      history = (rows ?? []).reverse();
      if (history[history.length - 1]?.role !== "manager") return json({ ok: false, why: "nothing to answer" });
    }

    const { data: snapshot, error: snapErr } = await supa.rpc("ai_floor_snapshot");
    if (snapErr) throw new Error(`reading the floor failed: ${snapErr.message}`);
    const { data: taught, error: memErr } = await supa.rpc("ai_memory");
    if (memErr) throw new Error(`reading what you taught failed: ${memErr.message}`);
    const floor = { ...(snapshot as Record<string, unknown>), taught };
    const { data: settings } = await supa.from("app_settings").select("key, value").in("key", ["ai", "ai_last_good"]);
    const val = (k: string) => (settings ?? []).find((r) => r.key === k)?.value as Record<string, unknown> | undefined;
    const model = String(val("ai")?.model ?? "").trim();
    const last = val("ai_last_good");
    const prefer = last && Date.now() - Date.parse(String(last.at)) < 3 * 86_400_000 ? String(last.model ?? "") || null : null;
    const remember = (m: string) =>
      supa.from("app_settings").upsert({ key: "ai_last_good", value: { model: m, at: new Date().toISOString() } });

    if (thread != null) {
      const out = await generateChat({ apiKey, model, prefer, snapshot: floor, history });
      await reply({ text: out.chat.reply, proposals: { lessons: out.chat.lessons, lists: out.chat.lists }, model: out.model });
      await remember(out.model);
      return json({ ok: true, model: out.model });
    }
    const out = await generateBrief({ apiKey, model, prefer, snapshot: floor });
    await record({ ok: true, model: out.model, brief: out.brief });
    await remember(out.model);
    return json({ ok: true, model: out.model });
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e)).slice(0, 1500);
    console.error(`floor-ai: ${msg}`);
    if (thread != null) await reply({ error: msg }); else await record({ ok: false, error: msg });
    return json({ ok: false, why: msg });
  }
});
