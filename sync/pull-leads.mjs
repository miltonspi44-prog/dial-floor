// Pull dialable leads from the hosted console into the dialing DB.
// Every NEWLY imported lead is marked `contacted` in the console, so the
// scraper's permanent suppression stops it from ever re-exporting elsewhere.
import { ensureAuth, dialableLeads, markContacted } from './lib/console.mjs'
import { supa, upsertLeads, logRun } from './lib/supa.mjs'

export async function pull() {
  await ensureAuth()
  let total = 0
  for await (const page of dialableLeads()) {
    const { imported, upserted } = await upsertLeads(page, { markPending: true })
    total += upserted
    console.log(`  upserted ${upserted} (new: ${imported.length})`)
  }
  const marked = await flushContacted()
  if (marked) console.log(`  marked ${marked} as contacted in the console`)
  return total
}

/** Tell the console about every lead still waiting to be marked contacted,
 *  including any that a failed earlier run left behind. */
export async function flushContacted() {
  let n = 0
  for (;;) {
    const { data, error } = await supa.from('leads').select('source_id')
      .eq('console_mark_pending', true).not('source_id', 'is', null).limit(200)
    if (error) throw error
    if (!data?.length) return n
    const ids = data.map((r) => r.source_id)
    await markContacted(ids)
    const { error: upErr } = await supa.from('leads').update({ console_mark_pending: false }).in('source_id', ids)
    if (upErr) throw upErr
    n += ids.length
  }
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
