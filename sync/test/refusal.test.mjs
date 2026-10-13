// A refused console password is remembered across edge instances
// (supabase/functions/sync-console/refusal.mjs).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fingerprint, markRefusal, refusalMark, refusedAt } from '../../supabase/functions/sync-console/refusal.mjs'
import { ConsoleError } from '../lib/console.mjs'

test('fingerprint: stable, 16 hex, keyed', async () => {
  const a = await fingerprint('pw-one', 'key-1')
  assert.match(a, /^[0-9a-f]{16}$/)
  assert.equal(a, await fingerprint('pw-one', 'key-1'))
  assert.notEqual(a, await fingerprint('pw-two', 'key-1'))
  assert.notEqual(a, await fingerprint('pw-one', 'key-2'))
})

test('a refusal carries the mark into the run detail logRun writes', async () => {
  const fp = await fingerprint('wrong', 'k')
  const e = new ConsoleError('The lead console would not accept the sync password.', 'auth', 401)
  const detail = String(markRefusal(e, fp))
  assert.ok(detail.startsWith('ConsoleError: The lead console would not accept'))
  assert.ok(detail.includes(refusalMark(fp)))
  markRefusal(e, fp)
  assert.equal(String(e).split(refusalMark(fp)).length, 2, 'marked once, not twice')
  assert.equal(refusedAt([{ started_at: 't1', detail: 'Error: other' }, { started_at: 't0', detail }], fp), 't0')
})

test('only a password refusal is marked', async () => {
  const fp = await fingerprint('x', 'k')
  const retry = new ConsoleError('console login: locked', 'retry', 429)
  assert.equal(String(markRefusal(retry, fp)), 'ConsoleError: console login: locked')
  const plain = new Error('boom')
  assert.equal(String(markRefusal(plain, fp)), 'Error: boom')
  assert.equal(markRefusal('text', fp), 'text')
})

test('refusedAt: a different password, an empty log, null details', async () => {
  const old = await fingerprint('old', 'k'), now = await fingerprint('new', 'k')
  const runs = [{ started_at: 't', detail: `x ${refusalMark(old)}` }, { started_at: 'u', detail: null }]
  assert.equal(refusedAt(runs, old), 't')
  assert.equal(refusedAt(runs, now), null)
  assert.equal(refusedAt([], now), null)
  assert.equal(refusedAt(null, now), null)
})
