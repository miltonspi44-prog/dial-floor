// Pull dialable leads from the hosted console into the dialing DB.
// Every NEWLY imported lead is marked `contacted` in the console, so the
// scraper's permanent suppression stops it from ever re-exporting elsewhere.
import { ensureAuth, dialableLeads, markContacted } from './lib/console.mjs'
import { upsertLeads, logRun } from './lib/supa.mjs'

export async function pull() {
  await ensureAuth()
  let total = 0
  const newlyImported = []
  for await (const page of dialableLeads()) {
    const { imported, upserted } = await upsertLeads(page)
    newlyImported.push(...imported)
    total += upserted
    console.log(`  upserted ${upserted} (new: ${imported.length})`)
  }
  if (newlyImported.length) {
    await markContacted(newlyImported)
    console.log(`  marked ${newlyImported.length} as contacted in the console`)
  }
  return total
}

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}`) {
  logRun('pull_leads', pull)
    .then((n) => { console.log(`pull done: ${n} leads`); process.exit(0) })
    .catch((e) => { console.error(e); process.exit(1) })
}
