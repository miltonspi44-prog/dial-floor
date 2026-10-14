// admin-users: managers add, remove and manage logins from the app's Users tab.
//
// Creating, deleting and resetting logins needs Supabase's service key (the Auth
// admin API), so it happens here and never in the browser. Every call must carry
// the session of a signed-in, active manager.
//
//   create          {email, name, role, password?}  → {id, email, password?}
//   reset_password  {user_id, password?}            → {password?}
//   set_email       {user_id, email}                → {email}
//   remove          {user_id, keep_history?}        → {deleted} | {removed}
//   restore         {user_id}                       → {restored}
//
// A password left blank is generated and returned once, for the manager to hand
// over; it is never logged. Names, roles and on/off-the-floor go through the
// set_member RPC.
//
// "remove" blocks the login and takes the person off the floor, leaving every
// report's history alone, and that is what it does unless the caller asks for the
// login itself to be deleted. keep_history is how the caller says what the manager
// was told before they pressed the button:
//
//   false   they were told nothing is on file, so the login may be deleted
//   true    they were promised a restore, so the login is only ever blocked
//   missing, or anything else: treated as true, and the login is only blocked
//
// Deleting a login is the one thing here that cannot be undone, so it takes two
// yeses: the caller's and the counts'. Neither is enough alone. The counts are not,
// because handing someone's lists back to the team empties them seconds before we
// read them — the tab decides what to promise, and then changes what we would see.
// The caller is not, because a count can appear between the promise and the click.
// A caller that says nothing is an older tab or one we don't understand, and that
// is not a caller to delete someone's login on.
//
// Someone a manager adds here is on the floor the moment they are created, while
// someone who signs themselves up on the public site stays off it until a manager
// switches them on with "bring back" on the Users tab (the set_member RPC). Nobody
// can switch themselves on: the only thing a signed-in user may update on their own
// profile row is their name.

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
  // The signup trigger made their profile, switched off, because sign-ups are open on
  // this project and a stranger who signs up must wait for a manager. A manager adding
  // someone here has already made that decision, so this is where active is turned on,
  // next to the name and role the form chose.
  const { data: updated, error: pe } = await admin.from("profiles")
    .update({ name, role, active: true }).eq("id", data.user.id).select("id");
  // An update answers with the rows it changed, so an empty answer is how we learn there
  // was no profile to set up — it comes back as no rows rather than as an error.
  const touched = Array.isArray(updated) ? updated.length > 0 : !!updated;
  // If that did not take, the login exists with a password nobody has seen and a profile
  // nobody set, and it would answer the manager's next attempt with "that email already
  // has a login" and no way forward. So undo it: then retrying is all they have to do.
  if (pe || !touched) {
    const why = pe?.message ?? "their profile was not there to set up";
    const { error: de } = await admin.auth.admin.deleteUser(data.user.id);
    if (de) {
      // Nothing else records that this login exists, so the message has to carry the id
      // as well as the email: that is what gets pasted into Supabase to clear it away.
      throw new Error(`The login for ${email} could not be finished (${why}), and clearing it ` +
        `away again failed too (${de.message}). It still exists: delete user ${data.user.id} in ` +
        `Supabase before this email can be used again.`);
    }
    throw new Error(`Could not finish the login for ${email}, so nothing was created: ${why}. Try again.`);
  }
  return { id: data.user.id, email, password: typed ? null : password };
}

/** Item 52: a manager's login is their own. One manager could quietly take over
 *  another's account by resetting its password (or re-pointing its email), and
 *  nothing in the ledger would say who did it. Your own login, and any agent's,
 *  stay fair game — that is what the button is for. */
