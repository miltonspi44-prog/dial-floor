// Long-running mode: pull every PULL_INTERVAL_MIN (default 15), push every minute.
// Run it on any always-on PC:  npm run loop
// (or via Task Scheduler — sync/README.md has the step-by-step)
import './lib/client-node.mjs'
import { pull } from './pull-leads.mjs'
import { push } from './push-status.mjs'
import { logRun } from './lib/supa.mjs'
import { isAuthFailure } from './lib/console.mjs'

const PULL_MIN = Number(process.env.PULL_INTERVAL_MIN ?? 15)

// One sync at a time. A full pull can easily outlast its own fifteen minutes, and
// two of them at once would fight over the same console session and write the same
// leads twice over. A push that gets skipped loses nothing: whatever was pending is
// still pending a minute later.
let busy = false
let stopped = false
const timers = []
const at = () => new Date().toLocaleTimeString()

async function safely(kind, fn) {
  if (stopped) return
  if (busy) { console.log(`[${at()}] ${kind} skipped: the sync before it is still running`); return }
  busy = true
  try {
    const n = await logRun(kind, fn)
    console.log(`[${at()}] ${kind}: ${n}`)
  } catch (e) {
    console.error(`[${at()}] ${kind} FAILED: ${e.message}`)
    // The console has refused our password. Every run from here on would be another
    // failed sign-in, and ten of those lock the console for the owner too, so the
    // loop stops. console.mjs has already printed what to do about it.
    //
    // Only that. A console that is locked, asleep, slow, or losing our session is
    // not this, and the loop keeps its clock and comes back on the next tick: those
    // all clear up by themselves, and stopping the worker over one would mean nobody
    // calls anybody until a person notices it is down.
    if (isAuthFailure(e)) stop()
  } finally {
    busy = false
  }
}

function stop() {
  stopped = true
  for (const t of timers) clearInterval(t)
  console.error(`[${at()}] sync loop stopped. Start it again once the password is sorted out.`)
  // A non-zero exit is how Task Scheduler and any service wrapper show this needs
  // a person. Nothing is left on the clock, so the process ends on its own.
  process.exitCode = 1
}

console.log(`dial-floor sync loop — pull every ${PULL_MIN} min, push every 60s`)
await safely('pull_leads', pull)
await safely('push_status', push)
if (!stopped) {
  timers.push(setInterval(() => safely('pull_leads', pull), PULL_MIN * 60_000))
  timers.push(setInterval(() => safely('push_status', push), 60_000))
}
