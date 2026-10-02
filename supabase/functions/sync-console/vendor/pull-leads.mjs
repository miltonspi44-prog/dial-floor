// Pull dialable leads from the hosted console into the dialing DB.
// Every NEWLY imported lead is marked `contacted` in the console, so the
// scraper's permanent suppression stops it from ever re-exporting elsewhere.
import { ensureAuth, dialableLeads, allLeads, markContacted } from './console.mjs'
import {
  supa, upsertLeads, heldSourceIds, statesOf, suppressLead, leadIdsBySourceId, logRun,
} from './supa.mjs'

// How many console rows go into one upsert. Small enough that the "which of these
// do we already have" lookup stays a short URL, big enough to not be chatty.
const WRITE_BATCH = 200

// A console contact_status that means this number must not be dialed here either,
// and what to call it on the suppression list. The console is the only place some
// of these are ever recorded — the owner marks a wrong number while looking at the
// lead over there — so honouring them is the whole point of the refresh pass.
const SUPPRESS_FOR = { do_not_call: 'dnc', wrong_number: 'wrong_number' }

// A mark the console takes but that never clears on our side would spin the flush
// loop below for ever, and it holds the one-sync-at-a-time flag while it spins, so
// every status write-back behind it would starve. Fifty ids a pass: this is a far
// bigger backlog than any real one, and past it something is wrong.
const MARK_PASSES_MAX = 200

export async function pull() {
  await ensureAuth()
  let news = 0
  const pulled = new Set()
  const unusable = []
  for await (const page of dialableLeads()) {
    const r = await upsertLeads(page, { markPending: true })
    news += r.changed
    unusable.push(...r.unusable)
    for (const id of r.ids.keys()) pulled.add(id)
    console.log(`  looked at ${r.upserted} (new: ${r.imported.length}, changed: ${r.changed})`)
  }
  // Before looking at what the console says about older leads, finish telling it
  // about these ones: that mark is what stops the scraper exporting them again.
  const { marked, note: markNote } = await flushContacted()
  if (marked) console.log(`  marked ${marked} as contacted in the console`)

  const back = await refreshImported(pulled)
  const notes = []
  if (unusable.length) notes.push(unusableNote(unusable, 'offered'))
  if (markNote) notes.push(markNote)
  if (back.detail) notes.push(back.detail)
  // The count is what came in, not what was written: the refresh pass below writes
  // every lead it recognises, and an owner watching this number needs to be able to
  // read 0 as "nothing came in".
  return { rows: news + back.written, detail: notes.join(' ') || null }
}

/** Tell the console about every lead still waiting to be marked contacted,
 *  including any that a failed earlier run left behind.
 *  Returns { marked, note } — the note is for the owner when it gave up. */
export async function flushContacted() {
  let n = 0
  for (let pass = 0; ; pass++) {
    if (pass >= MARK_PASSES_MAX) {
      const note = `Stopped marking leads contacted in the console after ${n}:`
        + ' they are not clearing on this side, so the rest waits for the next run.'
        + ' If this keeps happening, something is wrong with the console_mark_pending flag.'
      console.error(`  ${note}`)
      return { marked: n, note }
    }
    // one console request's worth at a time: a failure never leaves already-marked ids flagged
    const { data, error } = await supa.from('leads').select('source_id')
      .eq('console_mark_pending', true).not('source_id', 'is', null).limit(50)
    if (error) throw error
    if (!data?.length) return { marked: n, note: null }
    const ids = data.map((r) => r.source_id)
    await markContacted(ids)
    const { error: upErr } = await supa.from('leads').update({ console_mark_pending: false }).in('source_id', ids)
    if (upErr) throw upErr
    n += ids.length
  }
}

/** The console rows nobody could dial, named so the owner can go and fix them.
 *  Silence here is what let a do-not-call disappear: the row is skipped, and the
 *  number on it keeps being offered to agents. */
function unusableNote(rows, verb) {
  const named = rows.filter((r) => r.id != null).slice(0, 20).map((r) => r.id).join(', ')
  const which = named ? ` (console lead ${named}${rows.length > 20 ? ', and more' : ''})` : ''
  return `The console ${verb} ${rows.length} row(s) with no phone number anyone could dial${which},`
    + ' so nothing here was changed from them.'
    + ' Fix the number in the console and the lead comes in on the next sync.'
}

/** Second pass: what the console changed about leads we already hold.
 *
 *  The pull above cannot see any of it. It asks for dialable leads, the console
 *  counts a lead contacted as not dialable, and importing a lead is exactly what
 *  marks it contacted — so a phone number corrected over there, a lead told never
 *  to call again, or a lead deleted never reaches the floor, and this dialer goes
 *  on calling the old number. The console has no way to ask for a given set of
 *  ids, so the cheapest honest question is its whole list, a thousand rows at a
 *  time, keeping the rows whose id we hold.
 *
 *  This runs unattended every fifteen minutes, so it leans towards doing nothing.
 *  It refreshes every lead it recognises, but only counts and recomputes the ones
 *  the console has something different to say about, and a lead that has gone
 *  missing is reported rather than deleted. */
