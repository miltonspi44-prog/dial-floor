// Client for the hosted lead console (leads.sedsolutions.online/api.php).
// Session auth with the console password; keeps the PHP session cookie.
//
// The console locks sign-ins after ten failures in fifteen minutes, and that one
// password is also how the owner gets into the console, so a lockout locks them
// out of their own leads. Everything below is built around that: a password the
// console refuses is remembered and never tried again while this process lives,
// and only trouble that is plainly not our fault — a timeout, a dead host — is
// worth another go.
//
// A lockout itself is not the console refusing our password. It counts failures
// per address and answers 429 before it even looks at what we sent, so asking
// again while the lock is on adds nothing to the count — it is usually the owner
// mistyping at the console, and it clears itself a quarter of an hour after the
// last try. So a lockout is something to wait out, not a reason to stop the
// worker; only a plain 401 on the password is that.

const BASE = (process.env.CONSOLE_URL ?? 'https://leads.sedsolutions.online').replace(/\/$/, '')
const PASSWORD = process.env.CONSOLE_PASSWORD ?? ''

// A request that never comes back would otherwise hold the sync open forever and
// block every run behind it. Generous, because a thousand-row page off shared
// hosting is genuinely slow. CONSOLE_TIMEOUT_MS in .env shortens it for a host that
// is known to be quicker than this.
const TIMEOUT_MS = Number(process.env.CONSOLE_TIMEOUT_MS) || 120_000

// api.php caps `limit` at 1000 and quietly gives less if you ask for more.
const PAGE_MAX = 1000

// The furthest we will walk through the console's list in one pass.
const MAX_PAGES = 200

// How long to leave the console alone after it says sign-ins are locked. The lock
// is fifteen minutes from the last try; the extra minute is slack for clocks.
const LOCKOUT_WAIT_MS = 16 * 60_000

let cookie = null
// Set once we know the password is no good, and never cleared: it is both the
// reason to refuse every later login and the message the owner needs to read.
let passwordRefused = null
// When the console's sign-in lock should have expired. Until then there is nothing
// to gain by asking, and the run that wanted a session is simply deferred.
let lockedUntil = 0

/** A console failure with the one thing a caller needs to decide what to do next:
 *  `kind` is 'auth' (it will not let us in — stop), 'rejected' (it understood and
 *  said no — trying again changes nothing) or 'retry' (not our doing: try later).
 *  `reached` is false when the request never got an answer at all, which on its own
 *  says nothing about whether it was the host or the thing we asked for. */
export class ConsoleError extends Error {
  constructor(message, kind, status = null, { reached = true } = {}) {
    super(message)
    this.name = 'ConsoleError'
    this.kind = kind
    this.status = status
    this.reached = reached
  }
}

export const isAuthFailure = (e) => e?.kind === 'auth'
export const isRejected = (e) => e?.kind === 'rejected'
/** The console never answered this request at all. Which tells you nothing about the
 *  next one: shared hosting kills a single request whose body its firewall dislikes,
 *  and a PHP fatal on a long note closes the socket, while every other request to the
 *  same host goes through. Ask consoleAnswers() rather than concluding from this. */
export const isUnreachable = (e) => e?.kind === 'retry' && e?.reached === false
/** True once the console has refused the password, so callers can stop early. */
export const passwordIsRefused = () => passwordRefused != null

function rememberRefusal(status) {
  passwordRefused = 'The lead console would not accept the sync password.'
  // Printed once, here, because this is the only moment we learn it. The owner is
  // the only person who can fix it, and the worst thing we could do is keep trying.
  console.error('')
  console.error(passwordRefused)
  console.error('The sync will not try to sign in again. About ten wrong tries lock the console')
  console.error('for everyone, and that includes you.')
  console.error(`What to do: open ${BASE}, check the password you sign in with, put that same`)
  console.error('password in CONSOLE_PASSWORD in sync/.env, then start the sync again.')
  console.error('')
  return new ConsoleError(passwordRefused, 'auth', status)
}