async function guardPeer(me: string, id: string, what: string) {
  if (id === me) return;
  const { data } = await admin.from("profiles").select("role").eq("id", id).maybeSingle();
  if (data?.role === "manager") {
    throw new Error(`Another manager's login is theirs alone — they ${what} themselves.`);
  }
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

/** The counts member_history answers with (supabase/migrations/0014_users.sql). All nine
 *  have to be in the answer: one of them missing means we are not looking at the answer
 *  this was written against, and that is not an answer to delete anyone on. */
const HISTORY_KEYS = ["attempts", "callbacks", "lists", "handoffs", "emails", "taps",
  "radar", "library", "leads"];

/** Does member_history's answer mean this person has something on file? Everything does,
 *  except an answer we can read right through and find nothing but zeros in: all nine
 *  counts there, and every value in it — including any count added to that function after
 *  this was written — reading as the number zero. Anything else means something on file:
 *  a count we have never heard of, a value we cannot read, a number that is not zero.
 *  The two mistakes are not the same size. A wrong "nothing on file" deletes someone's
 *  records for good; a wrong "something on file" only leaves a blocked login that a
 *  manager can clear away later. So the unfamiliar answer is always the one we keep on. */
function anythingOnFile(hist: unknown): boolean {
  if (typeof hist !== "object" || hist === null || Array.isArray(hist)) return true;
  const row = hist as Record<string, unknown>;
  for (const key of HISTORY_KEYS) if (!(key in row)) return true;
  for (const v of Object.values(row)) {
    // The counts arrive as numbers. A count written as digits is still a count, so one
    // handed over as text somewhere along the way is read the same way.
    const n = typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : NaN;
    if (n !== 0) return true;
  }
  return false;
}

async function remove(me: string, id: string, mayDelete: boolean) {
  if (id === me) throw new Error("You can't remove yourself: ask another manager");
  // Blocking a login can be undone from the Removed list; deleting one cannot. So deleting
  // happens only when the caller has said the manager was told nothing is on file, and the
  // counts agree. The counts are not asked for otherwise: their answer would change nothing,
  // and a timeout on the way to them would only block a removal that is safe to finish.
  if (mayDelete) {
    const { data: hist, error: he } = await admin.rpc("member_history", { p_id: id });
    // Without the counts we would be guessing at whether there is anything to lose.
    if (he) throw new Error(he.message);
    if (!anythingOnFile(hist)) {
      // Nothing references them. The lead they had open and their spot on the floor board are
      // all a session leaves behind. The lead has to be let go by hand — nothing cascades it,
      // so leaving it would get the delete refused with a foreign key error no manager could
      // read — and that is why this one is checked while the floor board row, which goes with
      // the profile anyway, is not.
      const { error: le } = await admin.from("lead_state")
        .update({ reserved_by: null, reserved_until: null }).eq("reserved_by", id);
      // They may well have had no lead open: this says what failed, not what they were holding.
      if (le) throw new Error(`Could not let go of any lead they had open (${le.message}), so nothing was removed. Try again.`);
      await admin.from("agent_status").delete().eq("agent_id", id);
      const { error } = await admin.auth.admin.deleteUser(id);
      if (error) throw new Error(friendly(error.message));
      return { deleted: true };
    }
  }
  // Keep everything: take them off the floor, block the login, leave every report alone.
  // Off the floor first, because if the block then fails the manager is looking at someone
  // who is off the floor — a state the app already has a word for and a button to undo —
  // rather than at someone who is locked out but still counted as on the floor everywhere.
  const { error: pe } = await admin.from("profiles").update({ active: false }).eq("id", id);
  if (pe) throw new Error(`Could not take them off the floor (${pe.message}), so nothing was removed. Try again.`);
  const { error } = await admin.auth.admin.updateUserById(id, { ban_duration: BLOCKED });
  // Half done, and the half that is done is the half the manager can see and undo. Say so
  // rather than leaving the bare Auth message, which reads as if nothing had happened.
  if (error) {
    throw new Error(`They are off the floor now, but blocking their login failed ` +
      `(${friendly(error.message)}), so they can still sign in. Remove them again to finish it.`);
  }
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
  const { data: mine, error: mineErr } = await admin.from("profiles")
    .select("role, active").eq("id", me).maybeSingle();
  // Not being able to look someone up is not the same as them not being a manager. Saying
  // "managers only" to a manager sends them hunting for a permission problem that isn't there.
  if (mineErr) return json(503, { error: "Could not check who you are just now. Try again." });
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
      case "reset_password":
        await guardPeer(me, id, "reset their password");
        return json(200, await resetPassword(id, body.password));
      case "set_email":
        await guardPeer(me, id, "change their email");
        return json(200, await setEmail(id, body.email));
      // The login may be deleted only when keep_history is exactly false. Missing, or holding
      // anything else, means the login is blocked and kept, which is the answer that can be
      // undone — and the answer every caller gets until it says otherwise in those words.
      case "remove": return json(200, await remove(me, id, body.keep_history === false));
      case "restore": return json(200, await restore(id));
      default: return json(400, { error: "Unknown action" });
    }
  } catch (e) {
    return json(400, { error: e instanceof Error ? e.message : String(e) });
  }
});
