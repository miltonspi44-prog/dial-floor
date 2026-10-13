// What counts as a change, what sets off a refresh, and what is worth writing.
// Run with: npm test (node --test)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mapLead, needsRefresh, sameRow, sameRowExactly } from '../lib/map.mjs'

// a console row as api.php sends it
const row = (over = {}) => ({
  id: 7, name: 'Acme Roofing', phone: '(305) 555-0101', phone_type: 'mobile', addr_state: 'FL',
  website_type: 'none', rating: '4.6', review_count: '31', created_at: '2026-10-01 12:00:00',
  extras: { source: 'card', sponsored: 0, guaranteed: 0, scraped_at: '2026-10-09T23:07:10.681Z' },
  ...over,
})
// the same business as the dialing DB hands it back: numbers as numbers, the
// timestamp in Postgres's shape
const onFile = () => ({ ...mapLead(row()), rating: 4.6, review_count: 31, first_seen: '2026-10-01T12:00:00+00:00' })

test('a re-scrape that changed nothing about the business is not news — but it is still written', () => {
  const next = mapLead(row({ extras: { ...row().extras, scraped_at: '2026-10-12T01:00:00.000Z' } }))
  const prev = onFile()
  assert.equal(sameRow(next, prev), true, 'not counted as a change')
  assert.equal(needsRefresh(next, prev), false, 'no refresh_lead round trip')
  assert.equal(sameRowExactly(next, prev), false, 'the row on file is still brought up to date')
})

test('a row the same to the byte is left alone entirely', () => {
  const next = mapLead(row())
  const prev = onFile()
  assert.equal(sameRowExactly(next, prev), true)
  assert.equal(sameRow(next, prev), true)
  assert.equal(needsRefresh(next, prev), false)
})

test('a real change counts; only a refresh input sets off a refresh', () => {
  const prev = onFile()
  const renamed = mapLead(row({ name: 'Acme Roofing LLC' }))
  assert.equal(sameRow(renamed, prev), false, 'a new name is news')
  assert.equal(needsRefresh(renamed, prev), false, 'but nothing refresh_lead reads moved')
  assert.equal(needsRefresh(mapLead(row({ phone_type: 'landline' })), prev), true, 'the phone type is read for owner_mobile')
  assert.equal(needsRefresh(mapLead(row({ addr_state: 'GA' })), prev), true, 'the state is read for the timezone')
})

test('of extras, only the two flags refresh_lead reads matter to it', () => {
  const prev = onFile()
  assert.equal(needsRefresh(mapLead(row({ sponsored: '1' })), prev), true, 'sponsored lands in extras and is read for ad_spend')
  assert.equal(needsRefresh(mapLead(row({ yelp_guaranteed: '1' })), prev), true, 'guaranteed, for badge_holder')
  const bio = mapLead(row({ extras: { ...row().extras, fb_bio: 'Family owned since 1998' } }))
  assert.equal(needsRefresh(bio, prev), false, 'a new bio is not')
  assert.equal(sameRow(bio, prev), false, 'though it is a change worth counting')
})

test('numbers as strings and timestamps in another shape are the same value', () => {
  const next = mapLead(row({ rating: '4.60', review_count: '31', created_at: '2026-10-01T12:00:00Z' }))
  assert.equal(sameRowExactly(next, onFile()), true)
})
