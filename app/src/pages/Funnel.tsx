import { useEffect, useState } from 'react'
import { supabase, loadTargets } from '../lib/supabase'
import { hourLabel } from '../lib/types'
import type { FunnelCounts, FunnelData, Targets } from '../lib/types'
import BestTimePanel from '../components/BestTimePanel'

const RANGES = [
  { days: 1, label: 'Today' },
  { days: 7, label: 'Last 7 days' },
  { days: 30, label: 'Last 30 days' },
]

const SOURCE_LABEL: Record<string, string> = {
  callback: 'Callbacks',
  list: 'List',
  pool: 'General pool',
  untracked: 'Before tracking started',
}

function pct(n: number, of: number): string {
  return of ? `${Math.round((100 * n) / of)}%` : '—'
}

function talk(sec: number): string {
  const h = Math.floor(sec / 3600)
  const m = Math.round((sec % 3600) / 60)
  return h ? `${h}h ${m}m` : `${m}m`
}

function perDay(n: number, days: number): number {
  return Math.round(n / Math.max(1, days))
}

/** Stat tile: label, value, and one line of context. */
function Kpi({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="card kpi">
      <div className="kpilabel">{label}</div>
      <div className="kpivalue">{value}</div>
      {sub && <div className="kpisub">{sub}</div>}
    </div>
  )
}

/** The count columns every breakdown table shares. */
function CountCells({ r }: { r: FunnelCounts }) {
  return (
    <>
      <td className="num">{r.dials}</td>
      <td className="num">{r.answered}</td>
      <td className="num">{r.conversations}</td>
      <td className="num">{pct(r.conversations, r.dials)}</td>
      <td className="num">{r.handoffs}</td>
    </>
  )
}
const COUNT_HEADS = (
  <>
    <th className="num">Dials</th>
    <th className="num">Picked up</th>
    <th className="num">Conversations</th>
    <th className="num">Conv. rate</th>
    <th className="num">Handoffs</th>
  </>
)

