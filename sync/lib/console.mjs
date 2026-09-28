// Client for the hosted lead console (leads.sedsolutions.online/api.php).
// Session auth with the console password; keeps the PHP session cookie.
// Respects the console's login lockout (10 fails / 15 min) — one attempt, no retry loops.

const BASE = (process.env.CONSOLE_URL ?? 'https://leads.sedsolutions.online').replace(/\/$/, '')
const PASSWORD = process.env.CONSOLE_PASSWORD ?? ''

let cookie = null

async function api(action, { method = 'GET', params = {}, body } = {}) {
  const qs = new URLSearchParams({ action, ...params }).toString()
  const res = await fetch(`${BASE}/api.php?${qs}`, {
    method,
    headers: {
      ...(cookie ? { cookie } : {}),
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  })
  const setCookie = res.headers.get('set-cookie')
  if (setCookie) cookie = setCookie.split(';')[0]
  const text = await res.text()
  let json
  try { json = JSON.parse(text) } catch { throw new Error(`console ${action}: non-JSON response (${res.status})`) }
  if (!res.ok) throw new Error(`console ${action}: ${json.error ?? res.status}`)
  return json
}

export async function login() {
  if (!BASE || !PASSWORD) throw new Error('CONSOLE_URL / CONSOLE_PASSWORD missing in .env')
  await api('login', { method: 'POST', body: { password: PASSWORD } })
}

export async function ensureAuth() {
  const me = await api('me').catch(() => ({ authed: false }))
  if (!me.authed) await login()
}

/** One page of dialable leads: { total, leads }. */
export async function leadsPage(limit, offset) {
  return api('leads', { params: { dialable: 1, limit, offset } })
}

/** Page through dialable leads. Yields arrays of rows. */
export async function* dialableLeads(pageSize = 500) {
  let offset = 0
  for (;;) {
    const { total, leads } = await leadsPage(pageSize, offset)
    if (!leads?.length) return
    yield leads
    offset += leads.length
    if (offset >= total) return
  }
}

export async function setStatus(id, status, note) {
  await api('status', { method: 'POST', body: { id, status, note: note ?? undefined } })
}

export async function markContacted(ids) {
  if (!ids.length) return
  for (let i = 0; i < ids.length; i += 200) {
    await api('contacted', { method: 'POST', body: { ids: ids.slice(i, i + 200) } })
  }
}
