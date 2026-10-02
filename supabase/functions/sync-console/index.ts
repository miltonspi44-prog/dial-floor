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
// one that is still going (or died mid-flight; 20 minutes is the lease). The
// same goes for a refused password: refusal.mjs keeps that in sync_runs too.
//
// A push with nothing waiting is answered without a run: cron asks every
// minute, and logging each empty one would add 1,440 rows a day saying nothing.
import { createClient } from "npm:@supabase/supabase-js@2";
import { initSupa, logRun, supa } from "./vendor/supa.mjs";
import { pull } from "./vendor/pull-leads.mjs";
import { push } from "./vendor/push-status.mjs";
import { isAuthFailure, passwordIsRefused } from "./vendor/console.mjs";
import { fingerprint, markRefusal, REFUSAL_RETRY_H, refusedAt } from "./refusal.mjs";

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

async function somethingToPush(): Promise<boolean> {
  const { data, error } = await supa.from("lead_state").select("lead_id")
    .eq("writeback_done", false).not("writeback_status", "is", null).limit(1);
  if (error) throw error;
  return (data ?? []).length > 0;
}

// After a refusal every later run is turned away before it is logged, so the
// marked run is always among the newest failures.
async function recentFailures() {
  const since = new Date(Date.now() - REFUSAL_RETRY_H * 3_600_000).toISOString();
  const { data, error } = await supa.from("sync_runs").select("started_at, detail")
    .eq("ok", false).gt("started_at", since)
    .order("started_at", { ascending: false }).limit(50);
  if (error) throw error;
  return data ?? [];
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET") ?? "";
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!secret || !sameSecret(given, secret)) {
    return new Response(JSON.stringify({ error: "no" }), { status: 401 });
  }
  const password = Deno.env.get("CONSOLE_PASSWORD") ?? "";
  if (!password) {
    // Deliberately a 200: cron will call again anyway, and a red run every
    // minute before the owner has added the secret would only shout.
    return new Response(JSON.stringify({ skipped: "CONSOLE_PASSWORD is not set yet" }), { status: 200 });
  }
  if (passwordIsRefused()) {
    // This instance learned the password is wrong; it never asks again, and the
    // mark refusal.mjs leaves in sync_runs stops every other instance too.
    return new Response(JSON.stringify({ skipped: "the console refused the password; fix the secret" }), { status: 200 });
  }

  let task = "push";
  try { task = String((await req.json())?.task ?? "push"); } catch { /* empty body = push */ }
  if (!["pull", "push"].includes(task)) {
    return new Response(JSON.stringify({ error: `unknown task ${task}` }), { status: 400 });
  }

  try {
    if (task === "push" && !(await somethingToPush())) {
      return new Response(JSON.stringify({ ok: true, task, rows: 0, idle: true }), { status: 200 });
    }
    const fp = await fingerprint(password, secret);
    const refused = refusedAt(await recentFailures(), fp);
    if (refused) {
      return new Response(JSON.stringify({
        skipped: `the console refused this CONSOLE_PASSWORD at ${refused}; set the right one on the ` +
          "function and the next run tries it (the same one is tried again once a day)",
      }), { status: 200 });
    }
    if (await busy()) {
      return new Response(JSON.stringify({ skipped: "a sync is already running" }), { status: 200 });
    }
    const kind = task === "pull" ? "pull_leads" : "push_status";
    const work = task === "pull" ? pull : push;
    const rows = await logRun(kind, async () => {
      try {
        return await work();
      } catch (e) {
        throw markRefusal(e, fp);
      }
    });
    return new Response(JSON.stringify({ ok: true, task, rows }), { status: 200 });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // An auth refusal is final for this password (console.mjs remembers it here,
    // the run's mark everywhere else); anything else is the console having a
    // minute, and cron retries anyway.
    const status = isAuthFailure(e) ? 200 : 500;
    return new Response(JSON.stringify({ ok: false, task, error: msg }), { status });
  }
});
