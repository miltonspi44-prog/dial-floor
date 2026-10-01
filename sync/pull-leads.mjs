// Pull dialable leads from the hosted console into the dialing DB.
// Every NEWLY imported lead is marked `contacted` in the console, so the
// scraper's permanent suppression stops it from ever re-exporting elsewhere.
import { ensureAuth, dialableLeads, allLeads, markContacted } from './lib/console.mjs'
import { supa, upsertLeads, heldSourceIds, statesOf, suppressLead, logRun } from './lib/supa.mjs'

// How many console rows go into one upsert. Small enough that the "which of these
// do we already have" lookup stays a short URL, big enough to not be chatty.
const WRITE_BATCH = 200

export async function pull() {
  await ensureAuth()
  let total = 0
  const pulled = new Set()
  for await (const page of dialableLeads()) {
    const { imported, upserted, ids } = await upsertLeads(page, { markPending: true })
    total += upserted
    for (const id of ids.keys()) pulled.add(id)
    console.log(`  upserted ${upserted} (new: ${imported.length})`)
  }
  // Before looking at what the console says about older leads, finish telling it
  // about these ones: that mark is what stops the scraper exporting them again.
  const marked = await flushContacted()
  if (marked) console.log(`  marked ${marked} as contacted in the console`)

  const back = await refreshImported(pulled)
  return { rows: total + back.written, detail: back.detail }
}

/** Tell the console about every lead still waiting to be marked contacted,
 *  including any that a failed earlier run left behind. */
export async function flushContacted() {
  let n = 0
  for (;;) {
    // one console request's worth at a time: a failure never leaves already-marked ids flagged
    const { data, error } = await supa.from('leads').select('source_id')
      .eq('console_mark_pending', true).not('source_id', 'is', null).limit(50)
    if (error) throw error
    if (!data?.length) return n
    const ids = data.map((r) => r.source_id)
    await markContacted(ids)
    const { error: upErr } = await supa.from('leads').update({ console_mark_pending: false }).in('source_id', ids)
    if (upErr) throw upErr
    n += ids.length
  }
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
 *  This runs unattended every fifteen minutes, so it leans towards doing nothing:
 *  it writes a lead only when the console has something different to say about it,
 *  and a lead that has gone missing is reported rather than deleted. */
export async function refreshImported(skipIds = new Set()) {
  const held = await heldSourceIds()
  if (!held.size) return { written: 0, detail: null }

  const seen = new Set()
  let written = 0, refreshed = 0, suppressed = 0
  for await (const page of allLeads()) {
    const ours = []
    for (const row of page) {
      const id = Number(row.id)
      if (!held.has(id)) continue
      seen.add(id)
      // The ones the dialable pull just wrote are already current.
      if (!skipIds.has(id)) ours.push(row)
    }
    for (let i = 0; i < ours.length; i += WRITE_BATCH) {
      const slice = ours.slice(i, i + WRITE_BATCH)
      const { upserted, refreshed: again, ids } = await upsertLeads(slice, { markPending: false })
      written += upserted
      refreshed += again
      // A lead the console now marks do-not-call must not merely be updated here:
      // the number goes on the suppression list, which is what keeps it out of
      // every queue and out of any twin of it we hold on the same number. The ones
      // already suppressed are left alone, or every pull would redo the same work.
      const dnc = slice
        .filter((row) => String(row.contact_status ?? '') === 'do_not_call')
        .map((row) => ids.get(Number(row.id)))
        .filter((id) => id != null)
      if (dnc.length) {
        const states = await statesOf(dnc)
        for (const leadId of dnc) {
          if (['suppressed', 'handoff'].includes(states.get(leadId))) continue
          await suppressLead(leadId, 'dnc')
          suppressed++
        }
      }
    }
  }

  // A lead the dialable pull just read off the console is plainly still there,
  // whatever the census managed to show us.
  const missing = [...held].filter((id) => !seen.has(id) && !skipIds.has(id))
  const notes = []
  if (suppressed) notes.push(`${suppressed} lead(s) the console now marks do-not-call were suppressed here.`)
  if (missing.length) {
    // Deleting leads on the strength of a list we paged through would be a bad
    // trade: the console counts and lists in two queries and orders by a score the
    // scraper keeps changing, so a row can slip between pages. Say what we saw.
    const shown = missing.slice(0, 20).join(', ')
    notes.push(`${missing.length} lead(s) we hold were not in the console's list this time`
      + ` (${shown}${missing.length > 20 ? ', and more' : ''}).`
      + ' Nothing was changed here — they may have been deleted in the console, or the'
      + ' list may have moved under us while we read it.')
  }
  console.log(`  refreshed ${seen.size} already-imported leads: ${written} written, ${refreshed} requeued`)
  for (const note of notes) console.log(`  ${note}`)
  return { written, detail: notes.join(' ') || null }
}

// --marks-only: just retry the console `contacted` marks a failed run left pending
async function marksOnly() {
  await ensureAuth()
  return flushContacted()
}

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}`) {
  logRun('pull_leads', process.argv[2] === '--marks-only' ? marksOnly : pull)
    .then((n) => { console.log(`pull done: ${n} leads`); process.exit(0) })
    .catch((e) => { console.error(e); process.exit(1) })
}