function rememberLockout(why) {
  lockedUntil = Date.now() + LOCKOUT_WAIT_MS
  // Said out loud because it looks alarming in the log and the owner should know
  // it needs nothing from them. It is not about our password: the console counts
  // tries per address and turns us away before reading the one we sent.
  console.error('')
  console.error('The lead console has locked sign-ins for fifteen minutes: too many wrong passwords.')
  console.error('That count is for everyone on this connection, so it is usually a mistyped')
  console.error('password at the console itself. The lock clears by itself fifteen minutes after')
  console.error('the last try, and asking again while it is on does not extend it.')
  console.error('The sync will leave it alone until then and carry on by itself afterwards.')
  console.error('')
  return new ConsoleError(`console login: ${why}`, 'retry', 429)
}

async function api(action, { method = 'GET', params = {}, body, replayed = false } = {}) {
  const qs = new URLSearchParams({ action, ...params }).toString()
  let res, text
  try {
    res = await fetch(`${BASE}/api.php?${qs}`, {
      method,
      headers: {
        ...(cookie ? { cookie } : {}),
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    })
    const setCookie = res.headers.get('set-cookie')
    if (setCookie) cookie = setCookie.split(';')[0]
    text = await res.text()
  } catch (e) {
    // The host being unreachable, slow or cut off mid-answer says nothing about
    // our password, so this is always worth another try later.
    const why = e?.name === 'TimeoutError' ? `no answer in ${TIMEOUT_MS / 1000}s` : e.message
    throw new ConsoleError(`console ${action}: ${why}`, 'retry', null, { reached: false })
  }

  let json
  try { json = JSON.parse(text) } catch {
    // a PHP fatal comes back as an HTML page: keep its gist so the failure is diagnosable
    const gist = text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 300)
    throw new ConsoleError(
      `console ${action}: non-JSON response (${res.status})${gist ? `: ${gist}` : ', empty body'}`,
      'retry', res.status)
  }
  const why = json?.error ?? res.status

  // Sign-ins are locked for a quarter of an hour. Nothing about our password has
  // been judged, so this is only a wait — never a reason to give up on it.
  if (res.status === 429) {
    if (action === 'login') throw rememberLockout(why)
    throw new ConsoleError(`console ${action}: ${why}`, 'retry', 429)
  }
  if (res.status === 401) {
    if (action === 'login') throw rememberRefusal(res.status)
    // Any other action answering 401 means the PHP session we were given has
    // expired, which happens on its own after about twenty minutes of quiet. That
    // is worth exactly one fresh sign-in and one replay: a correct password makes
    // no failed attempt, and a wrong one is already refused by login() for good.
    if (passwordRefused) throw new ConsoleError(`console ${action}: ${why}`, 'auth', 401)
    if (replayed) {
      // We signed in, the console said ok, and it still does not know us. The
      // password is fine; the session is not sticking — a full or unwritable
      // session directory on the host does exactly this. Stopping the worker over
      // it would be wrong, because nobody can fix it by changing a password, and
      // it usually clears on its own once the host is tidied up.
      throw new ConsoleError(
        `console ${action}: signed in, but the console did not keep the session (${why})`,
        'retry', 401)
    }
    cookie = null
    await login()
    return api(action, { method, params, body, replayed: true })
  }
  if (!res.ok) {
    // The console answering 4xx has read what we sent and turned it down; sending
    // the same thing again tomorrow gets the same answer. A 5xx is its problem.
    throw new ConsoleError(`console ${action}: ${why}`, res.status < 500 ? 'rejected' : 'retry', res.status)
  }
  return json
}

