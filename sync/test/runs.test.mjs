// The lease on an open hosted run (supabase/functions/sync-console/runs.mjs).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { LEASE_MIN, splitUnfinished } from '../../supabase/functions/sync-console/runs.mjs'

const now = Date.parse('2026-10-13T12:00:00Z')
const lease = LEASE_MIN * 60_000
const at = (secondsAgo) => new Date(now - secondsAgo * 1000).toISOString()

test('a run inside its lease is still running; one past it died', () => {
  const { live, dead } = splitUnfinished([
    { id: 1, started_at: at(30) },
    { id: 2, started_at: at(LEASE_MIN * 60 - 1) },
    { id: 3, started_at: at(LEASE_MIN * 60 + 1) },
    { id: 4, started_at: at(3600) },
  ], now, lease)
  assert.deepEqual(live.map((r) => r.id), [1, 2])
  assert.deepEqual(dead.map((r) => r.id), [3, 4])
})

test('the lease outlives any edge instance', () => {
  assert.ok(LEASE_MIN * 60 > 150, 'an instance is stopped at 150 s, so a run older than the lease cannot still be running')
})

test('a row with no readable start is closed rather than trusted', () => {
  const { live, dead } = splitUnfinished([{ id: 9, started_at: null }, { id: 10 }], now, lease)
  assert.deepEqual(live, [])
  assert.deepEqual(dead.map((r) => r.id), [9, 10])
})

test('nothing open, nothing to do', () => {
  assert.deepEqual(splitUnfinished([], now, lease), { live: [], dead: [] })
  assert.deepEqual(splitUnfinished(null, now, lease), { live: [], dead: [] })
})
