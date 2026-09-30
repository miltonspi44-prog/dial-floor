import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { dispositionLabel } from '../lib/types'
import type { RecyclePool, RecyclePoolKey, RecyclePools, RecyclePreview } from '../lib/types'

const POOL: Record<RecyclePoolKey, { title: string; what: string }> = {
  provider: { title: 'Already has a provider', what: 'Parked for good until now. They come back as a win-back call: “how is it going with them?”' },
  resting: { title: 'Resting after a no', what: '“Not interested” and language-barrier leads, before their rest is over (they rejoin on their own when it ends).' },
  season: { title: 'Resting, trade in season', what: 'Resting leads whose trade’s season is open now.' },
}
const AGES = [0, 30, 90, 180, 365] as const

function ageLabel(d: number): string {
  if (d === 0) return 'all'
  return d >= 365 ? '1 year+' : d >= 180 ? '6 months+' : d >= 90 ? '3 months+' : `${d} days+`
}
function countFor(p: RecyclePool, d: number): number {
  return d === 0 ? p.total : p.ages[String(d) as keyof RecyclePool['ages']] ?? 0
}

/** B7: parked leads come back when the manager says; the automatic option starts off. */
export default function RecyclePanel() {
  const [pools, setPools] = useState<RecyclePools | null>(null)
  const [pick, setPick] = useState<{ pool: RecyclePoolKey; days: number } | null>(null)
  const [preview, setPreview] = useState<RecyclePreview | null>(null)
  const [asList, setAsList] = useState(true)
  const [auto, setAuto] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)

  function say(m: string) {
    setMsg(m)
    window.setTimeout(() => setMsg(null), 4000)
  }

  const load = useCallback(() => {
    supabase.rpc('recycle_pools').then(({ data, error }) => {
      if (error) { setMsg(error.message); return }
      const d = data as RecyclePools
      setPools(d)
      setAuto(d.auto_provider_days ? String(d.auto_provider_days) : '')
    })
  }, [])
  useEffect(() => { load() }, [load])

  function choose(pool: RecyclePoolKey, days: number) {
    setPick({ pool, days })
    setPreview(null)
    supabase.rpc('recycle_preview', { p_pool: pool, p_min_days: days }).then(({ data, error }) => {
      if (error) { say(error.message); return }
      setPreview(data as RecyclePreview)
    })
  }

  async function recycle() {
    if (!pick) return
    setBusy(true)
    const { data, error } = await supabase.rpc('recycle', { p_pool: pick.pool, p_min_days: pick.days, p_as_list: asList })
    setBusy(false)
    if (error) { say(error.message); return }
    const r = data as { recycled: number; listed: number }
    say(`${r.recycled} lead${r.recycled === 1 ? '' : 's'} back in the queue${r.listed ? `, ${r.listed} on a shared list (assign it on the Lists tab)` : ''}`)
    setPick(null); setPreview(null)
    load()
  }

  async function saveAuto() {
    const n = Math.max(0, Math.min(3650, Math.round(Number(auto) || 0)))
    const { error } = await supabase.from('app_settings').upsert({ key: 'recycle_provider_days', value: n, updated_at: new Date().toISOString() })
    say(error ? error.message : n ? `“Has a provider” leads now come back on their own after ${n} days` : 'Automatic recycling is off: leads come back only when you recycle them')
    load()
  }

  return (
    <>
      <div className="sectionhead">
        <h3>Recycle</h3>
        <span className="muted small">bring parked leads back when you choose; do-not-call and handed-off leads never come back</span>
      </div>
      {!pools ? <div className="card muted small">{msg ?? 'Loading…'}</div> : (
        <>
          <div className="radargrid">
            {pools.pools.map((p) => (
              <div key={p.pool} className={`card radarcard ${pick?.pool === p.pool ? 'picked' : ''}`}>
                <div className="kpilabel">{POOL[p.pool].title}</div>
                <div className="kpivalue">{p.total}</div>
                <div className="kpisub">{POOL[p.pool].what}</div>
                {Object.keys(p.outcomes).length > 0 && p.pool !== 'provider' && (
                  <div className="kpisub">{Object.entries(p.outcomes).map(([o, n]) => `${dispositionLabel(o === 'unknown' ? null : o)} ${n}`).join(' · ')}</div>
                )}
                {p.total > 0 && (
                  <div className="agerow">
                    <span className="kpilabel">Parked</span>
                    <div className="agebtns">
                      {AGES.map((d) => {
                        const n = countFor(p, d)
                        return (
                          <button key={d} className={`btn ghost small ${pick?.pool === p.pool && pick.days === d ? 'on' : ''}`}
                            disabled={!n} onClick={() => choose(p.pool, d)}>
                            {ageLabel(d)} ({n})
                          </button>
                        )
                      })}
                    </div>
                  </div>
                )}
              </div>
            ))}
          </div>

          {pick && (
            <div className="card" style={{ marginTop: 12 }}>
              {!preview ? <span className="muted small">Counting…</span> : (
                <>
                  <p style={{ marginTop: 0 }}>
                    <b>{preview.count}</b> {POOL[pick.pool].title.toLowerCase()} lead{preview.count === 1 ? '' : 's'}, parked {ageLabel(pick.days) === 'all' ? 'any time' : ageLabel(pick.days).replace('+', ' ago or more')}.
                    {pick.pool === 'provider' && ' They come back tagged “Provider win-back”.'}
                  </p>
                  {preview.sample.length > 0 && (
                    <ul className="radarlist">
                      {preview.sample.map((s) => (
                        <li key={s.lead_id}>
                          <span><b>{s.name}</b> <span className="muted">{[s.trade, [s.city, s.state].filter(Boolean).join(', ')].filter(Boolean).join(' · ')}</span></span>
                          <span className="muted small">{dispositionLabel(s.outcome)} · {new Date(s.parked_at).toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })}</span>
                        </li>
                      ))}
                      {preview.count > preview.sample.length && <li className="muted small">…and {preview.count - preview.sample.length} more, longest parked first</li>}
                    </ul>
                  )}
                  <div className="actionrow" style={{ marginTop: 10 }}>
                    <label className="radio"><input type="checkbox" checked={asList} onChange={(e) => setAsList(e.target.checked)} /> as a shared list, served before the general pool</label>
                    <button className="btn primary" onClick={recycle} disabled={busy || !preview.count}>Recycle {preview.count}</button>
                    <button className="btn ghost" onClick={() => { setPick(null); setPreview(null) }}>Cancel</button>
                  </div>
                </>
              )}
            </div>
          )}

          <div className="card" style={{ marginTop: 12 }}>
            <div className="formrow">
              <label>Bring “has a provider” leads back on their own after
                <span className="actionrow" style={{ gap: 6 }}>
                  <input type="number" min={0} style={{ width: 100 }} value={auto} onChange={(e) => setAuto(e.target.value)} placeholder="off" />
                  <span className="muted small">days</span>
                </span>
              </label>
              <button className="btn" onClick={saveAuto} disabled={String(pools.auto_provider_days || '') === auto}>Save</button>
              <span className="muted small">Off (blank or 0) by default: then they come back only when you recycle them above.</span>
            </div>
          </div>
        </>
      )}
      {msg && pools && <div className="toast">{msg}</div>}
    </>
  )
}
