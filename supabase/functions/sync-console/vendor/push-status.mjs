// Write terminal statuses back to the console (do_not_call, captured,
// not_interested, wrong_number, callback, long_term). The console updates its
// MySQL row and queues the change; the scraper's sync agent pulls it into
// leads.db through its existing channel — the scraper project stays untouched.
import {
  ensureAuth, setStatus, consoleAnswers, isAuthFailure, isRejected, isUnreachable,
} from './console.mjs'
import { supa, logRun } from './supa.mjs'

// How many statuses one run takes on. Every one of them is attempted every run,
// including the ones that failed last time: a status that never goes over is a
// number the console still hands out, so it is worth a wasted request a minute.
const BATCH = 200

// How long one row has to have been failing before we stop trying it — and only ever
// together with proof, from the same run, that the console is taking other rows.
// The console wraps its whole status write in one try/catch, so a note its MySQL
// cannot store comes back as a 500 that looks exactly like the console having a bad
// minute. What tells those two apart is not elapsed time: it is the console accepting
// somebody else's status in the same breath as it refuses this one.
const GIVE_UP_AFTER_H = 24

// Once the oldest waiting status has waited longer than this, every run says so
// loudly. A status that has not gone over means the console still lists that lead as
// dialable and the scraper can export its number again, so even an hour is wrong.
const WAITING_WARN_H = 2

// Written only once a row has been shown to be the problem, so they can be absent on
// a dialing DB that has not had migration 0025 applied. Everything else works without
// them; what is lost is the ability to ever stop trying a row the console will never
// accept, and any record of why it would not. push() says so out loud when it matters.
const FAILURE_COLUMNS = 'writeback_failed_at, writeback_error'

