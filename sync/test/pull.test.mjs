// pull() end to end against a stand-in console (fetch) and a stand-in dialing DB:
// which console leads come in, which are marked contacted, and which wait (0049).
import { test } from 'node:test'
import assert from 'node:assert/strict'

process.env.CONSOLE_URL = 'https://console.test'
process.env.CONSOLE_PASSWORD = 'not-a-real-password'
const { initSupa } = await import('../lib/supa.mjs')
const { pull } = await import('../pull-leads.mjs')

const DAY = 86_400_000
const stamp = (msAgo) => new Date(Date.now() - msAgo).toISOString().replace('T', ' ').slice(0, 19)
const row = (id, source, daysAgo) => ({
  id, name: `Business ${id}`, phone: `(512) 555-${String(1000 + id)}`, phone_type: 'mobile', addr_state: 'TX',
  website_type: 'none', source, first_seen: stamp(daysAgo * DAY), extras: {},
})

/** The console's api.php, answering from `dialable`; records what was marked contacted. */
function fakeConsole(dialable, marked) {
  return async (url, init = {}) => {
    const u = new URL(url)
    const action = u.searchParams.get('action')
    const json = (o) => new Response(JSON.stringify(o), { status: 200, headers: { 'content-type': 'application/json' } })
    if (action === 'me') return json({ authed: true })
    if (action === 'contacted') {
      const ids = JSON.parse(init.body).ids
      marked.push(...ids)
      for (const id of ids) { const i = dialable.findIndex((r) => r.id === id); if (i >= 0) dialable.splice(i, 1) }
      return json({ ok: true, n: ids.length })
    }
    if (action === 'leads') {
      const limit = Number(u.searchParams.get('limit')), offset = Number(u.searchParams.get('offset'))
      // the refresh pass asks for every lead; the held ones are all a dialable list shows anyway
      return json({ total: dialable.length, leads: dialable.slice(offset, offset + limit) })
    }
    return json({ ok: true })
  }
}

/** Just enough of the dialing DB: leads (by console id), the registry hold setting, nothing suppressed. */
function fakeDb(hold) {
  const leads = new Map()   // source_id -> row
  let nextId = 1
  const builder = (table) => {
    const q = { table, calls: [] }
    const run = () => {
      const has = (m) => q.calls.find(([name]) => name === m)
      if (table === 'app_settings') return { data: hold == null ? null : { value: hold }, error: null }
      if (table !== 'leads') return { data: [], error: null }
      if (has('upsert')) {
        const out = has('upsert')[1][0].map((r) => {
          const prev = leads.get(r.source_id)
          const saved = { ...prev, ...r, id: prev?.id ?? nextId++ }
          leads.set(r.source_id, saved)
          return { id: saved.id, source_id: saved.source_id }
        })
        return { data: out, error: null }
      }
      if (has('update')) {
        const ids = has('in')[1][1]
        for (const id of ids) Object.assign(leads.get(id), has('update')[1][0])
        return { data: null, error: null }
      }
      let rows = [...leads.values()]
      if (has('in')) rows = rows.filter((r) => has('in')[1][1].includes(r.source_id))
      if (has('eq')) rows = rows.filter((r) => r[has('eq')[1][0]] === has('eq')[1][1])
      if (has('gt')) rows = rows.filter((r) => r.source_id > has('gt')[1][1]).sort((a, b) => a.source_id - b.source_id)
      if (has('limit')) rows = rows.slice(0, has('limit')[1][0])
      return { data: rows, error: null }
    }
    const self = new Proxy({}, {
      get(_t, prop) {
        if (prop === 'then') return (res, rej) => Promise.resolve(run()).then(res, rej)
        return (...args) => { q.calls.push([prop, args]); return self }
      },
    })
    return self
  }
  return { leads, client: { from: builder, rpc: () => Promise.resolve({ data: null, error: null }) } }
}

test('0049: registry leads under the hold stay in the console; old ones and every other source come in and are marked', async () => {
  const dialable = [
    row(1, 'registry', 3),     // 3 days scraped: waits
    row(2, 'registry', 13.9),  // nearly there: waits
    row(3, 'registry', 14.1),  // past the hold: comes in
    row(4, 'yelp', 0.01),      // minutes old: comes in, as now
    row(5, 'angi', 1),
    row(6, 'thumbtack', 2),
    row(7, 'gmaps', 0.5),
  ]
  const marked = []
  const db = fakeDb(null)   // nobody has set it: 14 days
  globalThis.fetch = fakeConsole(dialable, marked)
  initSupa(db.client)

  const r = await pull()

  assert.deepEqual([...db.leads.keys()].sort((a, b) => a - b), [3, 4, 5, 6, 7], 'everything but the young registry leads came in')
  assert.deepEqual(marked.sort((a, b) => a - b), [3, 4, 5, 6, 7], 'and only those were marked contacted in the console')
  assert.deepEqual(dialable.map((x) => x.id).sort(), [1, 2], 'the young registry leads are still on offer in the console')
  assert.match(r.detail, /2 registry lead\(s\) wait in the console until the scraper has had them 14 days/)
  assert.equal(r.rows, 5, 'the count is what came in')

  // two weeks on, the next pull takes them like any other lead
  for (const x of dialable) x.first_seen = stamp(15 * DAY)
  const r2 = await pull()
  assert.deepEqual([...db.leads.keys()].sort((a, b) => a - b), [1, 2, 3, 4, 5, 6, 7])
  assert.deepEqual(marked.sort((a, b) => a - b), [1, 2, 3, 4, 5, 6, 7])
  assert.doesNotMatch(r2.detail ?? '', /wait in the console/)
})

test('0049: the hold is the setting; 0 switches it off', async () => {
  for (const [hold, want] of [[0, [1, 2, 3]], [2, [2, 3]], [30, [3]]]) {
    const dialable = [row(1, 'registry', 1), row(2, 'registry', 20), row(3, 'yelp', 0)]
    const marked = []
    const db = fakeDb(hold)
    globalThis.fetch = fakeConsole(dialable, marked)
    initSupa(db.client)
    await pull()
    assert.deepEqual([...db.leads.keys()].sort((a, b) => a - b), want, `a hold of ${hold} days`)
  }
})
