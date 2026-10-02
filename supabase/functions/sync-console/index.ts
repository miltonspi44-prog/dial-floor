// Dial Floor · sync-console — the 15-minute loop, hosted (focus item 48).
//
// The same pull and push the PC worker runs. sync/ stays the one source of
// truth; vendor/ holds deploy-time copies made by sync/vendor-to-function.sh
// (the deploy step runs it), because the function bundle can only carry files
// that live under this folder. pg_cron (migration 0034) POSTs
// here — pushes every minute, pulls every 15 — with a shared secret in the
// x-cron-secret header; verify_jwt is off because cron carries no JWT, and the
// secret is the whole gate.
//
// Secrets this function needs (Dashboard → Edge Functions → sync-console):
//   CONSOLE_PASSWORD  the lead console's password (never in the repo)
//   CRON_SECRET       the same value 0034 stores in Vault as sync_cron_secret
//   CONSOLE_URL       only if it ever moves off leads.sedsolutions.online
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY arrive built in.
//
// One sync at a time, like the PC loop — but edge instances share no memory, so
// the guard lives in sync_runs: a run younger than 20 minutes with no finish is
// one that is still going (or died mid-flight; 20 minutes is the lease).
import { createClient } from "npm:@supabase/supabase-js@2";
import { initSupa, logRun, supa } from "./vendor/supa.mjs";
import { pull } from "./vendor/pull-leads.mjs";
import { push } from "./vendor/push-status.mjs";
import { isAuthFailure, passwordIsRefused } from "./vendor/console.mjs";

initSupa(createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
));

const BUSY_LEASE_MIN = 20;

function sameSecret(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a), y = enc.encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function busy(): Promise<boolean> {
  const since = new Date(Date.now() - BUSY_LEASE_MIN * 60_000).toISOString();
  const { data, error } = await supa.from("sync_runs").select("id")
    .is("finished_at", null).gt("started_at", since).limit(1);
  if (error) throw error;
  return (data ?? []).length > 0;
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET") ?? "";
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!secret || !sameSecret(given, secret)) {
    return new Response(JSON.stringify({ error: "no" }), { status: 401 });
  }
  if (!Deno.env.get("CONSOLE_PASSWORD")) {
    // Deliberately a 200: cron will call again anyway, and a red run every
    // minute before the owner has added the secret would only shout.
    return new Response(JSON.stringify({ skipped: "CONSOLE_PASSWORD is not set yet" }), { status: 200 });
  }
  if (passwordIsRefused()) {
    // This instance learned the password is wrong; stop burning login attempts
    // until a redeploy or new instance (where the fresh try happens once).
    return new Response(JSON.stringify({ skipped: "the console refused the password; fix the secret" }), { status: 200 });
  }

  let task = "push";
  try { task = String((await req.json())?.task ?? "push"); } catch { /* empty body = push */ }
  if (!["pull", "push"].includes(task)) {
    return new Response(JSON.stringify({ error: `unknown task ${task}` }), { status: 400 });
  }

  try {
    if (await busy()) {
      return new Response(JSON.stringify({ skipped: "a sync is already running" }), { status: 200 });
    }
    const kind = task === "pull" ? "pull_leads" : "push_status";
    const rows = await logRun(kind, task === "pull" ? pull : push);
    return new Response(JSON.stringify({ ok: true, task, rows }), { status: 200 });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // An auth refusal is final for this instance (console.mjs remembers it);
    // everything else is the console having a minute, and cron retries anyway.
    const status = isAuthFailure(e) ? 200 : 500;
    return new Response(JSON.stringify({ ok: false, task, error: msg }), { status });
  }
});