export async function refreshImported(skipIds = new Set()) {
  const held = await heldSourceIds()
  if (!held.size) return { written: 0, detail: null }

  const census = {}
  const seen = new Set()
  let looked = 0, written = 0, refreshed = 0
  const unusable = []
  const excluded = []
  for await (const page of allLeads(undefined, census)) {
    const ours = []
    const told = []
    for (const row of page) {
      const id = Number(row.id)
      if (!held.has(id)) continue
      seen.add(id)
      // A lead the console marks do-not-call (or wrong number) must not merely be
      // updated here: the number goes on the suppression list, which is what keeps
      // every lead we hold on that number out of every queue. This is read off the
      // console's own row and acted on through a lookup by console id, because the
      // row may be one we cannot otherwise use at all — a lead with no dialable
      // number in the console still has a number here, and agents are still being
      // handed it. Dropping it is how a do-not-call went missing.
      const reason = SUPPRESS_FOR[String(row.contact_status ?? '')]
      if (reason) told.push({ id, reason })
      // The ones the dialable pull just wrote are already current.
      if (!skipIds.has(id)) ours.push(row)
    }
    for (let i = 0; i < ours.length; i += WRITE_BATCH) {
      const slice = ours.slice(i, i + WRITE_BATCH)
      const r = await upsertLeads(slice, { markPending: false })
      looked += r.upserted
      written += r.changed
      refreshed += r.refreshed
      unusable.push(...r.unusable)
    }
    if (told.length) excluded.push(...await suppressTold(told))
  }

  // A lead the dialable pull just read off the console is plainly still there,
  // whatever the census managed to show us.
  const missing = [...held].filter((id) => !seen.has(id) && !skipIds.has(id))
  const notes = []
  if (excluded.length) {
    const byReason = new Map()
    for (const e of excluded) byReason.set(e.reason, (byReason.get(e.reason) ?? 0) + 1)
    const how = [...byReason].map(([reason, n]) => `${n} as ${WORDS_FOR[reason] ?? reason}`).join(', ')
    notes.push(`${excluded.length} lead(s) the console has excluded were suppressed here (${how}).`)
  }
  if (unusable.length) notes.push(unusableNote(unusable, 'lists'))
  if (census.truncated) {
    // We did not get to the end of the console's list, so most of what is "missing"
    // is only unread. Saying they may be gone would be alarming and wrong.
    notes.push(`The console's list was too long to walk in one pass (${census.rows} rows read),`
      + ' so this only covers the leads in that part of it.')
  } else if (missing.length) {
    // Deleting leads on the strength of a list we paged through would be a bad
    // trade: the console counts and lists in two queries and orders by a score the
    // scraper keeps changing, so a row can slip between pages. Say what we saw.
    const shown = missing.slice(0, 20).join(', ')
    notes.push(`${missing.length} lead(s) we hold were not in the console's list this time`
      + ` (${shown}${missing.length > 20 ? ', and more' : ''}).`
      + ' Nothing was changed here — they may have been deleted in the console, or the'
      + ' list may have moved under us while we read it.')
  }
  console.log(`  looked at ${looked} of ${seen.size} already-imported leads the console still lists:`
    + ` ${written} changed, ${refreshed} requeued`)
  for (const note of notes) console.log(`  ${note}`)
  return { written, detail: notes.join(' ') || null }
}

// How to say each suppression reason to someone reading a run's detail later.
const WORDS_FOR = { dnc: 'do-not-call', wrong_number: 'a wrong number' }

/** Suppress the leads the console says are excluded, skipping the ones already dealt
 *  with. The console ids are resolved to our own here, so this works for a console
 *  row we could make no other use of. Returns what it actually suppressed. */
async function suppressTold(told) {
  const ids = await leadIdsBySourceId(told.map((t) => t.id))
  const work = []
  for (const t of told) {
    const leadId = ids.get(t.id)
    if (leadId == null) {
      // We hold this console id, so not finding it means it went away between the
      // two questions. Next pass will see it.
      console.error(`  console lead ${t.id} is marked ${t.reason} but we no longer hold it.`)
      continue
    }
    work.push({ ...t, leadId })
  }
  if (!work.length) return []

  const states = await statesOf(work.map((w) => w.leadId))
  const done = []
  for (const w of work) {
    // Already dealt with: redoing it every quarter of an hour changes nothing.
    if (['suppressed', 'handoff'].includes(states.get(w.leadId))) continue
    await suppressLead(w.leadId, w.reason)
    console.log(`  console lead ${w.id} is marked ${w.reason}: its number is now suppressed here.`)
    done.push(w)
  }
  return done
}

// --marks-only: just retry the console `contacted` marks a failed run left pending
async function marksOnly() {
  await ensureAuth()
  const { marked, note } = await flushContacted()
  return { rows: marked, detail: note }
}

// Run directly under Node (`npm run pull` / `npm run push`); under Deno this
// file is a library and globalThis.process is nobody, so the guard stays false.
const argv1 = globalThis.process?.argv?.[1]
if (argv1 && import.meta.url === `file://${argv1.replace(/\\/g, '/')}`) {
  logRun('pull_leads', process.argv[2] === '--marks-only' ? marksOnly : pull)
    .then((n) => { console.log(`pull done: ${n} leads`); process.exit(0) })
    .catch((e) => { console.error(e); process.exit(1) })
}
