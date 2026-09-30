// admin-users: managers add, remove and manage logins from the app's Users tab.
//
// Creating, deleting and resetting logins needs Supabase's service key (the Auth
// admin API), so it happens here and never in the browser. Every call must carry
// the session of a signed-in, active manager.
//
//   create          {email, name, role, password?}  → {id, email, password?}
//   reset_password  {user_id, password?}            → {password?}
//   set_email       {user_id, email}                → {email}
//   remove          {user_id}                       → {deleted} | {removed}
//   restore         {user_id}                       → {restored}
//
// A password left blank is generated and returned once, for the manager to hand
// over; it is never logged. "remove" deletes a login outright only when nothing
// references it; anyone with calls or records on file is removed instead: the
// login is blocked and they are taken off the floor, and every report keeps their
// history. Names, roles and on/off-the-floor go through the set_member RPC.

import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "https://dialer.sedsolutions.online,http://localhost:5173")
  .split(",").map((s) => s.trim()).filter(Boolean);
const BLOCKED = "876000h"; // ~100 years: a removed login stays blocked until restored
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(origin) ? origin : ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

/** 12 random characters with no look-alikes (0/O, 1/l/I), shown as xxxx-xxxx-xxxx.
 *  Always a lower, an upper and a digit (the dashes add a symbol), so it passes
 *  any password rule the project's Auth settings may require. */
function newPassword(): string {
  const abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 56
  for (;;) {
    const out: string[] = [];
    while (out.length < 12) {
      for (const b of crypto.getRandomValues(new Uint8Array(16))) {
        if (b < 224 && out.length < 12) out.push(abc[b % 56]); // 224 = 4 × 56: no modulo bias
      }
    }
    const p = out.join("");
    if (/[a-z]/.test(p) && /[A-Z]/.test(p) && /[2-9]/.test(p)) return `${p.slice(0, 4)}-${p.slice(4, 8)}-${p.slice(8)}`;
  }
}

/** Auth's messages, in the app's words where they are cryptic. */
function friendly(msg: string): string {
  if (/already been registered|already exists|email_exists/i.test(msg)) return "That email already has a login";
  if (/password/i.test(msg) && /characters|weak|length/i.test(msg)) return "That password is too short or too weak";
  if (/not found|user_not_found/i.test(msg)) return "No such user";
  return msg;
}

function typedPassword(p: unknown): string | null {
  if (typeof p !== "string" || p === "") return null;
  if (p.length < 8) throw new Error("Passwords need at least 8 characters");
  return p;
}

async function create(b: Record<string, unknown>) {
  const email = String(b.email ?? "").trim().toLowerCase();
  const name = String(b.name ?? "").trim();
  const role = b.role === "manager" ? "manager" : "agent";
  if (!EMAIL.test(email)) throw new Error("Enter a valid email address");
  if (!name) throw new Error("Enter their name");
  const typed = typedPassword(b.password);
  const password = typed ?? newPassword();
  const { data, error } = await admin.auth.admin.createUser({
    email, password, email_confirm: true, user_metadata: { name },
  });
  if (error || !data.user) throw new Error(friendly(error?.message ?? "Could not create the login"));
  // the signup trigger made their profile (as an agent); set what the form chose
  const { error: pe } = await admin.from("profiles").update({ name, role }).eq("id", data.user.id);
  if (pe) throw new Error(pe.message);
  return { id: data.user.id, email, password: typed ? null : password };
}

async function resetPassword(id: string, p: unknown) {
  const typed = typedPassword(p);
  const password = typed ?? newPassword();
  const { error } = await admin.auth.admin.updateUserById(id, { password });
  if (error) throw new Error(friendly(error.message));
  return { password: typed ? null : password };
}

async function setEmail(id: string, e: unknown) {
  const email = String(e ?? "").trim().toLowerCase();
  if (!EMAIL.test(email)) throw new Error("Enter a valid email address");
  const { error } = await admin.auth.admin.updateUserById(id, { email, email_confirm: true });
  if (error) throw new Error(friendly(error.message));
  return { email };
}

async function remove(me: string, id: string) {
  if (id === me) throw new Error("You can't remove yourself: ask another manager");
  const { data: hist, error: he } = await admin.rpc("member_history", { p_id: id });
  if (he) throw new Error(he.message);
  const onFile = Object.values((hist ?? {}) as Record<string, number>).some((n) => Number(n) > 0);
  if (!onFile) {
    // nothing references them: clear what a session leaves behind, then delete the login
    await admin.from("lead_state").update({ reserved_by: null, reserved_until: null }).eq("reserved_by", id);
    await admin.from("agent_status").delete().eq("agent_id", id);
    const { error } = await admin.auth.admin.deleteUser(id);
    if (error) throw new Error(friendly(error.message));
    return { deleted: true };
  }
  // calls or records on file: block the login and take them off the floor, keep the history
  const { error } = await admin.auth.admin.updateUserById(id, { ban_duration: BLOCKED });
  if (error) throw new Error(friendly(error.message));
  const { error: pe } = await admin.from("profiles").update({ active: false }).eq("id", id);
  if (pe) throw new Error(pe.message);
  return { removed: true };
}

async function restore(id: string) {
  const { error } = await admin.auth.admin.updateUserById(id, { ban_duration: "none" });
  if (error) throw new Error(friendly(error.message));
  const { error: pe } = await admin.from("profiles").update({ active: true }).eq("id", id);
  if (pe) throw new Error(pe.message);
  return { restored: true };
}

Deno.serve(async (req) => {
  const cors = corsHeaders(req);
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  // who is asking: a signed-in, active manager
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json(401, { error: "Sign in again" });
  const { data: who, error: whoErr } = await admin.auth.getUser(jwt);
  if (whoErr || !who?.user) return json(401, { error: "Sign in again" });
  const me = who.user.id;
  const { data: mine } = await admin.from("profiles").select("role, active").eq("id", me).maybeSingle();
  if (!mine || mine.role !== "manager" || !mine.active) return json(403, { error: "Managers only" });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "Bad request" });
  }
  const id = typeof body.user_id === "string" ? body.user_id : "";
  if (body.action !== "create" && !id) return json(400, { error: "Pick a user" });
  try {
    switch (body.action) {
      case "create": return json(200, await create(body));
      case "reset_password": return json(200, await resetPassword(id, body.password));
      case "set_email": return json(200, await setEmail(id, body.email));
      case "remove": return json(200, await remove(me, id));
      case "restore": return json(200, await restore(id));
      default: return json(400, { error: "Unknown action" });
    }
  } catch (e) {
    return json(400, { error: e instanceof Error ? e.message : String(e) });
  }
});
