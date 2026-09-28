// Write terminal statuses back to the console (do_not_call, captured,
// not_interested, wrong_number, callback, long_term). The console updates its
// MySQL row and queues the change; the scraper's sync agent pulls it into
// leads.db through its existing channel — the scraper project stays untouched.
import { ensureAuth, setStatus } from './lib/console.mjs'
import { supa, logRun } from './lib/supa.mjs'

export async function push() {
  const { data: pending, error } = await supa
    .from('lead_state')
    .select('lead_id, writeback_status, writeback_note, leads!inner(source_id)')
    .eq('writeback_done', false)
    .not('writeback_status', 'is', null)
    .limit(200)
  if (error) throw error
  if (!pending?.length) return 0

  await ensureAuth()
  let n = 0
  for (const row of pending) {
    const srcId = row.leads?.source_id
    if (srcId) {
      try {
        await setStatus(srcId, row.writeback_status, row.writeback_note)
      } catch (e) {
        console.error(`  status push failed for console lead ${srcId}: ${e.message}`)
        continue
      }
    }
    await supa.from('lead_state').update({ writeback_done: true }).eq('lead_id', row.lead_id)
    n++
  }
  return n
}

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}`) {
  logRun('push_status', push)
    .then((n) => { console.log(`push done: ${n} statuses`); process.exit(0) })
    .catch((e) => { console.error(e); process.exit(1) })
}
