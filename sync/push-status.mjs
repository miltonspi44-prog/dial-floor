// Write terminal statuses back to the console (do_not_call, captured,
// not_interested, wrong_number, callback, long_term). The console updates its
// MySQL row and queues the change; the scraper's sync agent pulls it into
// leads.db through its existing channel — the scraper project stays untouched.
import { ensureAuth, setStatus, isAuthFailure, isRejected } from './lib/console.mjs'
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
  let n = 0, refused = 0
  let deferred = null
  for (const row of pending) {
    const srcId = row.leads?.source_id
    if (srcId) {
      try {
        await setStatus(srcId, row.writeback_status, row.writeback_note)
      } catch (e) {
        // The password being wrong is not this row's problem and no row will get
        // through; let it out so the loop can stop instead of hammering the console.
        if (isAuthFailure(e)) throw e
        if (!isRejected(e)) {
          // The console is down, slow, or having a bad minute. This row is still
          // good and goes out next time; the rest of the batch would only queue up
          // behind the same wall, so stop here and say why.
          deferred = e.message
          console.error(`  stopping early, the rest goes out next run: ${e.message}`)
          break
        }
        // The console has read this and said no — there is no such lead over there
        // any more, or it does not know that status. Trying again every minute for
        // ever changes nothing, so stop asking and keep the reason where it can be
        // read later.
        console.error(`  the lead console would not take console lead ${srcId}: ${e.message}`)
        await supa.from('lead_state').update({
          writeback_done: true,
          writeback_note: refusedNote(row.writeback_note, e.message),
        }).eq('lead_id', row.lead_id)
        refused++
        continue
      }
    }
    await supa.from('lead_state').update({ writeback_done: true }).eq('lead_id', row.lead_id)
    n++
  }

  const notes = []
  if (refused) notes.push(`${refused} status(es) the console refused for good were marked done, with the reason in the note.`)
  if (deferred) notes.push(`Stopped early and left the rest for the next run: ${deferred}`)
  return { rows: n, detail: notes.join(' ') || null }
}

/** Keep the agent's own note and add why it never left the building. lead_state
 *  has nowhere else to put this, and a note nobody can find is no record at all. */
function refusedNote(note, why) {
  return `${note ? `${note} — ` : ''}not sent to the lead console: ${why}`.slice(0, 500)
}

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}`) {
  logRun('push_status', push)
    .then((n) => { console.log(`push done: ${n} statuses`); process.exit(0) })
    .catch((e) => { console.error(e); process.exit(1) })
}