export async function push() {
  const { pending, more, tracked } = await pendingStatuses()

  // Said every run, before anything that can fail, because a dead write-back and a
  // quiet minute both used to read as "0" in sync_runs. With only that to go on, the
  // first sign of a stalled queue was an agent being handed a number the console was
  // told never to call again, weeks later.
  const waiting = whatIsWaiting(pending, more)
  console.log(`  ${waiting.line}`)
  if (waiting.tooOld) shoutAboutTheQueue(waiting)
  if (!pending.length) return { rows: 0, detail: waiting.line }

  await ensureAuth()
  let n = 0, refused = 0, unsaved = 0
  let stopped = null
  // Rows the console gave a real answer about: it took the status, or it read it and
  // said no. A 500 is neither — its own database fell over inside the write, and that
  // says nothing whatever about the row we sent it.
  let answered = 0
  const failed = []

  for (const row of pending) {
    const srcId = row.leads?.source_id
    if (srcId) {
      try {
        await setStatus(srcId, row.writeback_status, row.writeback_note)
        answered++
      } catch (e) {
        // The password being wrong is not this row's problem and no row will get
        // through; let it out so the loop can stop instead of hammering the console.
        if (isAuthFailure(e)) throw e
        if (isRejected(e)) {
          // The console has read this and said no — there is no such lead over there
          // any more, or it does not know that status. Trying again every minute for
          // ever changes nothing, so stop asking and keep the reason where it can be
          // read later.
          answered++
          console.error(`  the lead console would not take console lead ${srcId}: ${e.message}`)
          if (await settled(row.lead_id, {
            writeback_done: true,
            writeback_note: refusedNote(row.writeback_note, e.message),
          })) refused++
          else unsaved++
          continue
        }
        // Not a no, and not something that can be told apart from the console having a
        // bad minute. So nothing is decided about this row here: it is kept, the next
        // row gets its turn, and what it all meant is worked out below, once the whole
        // batch has been tried and we know whether the console took anything at all.
        console.error(`  the console would not take console lead ${srcId} this time: ${e.message}`)
        failed.push({ row, srcId, why: e.message })
        if (!isUnreachable(e)) continue
        // No answer at all. That could be the host, or it could be this one row — its
        // firewall cuts a request whose body it dislikes, and a PHP fatal on a long note
        // closes the socket. Reading it as "the host is gone" is what stranded every
        // status behind one bad row, so ask the console instead of guessing: if it
        // answers, carry on down the batch.
        if (await consoleAnswers()) continue
        stopped = `the console is not answering at all (${e.message})`
        console.error('  the console is not there; the rest goes out next run.')
        break
      }
    }
    if (await settled(row.lead_id, { writeback_done: true })) n++
    else unsaved++
  }

  // Only with the batch tried is there anything honest to say about a row that
  // failed: the console took somebody else's status in this same run, so what it will
  // not have is this row. While it is failing on everything, none of this is about the
  // rows — not one of them is recorded against, and not one is written off. A day of a
  // host's database being down is not evidence about a lead, and writing off a
  // do-not-call on the strength of it is how a number the console was told never to
  // call again goes back into the queue, with nobody any the wiser.
  const consoleIsWorking = answered > 0
  let gaveUp = 0
  if (consoleIsWorking) {
    for (const f of failed) {
      // The first failure's time is the one kept: it is the age that decides.
      const firstFailed = f.row.writeback_failed_at ?? new Date().toISOString()
      if (tracked) await recordFailure(f, firstFailed)
      if (Date.now() - Date.parse(firstFailed) < GIVE_UP_AFTER_H * 3_600_000) continue
      console.error(`  giving up on console lead ${f.srcId}: the console has taken other statuses`
        + ` and gone on refusing this one for over ${GIVE_UP_AFTER_H}h: ${f.why}`)
      if (await settled(f.row.lead_id, {
        writeback_done: true,
        writeback_note: refusedNote(f.row.writeback_note, f.why),
      })) { gaveUp++; f.writtenOff = true }
      else unsaved++
    }
  }
  const held = failed.filter((f) => !f.writtenOff).length

  const notes = [waiting.line]
  if (refused) notes.push(`${refused} status(es) the console refused for good were marked done, with the reason in the note.`)
  if (gaveUp) notes.push(`${gaveUp} status(es) the console kept refusing for over ${GIVE_UP_AFTER_H} hours`
    + ' while taking others were given up on, with the reason in the note.')
  if (held) notes.push(`${held} status(es) the console would not take this time are waiting for the next run.`)
  if (held && !consoleIsWorking) notes.push('It took none of them, so nothing here tells us whether it'
    + ' is the console or the leads: nothing was written off and nothing was recorded against any lead.')
  if (held && !tracked) {
    const missing = 'How long each one has been failing is not being recorded, so none of them will'
      + ' ever be given up on and nothing says why they failed.'
      + ' Migration 0025_writeback_failures.sql adds the two columns for that.'
    // In the log as well as in the run's detail: a safeguard nobody is told is missing
    // reads like a safeguard that is there.
    console.error(`  ${missing}`)
    notes.push(missing)
  }
  if (unsaved) notes.push(`${unsaved} status(es) could not be written off here, so they will be`
    + ' tried again on the next run — see the log for what the dialing DB said.')
  if (stopped) notes.push(`Stopped early and left the rest for the next run: ${stopped}`)
  return { rows: n, detail: notes.join(' ') }
}

/** How much is waiting to go to the console and how long the oldest has waited, in
 *  one line fit for the log and for a run's detail. `updated_at` is the closest
 *  lead_state has to "when this status was promised": every path that promises one
 *  sets it in the same statement. */
function whatIsWaiting(pending, more) {
  if (!pending.length) return { count: 0, tooOld: false, line: 'Nothing is waiting to go to the lead console.' }
  const count = more ? `more than ${BATCH}` : String(pending.length)
  const oldest = pending.reduce((so_far, r) => {
    const t = Date.parse(r.updated_at ?? '')
    return Number.isFinite(t) && t < so_far ? t : so_far
  }, Infinity)
  const waited = Number.isFinite(oldest) ? Math.max(0, Date.now() - oldest) : null
  // Past the batch we have not looked, so the true oldest can only be older.
  const howLong = waited == null ? null : `${more ? 'at least ' : ''}${forHowLong(waited)}`
  const tooOld = waited != null && waited > WAITING_WARN_H * 3_600_000
  // Tense-free on purpose: the same sentence is the log line at the start of the run
  // and the first line of the run's detail afterwards, however the run then went.
  const line = `${count} status(es) waiting for the lead console`
    + `${howLong ? `, the oldest for ${howLong}` : ''}${tooOld ? ' — far too long' : ''}.`
  return { count, howLong, tooOld, line }
}

/** A length of time the way a person would say it. */
function forHowLong(ms) {
  const minutes = Math.floor(ms / 60_000)
  if (minutes < 1) return 'less than a minute'
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'}`
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return `${hours} hour${hours === 1 ? '' : 's'}`
  return `${Math.floor(hours / 24)} days`
}

