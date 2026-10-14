// One sync at a time, across edge instances that share nothing: the open run in
// sync_runs is the lock. An edge instance cannot outlive its own clock (150 s on
// this plan), so a run still open after the lease was not finished by anyone —
// the runtime ended that instance mid-run (its clock or its CPU budget) and the
// catch that would have closed the row never ran. Seven of the first thousand
// hosted pulls went that way, and each one also made the next pull wait out the
// old twenty-minute lease. So the lease is three minutes, and a run found past
// it is closed as failed by whoever finds it, with the reason on the row.
export const LEASE_MIN = 3

export const DIED = 'the run stopped before it could finish: the edge runtime ended it (its clock or CPU budget ran out)'

/** Split the open runs into the one still inside its lease and the ones that died. */
export function splitUnfinished(rows, nowMs, leaseMs) {
  const live = []
  const dead = []
  for (const r of rows ?? []) {
    const t = Date.parse(r?.started_at ?? '')
    if (Number.isFinite(t) && nowMs - t < leaseMs) live.push(r)
    else dead.push(r)
  }
  return { live, dead }
}
