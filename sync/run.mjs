// Long-running mode: pull every PULL_INTERVAL_MIN (default 15), push every minute.
// Run it on any always-on PC:  npm run loop   (or via Task Scheduler, see README)
import { pull } from './pull-leads.mjs'
import { push } from './push-status.mjs'
import { logRun } from './lib/supa.mjs'

const PULL_MIN = Number(process.env.PULL_INTERVAL_MIN ?? 15)

async function safely(kind, fn) {
  try {
    const n = await logRun(kind, fn)
    console.log(`[${new Date().toLocaleTimeString()}] ${kind}: ${n}`)
  } catch (e) {
    console.error(`[${new Date().toLocaleTimeString()}] ${kind} FAILED: ${e.message}`)
  }
}

console.log(`dial-floor sync loop — pull every ${PULL_MIN} min, push every 60s`)
await safely('pull_leads', pull)
await safely('push_status', push)
setInterval(() => safely('pull_leads', pull), PULL_MIN * 60_000)
setInterval(() => safely('push_status', push), 60_000)
