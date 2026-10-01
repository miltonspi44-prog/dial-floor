// Client for the hosted lead console (leads.sedsolutions.online/api.php).
// Session auth with the console password; keeps the PHP session cookie.
//
// The console locks sign-ins after ten failures in fifteen minutes, and that one
// password is also how the owner gets into the console, so a lockout locks them
// out of their own leads. Everything below is built around that: a password the
// console refuses is remembered and never tried again while this process lives,
// and only trouble that is plainly not our fault — a timeout, a dead host — is
// worth another go.

const BASE = (process.env.CONSOLE_URL ?? 'https://leads.sedsolutions.online').replace(/\/$/, '')
const PASSWORD = process.env.CONSOLE_PASSWORD ?? ''

// A request that never comes back would otherwise hold the sync open forever and
// block every run behind it. Generous, because a thousand-row page off shared
// hosting is genuinely slow.
const TIMEOUT_MS = 120_000

// api.php caps `limit` at 1000 and quietly gives less if you ask for more.
const PAGE_MAX = 1000

// The furthest we will walk through the console's list in one pass.
const MAX_PAGES = 200

let cookie = null
// Set once we know the password is no good, and never cleared: it is both the
// reason to refuse every later login and the message the owner needs to read.
let passwordRefused = null

/** A console failure with the one thing a caller needs to decide what to do next:
 *  `kind` is 'auth' (it will not let us in — stop), 'rejected' (it understood and
 *  said no — trying again changes nothing) or 'retry' (not our doing: try later). */
export class ConsoleError extends Error {
  constructor(message, kind, status = null) {
    super(message)
    this.name = 'ConsoleError'
    this.kind = kind
    this.status = status
  }
}

export const isAuthFailure = (e) => e?.kind === 'auth'
export const isRejected = (e) => e?.kind === 'rejected'
/** True once the console has refused the password, so callers can stop early. */
export const passwordIsRefused = () => passwordRefused != null

function rememberRefusal(status) {
  passwordRefused = status === 429
    ? 'The lead console has locked sign-ins for fifteen minutes: too many wrong passwords.'
    : 'The lead console would not accept the sync password.'
  // Printed once, here, because this is the only moment we learn it. The owner is
  // the only person who can fix it, and the worst thing we could do is keep trying.
  console.error('')
  console.error(passwordRefused)
  console.error('The sync will not try to sign in again. About ten wrong tries lock the console')
  console.error('for everyone, and that includes you.')
  console.error(`What to do: open ${BASE}, check the password you sign in with, put that same`)
  console.error('password in CONSOLE_PASSWORD in sync/.env, then start the sync again.')
  if (status === 429) console.error('The lock clears by itself fifteen minutes after the last try.')
  console.error('')
  return new ConsoleError(passwordRefused, 'auth', status)
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
    throw new ConsoleError(`console ${action}: ${why}`, 'retry')
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

  if (res.status === 429 && action !== 'login') {
    throw new ConsoleError(`console ${action}: ${why}`, 'retry', 429)
  }
  if (res.status === 401 || res.status === 429) {
    if (action === 'login') throw rememberRefusal(res.status)
    // Any other action answering 401 means the PHP session we were given has
    // expired, which happens on its own after about twenty minutes of quiet. That
    // is worth exactly one fresh sign-in and one replay: a correct password makes
    // no failed attempt, and a wrong one is already refused by login() for good.
    if (replayed || passwordRefused) throw new ConsoleError(`console ${action}: ${why}`, 'auth', 401)
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
  await api('login', { method: 'POST', body: { password: PASSWORD } })
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

async function* pagesOf(fetchPage, pageSize) {
  const size = Math.min(pageSize, PAGE_MAX)
  let offset = 0, pages = 0
  for (;;) {
    const { total, leads } = await fetchPage(size, offset)
    if (!leads?.length) return
    yield leads
    offset += leads.length
    pages++
    if (offset >= Number(total ?? 0)) return
    // The console counts and lists in two queries, so a scrape finishing while we
    // read can keep its total ahead of us and there would be no end to the paging.
    // This is a hard stop on that, and on a console grown too big to walk every
    // quarter of an hour — at which point it needs a way to ask about given ids.
    if (pages >= MAX_PAGES) {
      console.error(`  console leads: stopped after ${MAX_PAGES} pages (${offset} rows of ${total}).`)
      return
    }
  }
}

/** Page through dialable leads. Yields arrays of rows. */
export async function* dialableLeads(pageSize = 500) {
  yield* pagesOf(leadsPage, pageSize)
}

/** Page through every lead the console holds. Yields arrays of rows. */
export async function* allLeads(pageSize = PAGE_MAX) {
  yield* pagesOf(allLeadsPage, pageSize)
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