/** The owner's one real signal that the write-back has stalled. Printed on every run
 *  it is true of, because what it is about stays broken until somebody looks at it. */
function shoutAboutTheQueue(waiting) {
  console.error('')
  console.error(`The lead console has not taken ${waiting.count} status change(s) from the dialer.`)
  console.error(`The oldest has been waiting ${waiting.howLong}.`)
  console.error('Until it takes them the console still lists those leads as dialable, and the scraper')
  console.error('can export their numbers again — including the ones somebody asked never to be called.')
  console.error('What to do: open the console and check it is up and its database is working. If the')
  console.error('lines above name one lead over and over, it is that lead\'s note the console cannot')
  console.error('store — shorten it or take the emoji out of it in the dialer.')
  console.error('')
}

/** The statuses waiting to go out: the ones never tried first, then the ones the
 *  console has been refusing longest, so a lead it keeps failing on never sits in
 *  front of a status nobody has tried yet. `tracked` is false on a dialing DB without
 *  the two failure columns, which costs the ability to ever give up on a row.
 *  `more` says the queue is longer than one batch. */
async function pendingStatuses() {
  const wanted = 'lead_id, writeback_status, writeback_note, updated_at, leads!inner(source_id)'
  const ready = (cols) => supa.from('lead_state').select(cols)
    .eq('writeback_done', false)
    .not('writeback_status', 'is', null)

  // One row past the batch, purely so the log can say the queue is longer than this.
  const { data, error } = await ready(`${wanted}, ${FAILURE_COLUMNS}`)
    .order('writeback_failed_at', { ascending: true, nullsFirst: true })
    .limit(BATCH + 1)
  if (!error) return oneBatch(data, true)
  if (!missingColumn(error)) throw error

  const plain = await ready(wanted).limit(BATCH + 1)
  if (plain.error) throw plain.error
  return oneBatch(plain.data, false)
}

function oneBatch(data, tracked) {
  const rows = data ?? []
  return { pending: rows.slice(0, BATCH), more: rows.length > BATCH, tracked }
}

/** Whether a Postgres complaint is "that column does not exist", which is the one
 *  error we answer by asking for less rather than by giving up. */
function missingColumn(error) {
  const code = String(error?.code ?? '')
  if (code === '42703' || code === 'PGRST204') return true
  return /writeback_failed_at|writeback_error/.test(String(error?.message ?? ''))
}

/** Write a lead_state change and say whether it stuck. supabase-js hands errors back
 *  rather than throwing them, so an unchecked write here is how "stop retrying this"
 *  quietly became "retry it for ever". */
async function settled(leadId, patch) {
  const { error } = await supa.from('lead_state').update(patch).eq('lead_id', leadId)
  if (!error) return true
  console.error(`  could not record the write-back for lead ${leadId}: ${error.message}`)
  return false
}

/** Remember when the console started refusing this one row while taking others, and
 *  what it said about it, so a row it will never accept can be given up on instead of
 *  blocking a minute every minute — and so a manager can read why it never went.
 *  Only ever called once the console has proved it is taking statuses, so the stamp
 *  means "refused while the console was working", not "waiting since". */
async function recordFailure(f, firstFailed) {
  const { error } = await supa.from('lead_state').update({
    writeback_failed_at: firstFailed,
    writeback_error: String(f.why).slice(0, 500),
  }).eq('lead_id', f.row.lead_id)
  if (error) console.error(`  could not record why lead ${f.row.lead_id} failed: ${error.message}`)
}

/** Keep the agent's own note and add why it never left the building. lead_state
 *  has nowhere else to put this, and a note nobody can find is no record at all. */
function refusedNote(note, why) {
  return `${note ? `${note} — ` : ''}not sent to the lead console: ${why}`.slice(0, 500)
}

// Run directly under Node (`npm run pull` / `npm run push`); under Deno this
// file is a library and globalThis.process is nobody, so the guard stays false.
const argv1 = globalThis.process?.argv?.[1]
if (argv1 && import.meta.url === `file://${argv1.replace(/\\/g, '/')}`) {
  logRun('push_status', push)
    .then((n) => { console.log(`push done: ${n} statuses`); process.exit(0) })
    .catch((e) => { console.error(e); process.exit(1) })
}
