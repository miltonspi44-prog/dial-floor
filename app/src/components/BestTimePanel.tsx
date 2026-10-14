import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { hourLabel } from '../lib/types'
import type { BestTimes } from '../lib/types'

function pct(r: number): string {
  return `${Math.round(r * 100)}%`
}

/** C6: when each trade picks up, on the lead's own clock. One factor among
 *  several: a hint on the Dial page, and (switched on) a lean in the pool. */
export default function BestTimePanel() {
  const [b, setB] = useState<BestTimes | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)

  const load = useCallback(() => {
    supabase.rpc('best_times').then(({ data, error }) => {
      if (error) { setMsg(error.message); return }
      setB(data as BestTimes)
    })
  }, [])
  useEffect(() => { load() }, [load])

  async function toggleQueue() {
    if (!b) return
    setBusy(true)
    const { data } = await supabase.from('app_settings').select('value').eq('key', 'best_time').maybeSingle()
    const value = { ...((data?.value ?? {}) as Record<string, unknown>), use_in_queue: !b.use_in_queue }
    const { error } = await supabase.from('app_settings').upsert({ key: 'best_time', value, updated_at: new Date().toISOString() })
    setBusy(false)
    setMsg(error ? error.message : null)
    load()
  }

  const st = b?.state
  const hours = (b?.hours ?? []).filter((h) => h.dials > 0)
  const maxRate = Math.max(0.01, ...hours.map((h) => h.rate))
  const trades = (b?.trades ?? []).filter((t) => t.cells.length)

  return (
    <>
      <div className="sectionhead">
        <h3>Best time to call</h3>
        <span className="muted small">pickup rate by the lead's own hour, learned from your calls; one factor among several</span>
      </div>
      <div className="card">
        {!b ? <span className="muted small">{msg ?? 'Loading…'}</span> : (
          <>
            {!b.ready ? (
              <div>
                <p style={{ marginTop: 0 }}>
                  <b>Learning.</b> {st?.total ?? 0} of the {st?.min_total ?? 1000} logged dials it needs (last {st?.days ?? 90} days).
                  Until then the Dial page shows no hints and the queue ignores it: thin data would only add noise.
                </p>
                <div className="targetbar" style={{ maxWidth: 420 }}>
                  <i style={{ width: `${Math.min(100, (100 * (st?.total ?? 0)) / (st?.min_total || 1000))}%` }} />
                </div>
              </div>
            ) : (
              <p style={{ marginTop: 0 }} className="small">
                From {st?.total.toLocaleString()} logged dials in the last {st?.days} days, {pct(st?.rate ?? 0)} picked up.
                An hour counts once it has {st?.min_dials}+ dials; until then it leans on the trade's all-day rate.
                {st?.at && <span className="muted"> Updated {new Date(st.at).toLocaleString([], { dateStyle: 'short', timeStyle: 'short' })}.</span>}
              </p>
            )}

            {hours.length > 0 && (
              <div className="tablewrap">
                <table className="data">
                  <thead><tr><th>Their hour</th><th className="barcol">Picked up, every trade</th><th className="num">Dials</th></tr></thead>
                  <tbody>
                    {hours.map((h) => (
                      <tr key={h.hour} className={h.reliable ? '' : 'thin'}>
                        <td>{hourLabel(h.hour)}</td>
                        <td className="barcol">
                          <span className="barcell">
                            <span className="minibar"><i style={{ width: `${(100 * h.rate) / maxRate}%` }} /></span>
                            <span className="n">{pct(h.rate)}</span>
                          </span>
                        </td>
                        <td className="num">{h.dials}{h.reliable ? '' : <span className="muted"> (few)</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}

            {b.ready && (
              trades.length ? (
                <div className="tablewrap" style={{ marginTop: 12 }}>
                  <table className="data">
                    <thead><tr><th>Trade</th><th className="num">Dials</th><th className="num">All day</th><th>Best hours, their time</th></tr></thead>
                    <tbody>
                      {trades.map((t) => (
                        <tr key={t.trade}>
                          <td>{t.label ?? t.trade.replace(/_/g, ' ')}</td>
                          <td className="num">{t.dials}</td>
                          <td className="num">{pct(t.rate)}</td>
                          <td className="small">{t.cells.slice(0, 3).map((c) => `${hourLabel(c.hour)} ${pct(c.rate)}`).join(' · ')}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ) : <p className="muted small">No trade has an hour with enough dials yet.</p>
            )}

            <div className="actionrow" style={{ marginTop: 12 }}>
              <label className="radio">
                <input type="checkbox" checked={b.use_in_queue} onChange={toggleQueue} disabled={busy} />
                Use it in the queue
              </label>
              <span className="muted small">
                Off by default. On, the general pool leans toward trades in a good hour right now: the lead score × that hour's lift,
                held between 0.7 and 1.3, so it reorders the pool without overriding it. Lists and callbacks keep their own order.
                {!b.ready && ' It has no effect until the model is ready.'}
              </span>
            </div>
            {msg && <div className="warnline">{msg}</div>}
          </>
        )}
      </div>
    </>
  )
}