export default function Funnel() {
  const [days, setDays] = useState(1)
  const [data, setData] = useState<FunnelData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [targets, setTargets] = useState<Targets>({ dials: null, connects: null, handoffs: null })
  const [draft, setDraft] = useState({ dials: '', connects: '', handoffs: '' })
  // A4: the shift the dial target is spread over, and the wrap-up countdown
  const [pacing, setPacing] = useState({ shift: '8', wrap: '20' })
  const [saved, setSaved] = useState<string | null>(null)

  function pick(d: number) {
    if (d === days) return
    setLoading(true)
    setDays(d)
  }

  useEffect(() => {
    let live = true
    supabase.rpc('funnel', { p_days: days }).then(({ data: d, error: e }) => {
      if (!live) return
      // a failed range shows the error, not the previous range's numbers under the new label
      if (e) { setError(e.message); setData(null) }
      else { setError(null); setData(d as FunnelData) }
      setLoading(false)
    })
    return () => { live = false }
  }, [days])

  useEffect(() => {
    loadTargets().then((t) => {
      setTargets(t)
      setDraft({ dials: String(t.dials ?? ''), connects: String(t.connects ?? ''), handoffs: String(t.handoffs ?? '') })
    })
    supabase.from('app_settings').select('key, value').in('key', ['shift_hours', 'wrapup_seconds']).then(({ data }) => {
      const v = new Map((data ?? []).map((r) => [r.key as string, String(r.value)]))
      setPacing({ shift: v.get('shift_hours') ?? '8', wrap: v.get('wrapup_seconds') ?? '20' })
    })
  }, [])

  async function saveTargets() {
    const rows = ([['dials_per_day', draft.dials], ['connects_per_day', draft.connects], ['handoffs_per_day', draft.handoffs]] as const)
      .filter(([, v]) => v.trim() !== '' && Number(v) >= 0)
      .map(([metric, v]) => ({ metric, target: Number(v), scope: 'agent_day', updated_at: new Date().toISOString() }))
    const now = new Date().toISOString()
    const settings = [
      { key: 'shift_hours', value: Math.max(1, Math.min(16, Number(pacing.shift) || 8)), updated_at: now },
      { key: 'wrapup_seconds', value: Math.max(0, Math.min(300, Math.round(Number(pacing.wrap) || 0))), updated_at: now },
    ]
    const { error: se } = await supabase.from('app_settings').upsert(settings)
    if (se) { setSaved(se.message); return }
    setPacing({ shift: String(settings[0].value), wrap: String(settings[1].value) })
    const { error: e } = rows.length ? await supabase.from('kpi_targets').upsert(rows) : { error: null }
    if (e) { setSaved(e.message); return }
    setTargets(await loadTargets())
    setSaved('Targets saved')
    window.setTimeout(() => setSaved(null), 2000)
  }

  const t = data?.totals
  const stages = t ? [
    { label: 'Dials', n: t.dials, note: '' },
    { label: 'Picked up', n: t.answered, note: `${pct(t.answered, t.dials)} of dials` },
    { label: 'Conversations', n: t.conversations, note: `${pct(t.conversations, t.dials)} of dials` },
    { label: 'Handoffs', n: t.handoffs, note: `${pct(t.handoffs, t.conversations)} of conversations` },
  ] : []
  const maxHour = Math.max(1, ...(data?.by_hour ?? []).map((h) => h.dials))

  return (
    <div className="page">
      <div className="rangebar" role="group" aria-label="Date range">
        {RANGES.map((r) => (
          <button key={r.days} className={`rangebtn ${days === r.days ? 'active' : ''}`} onClick={() => pick(r.days)}>
            {r.label}
          </button>
        ))}
      </div>

      {error && <div className="card alertcard">{error}</div>}

      {/* Refetching keeps the last numbers on screen, dimmed: no flash, no jump. */}
      <div className={loading && data ? 'stale' : ''}>
        {!data && loading && <div className="emptystate">Loading…</div>}
        {t && (
          <>
            <div className="kpirow">
              <Kpi label="Dials" value={t.dials.toLocaleString()} />
              <Kpi label="Picked up" value={t.answered.toLocaleString()} sub={`${pct(t.answered, t.dials)} of dials`} />
              <Kpi label="Conversations" value={t.conversations.toLocaleString()} sub={`${pct(t.conversations, t.dials)} of dials`} />
              <Kpi label="Handoffs" value={t.handoffs.toLocaleString()} sub={`${pct(t.handoffs, t.conversations)} of conversations`} />
              <Kpi label="Talk time" value={talk(t.talk_seconds)} sub={`${t.callbacks} callbacks set · ${t.emails} emails requested`} />
            </div>

            <div className="sectionhead"><h3>Funnel</h3></div>
            <div className="card">
              {t.dials ? (
                <div className="funnelbars">
                  {stages.map((s) => (
                    <div className="fstage" key={s.label}>
                      <span className="fname">{s.label}</span>
                      <span className="ftrack">
                        <span className="fbar" style={{ width: `${Math.max(0.5, (100 * s.n) / t.dials)}%` }} />
                      </span>
                      <span className="fval"><b>{s.n.toLocaleString()}</b>{s.note && <span className="muted"> · {s.note}</span>}</span>
                    </div>
                  ))}
                </div>
              ) : <div className="muted small">No dials in this range yet.</div>}
              <p className="muted small" style={{ marginBottom: 0 }}>
                Picked up = Zoom says the call was answered (a person, voicemail or an auto-attendant), or the agent
                logged a live conversation. Conversations = the agent logged a live-person outcome. Handoffs = chance given / sale closed.
              </p>
            </div>

            <div className="sectionhead"><h3>By agent</h3><span className="muted small">per day against the daily targets</span></div>
            <div className="card">
              {data.by_agent.length ? (
                <div className="tablewrap"><table className="data">
                  <thead><tr><th>Agent</th>{COUNT_HEADS}<th className="num">Dials / day</th><th className="num">Conv. / day</th><th className="num">Handoffs / day</th></tr></thead>
                  <tbody>
                    {data.by_agent.map((a) => (
                      <tr key={a.agent_id}>
                        <td>{a.name}</td>
                        <CountCells r={a} />
                        <td className="num">{perDay(a.dials, a.days)}{targets.dials ? <span className="muted"> / {targets.dials}</span> : null}</td>
                        <td className="num">{perDay(a.conversations, a.days)}{targets.connects ? <span className="muted"> / {targets.connects}</span> : null}</td>
                        <td className="num">{perDay(a.handoffs, a.days)}{targets.handoffs ? <span className="muted"> / {targets.handoffs}</span> : null}</td>
                      </tr>
                    ))}
                  </tbody>
                </table></div>
              ) : <span className="muted small">No dials in this range yet.</span>}
            </div>

            <div className="sectionhead"><h3>Where the dials came from</h3></div>
            <div className="card">
              {data.by_source.length ? (
                <div className="tablewrap"><table className="data">
                  <thead><tr><th>Source</th>{COUNT_HEADS}</tr></thead>
                  <tbody>
                    {data.by_source.map((s, i) => (
                      <tr key={i}>
                        <td>{SOURCE_LABEL[s.source] ?? s.source}{s.list ? `: ${s.list}` : ''}</td>
                        <CountCells r={s} />
                      </tr>
                    ))}
                  </tbody>
                </table></div>
              ) : <span className="muted small">No dials in this range yet.</span>}
            </div>

            <div className="sectionhead"><h3>By intent</h3><span className="muted small">a lead with several intents counts under each</span></div>
            <div className="card">
              {data.by_intent.length ? (
                <div className="tablewrap"><table className="data">
                  <thead><tr><th>Intent</th>{COUNT_HEADS}</tr></thead>
                  <tbody>
                    {data.by_intent.map((s) => (
                      <tr key={s.intent}><td>{s.label}</td><CountCells r={s} /></tr>
                    ))}
                  </tbody>
                </table></div>
              ) : <span className="muted small">No dials in this range yet.</span>}
            </div>

            <div className="sectionhead"><h3>By hour</h3><span className="muted small">the lead's own local time</span></div>
            <div className="card">
              {data.by_hour.length ? (
                <div className="tablewrap"><table className="data">
                  <thead><tr><th>Hour</th><th className="barcol">Dials</th><th className="num">Picked up</th><th className="num">Conversations</th><th className="num">Conv. rate</th><th className="num">Handoffs</th></tr></thead>
                  <tbody>
                    {data.by_hour.map((h) => (
                      <tr key={h.hour}>
                        <td>{hourLabel(h.hour)}</td>
                        <td className="barcol">
                          <span className="barcell">
                            <span className="minibar"><i style={{ width: `${(100 * h.dials) / maxHour}%` }} /></span>
                            <span className="n">{h.dials}</span>
                          </span>
                        </td>
                        <td className="num">{h.answered}</td>
                        <td className="num">{h.conversations}</td>
                        <td className="num">{pct(h.conversations, h.dials)}</td>
                        <td className="num">{h.handoffs}</td>
                      </tr>
                    ))}
                  </tbody>
                </table></div>
              ) : <span className="muted small">No dials in this range yet.</span>}
            </div>
          </>
        )}
      </div>

      <div className="sectionhead"><h3>Daily targets</h3><span className="muted small">per agent, per day — shown on the floor board, the Dial page and above</span></div>
      <div className="card">
        <div className="formrow">
          <label>Dials<input type="number" style={{ width: 110 }} min={0} value={draft.dials} onChange={(e) => setDraft({ ...draft, dials: e.target.value })} /></label>
          <label>Conversations<input type="number" style={{ width: 110 }} min={0} value={draft.connects} onChange={(e) => setDraft({ ...draft, connects: e.target.value })} /></label>
          <label>Handoffs<input type="number" style={{ width: 110 }} min={0} value={draft.handoffs} onChange={(e) => setDraft({ ...draft, handoffs: e.target.value })} /></label>
          <label>Shift (hours)<input type="number" style={{ width: 90 }} min={1} max={16} value={pacing.shift} onChange={(e) => setPacing({ ...pacing, shift: e.target.value })} /></label>
          <label>Wrap-up (seconds)<input type="number" style={{ width: 100 }} min={0} max={300} value={pacing.wrap} onChange={(e) => setPacing({ ...pacing, wrap: e.target.value })} /></label>
          <button className="btn primary" onClick={saveTargets}>Save targets</button>
          {saved && <span className="muted small">{saved}</span>}
        </div>
        <p className="muted small" style={{ marginBottom: 0 }}>
          Pace on the Dial page and the floor board spreads the dial target over the shift ({Math.round((Number(draft.dials) || 0) / Math.max(1, Number(pacing.shift) || 8))} an hour).
          The wrap-up is a countdown after each logged call: it never dials by itself; 0 turns it off.
        </p>
      </div>

      <BestTimePanel />
    </div>
  )
}
