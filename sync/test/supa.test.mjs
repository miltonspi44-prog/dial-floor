// upsertLeads against a stand-in for the Supabase client: which rows get
// written, which get counted, and which get a refresh_lead round trip.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { initSupa, upsertLeads } from '../lib/supa.mjs'
import { mapLead } from '../lib/map.mjs'

/** A client whose query builders record what was asked and answer from `answer`.
 *  supabase-js builders are thenables, so awaiting one here resolves the same way. */
function fakeClient(answer, log) {
  const builder = (table) => {
    const q = { table, op: null, args: {}, calls: [] }
    const self = new Proxy({}, {
      get(_t, prop) {
        if (prop === 'then') return (res, rej) => Promise.resolve(answer(q)).then(res, rej)
        return (...args) => {
          q.calls.push([prop, args])
          if (['select', 'upsert', 'insert', 'update'].includes(prop) && (q.op == null || q.op === 'select')) q.op = prop
          if (prop === 'in') q.args.in = args
          return self
        }
      },
    })
    return self
  }
  return {
    from: (t) => builder(t),
    rpc: (fn, args) => { log.rpcs.push([fn, args]); return Promise.resolve({ data: null, error: null }) },
  }
}

const consoleRow = (id, over = {}) => ({
  id, name: `Business ${id}`, phone: `(305) 555-01${String(id).padStart(2, '0')}`, phone_type: 'mobile',
  addr_state: 'FL', website_type: 'none', rating: '4.5', review_count: '12', created_at: '2026-10-01 12:00:00',
  extras: { source: 'card', sponsored: 0, guaranteed: 0, scraped_at: '2026-10-09T23:07:10.681Z' },
  ...over,
})
// the row as the dialing DB holds it, with the shape it hands back
const held = (id, over = {}) => ({
  id: 100 + id, console_mark_pending: false,
  ...mapLead(consoleRow(id)), rating: 4.5, review_count: 12, first_seen: '2026-10-01T12:00:00+00:00', ...over,
})

test('only rows with something different on them are written; only news is counted; only refresh inputs refresh', async () => {
  const log = { rpcs: [], written: [] }
  const onFile = [
    held(1),                                                                         // identical
    held(2, { extras: { ...held(2).extras, scraped_at: '2026-10-01T00:00:00.000Z' } }), // re-scraped, nothing else
    held(3, { name: 'Old Name' }),                                                   // renamed in the console
  ]
  initSupa(fakeClient((q) => {
    if (q.table === 'leads' && q.op === 'select') {
      const ids = q.args.in?.[1] ?? []
      return { data: onFile.filter((r) => ids.includes(r.source_id)), error: null }
    }
    if (q.table === 'leads' && q.op === 'upsert') {
      const payload = q.calls.find(([m]) => m === 'upsert')[1][0]
      log.written.push(...payload.map((r) => r.source_id))
      return { data: payload.map((r) => ({ id: 100 + r.source_id, source_id: r.source_id })), error: null }
    }
    return { data: [], error: null } // suppression, lead_state: nothing on the list
  }, log))

  const r = await upsertLeads([consoleRow(1), consoleRow(2), consoleRow(3), consoleRow(4)])

  assert.deepEqual(log.written.sort(), [2, 3, 4], 'the identical row is left alone; the re-scraped one is brought up to date')
  assert.equal(r.looked, 4)
  assert.equal(r.upserted, 3, 'written')
  assert.equal(r.changed, 2, 'the rename and the new lead are news; the re-scrape is not')
  assert.deepEqual(r.imported, [4])
  assert.deepEqual(log.rpcs, [['refresh_lead', { p_lead_id: 104 }]], 'only the new lead needs refresh_lead()')
  assert.equal(r.refreshed, 1)
  assert.deepEqual([...r.ids.entries()].sort((a, b) => a[0] - b[0]), [[1, 101], [2, 102], [3, 103], [4, 104]],
    'every id in the batch is known, written or not')
})

test('a quiet quarter hour writes nothing at all', async () => {
  const log = { rpcs: [], written: [] }
  const onFile = [held(1), held(2)]
  initSupa(fakeClient((q) => {
    if (q.table === 'leads' && q.op === 'select') return { data: onFile, error: null }
    if (q.table === 'leads' && q.op === 'upsert') { log.written.push('called'); return { data: [], error: null } }
    return { data: [], error: null }
  }, log))
  const r = await upsertLeads([consoleRow(1), consoleRow(2)])
  assert.deepEqual(log.written, [], 'no upsert was sent')
  assert.equal(r.upserted, 0)
  assert.equal(r.changed, 0)
  assert.deepEqual(log.rpcs, [])
})
