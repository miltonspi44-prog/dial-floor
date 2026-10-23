// Dial Floor · floor-ai — Gemini's analysis of the floor (migration 0043).
//
// pg_cron (12:35 UTC daily) and a manager's "Ask Gemini" button both go through
// ai_brief_request(), which POSTs here with the shared cron secret in the
// x-cron-secret header, the same gate sync-console uses; verify_jwt is off
// because the call comes from the database, not a browser.
//
// Each run: the aggregated snapshot (ai_floor_snapshot — rates, counts and
// lifts only, no lead names, numbers or notes), Gemini's analysis of it, and one
// row in ai_briefs either way, so the AI page can say what happened. The lead
// scores it reads are the hourly job's: rescoring every lead takes longer than
// the API's statement timeout allows, so it is not done from here.
//
// Secrets (Supabase → Edge Functions → Secrets; shared by every function):
//   GEMINI_API_KEY  from Google AI Studio (never in the repo)
//   CRON_SECRET     already set for sync-console; the same value is in Vault
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY arrive built in.
import { createClient } from "npm:@supabase/supabase-js@2";
import { generateBrief } from "./gemini.mjs";

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

  async function record(row: Record<string, unknown>) {
    const { error } = await supa.from("ai_briefs").insert({ source, requested_by: requestedBy, ...row });
    if (error) console.error(`floor-ai: could not record the run: ${error.message}`);
  }

  const apiKey = Deno.env.get("GEMINI_API_KEY") ?? "";
  if (!apiKey) {
    await record({ ok: false, error: "GEMINI_API_KEY is not set. Add it in Supabase → Edge Functions → Secrets, then ask again." });
    return json({ ok: false, why: "no GEMINI_API_KEY" });
  }

  try {
    const { data: snapshot, error: snapErr } = await supa.rpc("ai_floor_snapshot");
    if (snapErr) throw new Error(`reading the floor failed: ${snapErr.message}`);
    const { data: setting } = await supa.from("app_settings").select("value").eq("key", "ai").maybeSingle();
    const model = String((setting?.value as { model?: string } | null)?.model ?? "").trim();

    const out = await generateBrief({ apiKey, model, snapshot });
    await record({ ok: true, model: out.model, brief: out.brief });
    return json({ ok: true, model: out.model });
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e)).slice(0, 500);
    console.error(`floor-ai: ${msg}`);
    await record({ ok: false, error: msg });
    return json({ ok: false, why: msg });
  }
});