export async function login() {
  if (!BASE || !PASSWORD) throw new ConsoleError('CONSOLE_URL / CONSOLE_PASSWORD missing in .env', 'auth')
  if (passwordRefused) throw new ConsoleError(passwordRefused, 'auth')
  const left = lockedUntil - Date.now()
  if (left > 0) {
    throw new ConsoleError(
      `console login: sign-ins are locked for about ${Math.ceil(left / 60_000)} more minute(s)`,
      'retry', 429)
  }
  await api('login', { method: 'POST', body: { password: PASSWORD } })
  // It let us in, so whatever the lock was about is over.
  lockedUntil = 0
}

/** Is the console there at all? `me` is the cheapest thing it answers and it changes
 *  nothing, so this is how "the host is gone" gets told apart from "the host would not
 *  take that one row" — by asking, rather than by guessing from the shape of a silence.
 *  Any answer at all, happy or not, means it is there. */
export async function consoleAnswers() {
  try {
    await api('me')
    return true
  } catch (e) {
    return !isUnreachable(e)
  }
}

export async function ensureAuth() {
  if (passwordRefused) throw new ConsoleError(passwordRefused, 'auth')
  // `me` answers 200 with authed:false when we are merely not signed in, so an
  // error from it is a real problem — a blip, a sick host — and must never be read
  // as "sign in again". Reading it that way is how one wrong password became a
  // login attempt every minute until the console locked.
  const me = await api('me')
  if (!me?.authed) await login()
}

/** One page of dialable leads: { total, leads }. */
export async function leadsPage(limit, offset) {
  return api('leads', { params: { dialable: 1, limit, offset } })
}

/** One page of leads with no filter: every row the console holds, newest-scored
 *  first. This is the only way to ask about leads we already imported, because
 *  importing marks them contacted and that drops them out of `dialable`. */
export async function allLeadsPage(limit, offset) {
  return api('leads', { params: { limit, offset } })
}

async function* pagesOf(fetchPage, pageSize, status = {}) {
  const size = Math.min(pageSize, PAGE_MAX)
  let offset = 0, pages = 0
  status.truncated = false
  for (;;) {
    const { total, leads } = await fetchPage(size, offset)
    if (!leads?.length) return
    yield leads
    offset += leads.length
    status.rows = offset
    pages++
    if (offset >= Number(total ?? 0)) return
    // The console counts and lists in two queries, so a scrape finishing while we
    // read can keep its total ahead of us and there would be no end to the paging.
    // This is a hard stop on that, and on a console grown too big to walk every
    // quarter of an hour — at which point it needs a way to ask about given ids.
    if (pages >= MAX_PAGES) {
      // The caller has to know it only saw part of the list: concluding anything
      // about the leads it never reached — that they are gone, say — would be
      // wrong, and that conclusion would be about nearly all of them.
      status.truncated = true
      console.error(`  console leads: stopped after ${MAX_PAGES} pages (${offset} rows of ${total}).`)
      return
    }
  }
}

/** Page through dialable leads. Yields arrays of rows. */
export async function* dialableLeads(pageSize = 500) {
  yield* pagesOf(leadsPage, pageSize)
}

/** Page through every lead the console holds. Yields arrays of rows. `status` is
 *  filled in as we go: `rows` is how many we read, and `truncated` says we gave up
 *  before the end of the list. */
export async function* allLeads(pageSize = PAGE_MAX, status = {}) {
  yield* pagesOf(allLeadsPage, pageSize, status)
}

export async function setStatus(id, status, note) {
  const lead = await api('status', { method: 'POST', body: { id, status, note: note ?? undefined } })
  // The console answers with the lead it just changed, and a bare `false` — under
  // a 200, not a 404 — when it has no such lead. Looking at what came back is the
  // only way to notice a lead that was deleted over there.
  if (!lead || typeof lead !== 'object' || lead.id == null) {
    throw new ConsoleError(`console status: it has no lead with id ${id}`, 'rejected', 404)
  }
  return lead
}

export async function markContacted(ids) {
  if (!ids.length) return
  // the console writes a status + log row per id; keep each request small
  for (let i = 0; i < ids.length; i += 50) {
    await api('contacted', { method: 'POST', body: { ids: ids.slice(i, i + 50) } })
  }
}
