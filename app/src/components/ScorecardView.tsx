import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { dispositionLabel, talkTime } from '../lib/types'
import type { Scorecard, WeekCounts } from '../lib/types'

type Floor = WeekCounts & { agents: number }
interface Metric {
  label: string
  me: (w: WeekCounts) => number | null
  floor: (f: Floor) => number | null
  fmt: (v: number) => string
}

const ratio = (a: number, b: number) => (b ? a / b : null)
const pct = (v: number) => `${Math.round(v * 100)}%`
const whole = (v: number) => String(Math.round(v))
const oneDp = (v: number) => (Number.isInteger(v) ? String(v) : v.toFixed(1))
function hours(sec: number): string {
  const h = Math.floor(sec / 3600)
  const m = Math.round((sec % 3600) / 60)
  return h ? `${h}h ${m}m` : `${m}m`
}

/** The rows: the agent's week, and the floor's (per agent for counts, pooled for rates). */
const METRICS: Metric[] = [
  { label: 'Dials', me: (w) => w.dials, floor: (f) => ratio(f.dials, f.agents), fmt: whole },
  { label: 'Dials per day on the floor', me: (w) => ratio(w.dials, w.days), floor: (f) => ratio(f.dials, f.days), fmt: whole },
  { label: 'Picked up', me: (w) => ratio(w.picked_up, w.dials), floor: (f) => ratio(f.picked_up, f.dials), fmt: pct },
  { label: 'Conversations', me: (w) => w.conversations, floor: (f) => ratio(f.conversations, f.agents), fmt: whole },
  { label: 'Dials that reach a person', me: (w) => ratio(w.conversations, w.dials), floor: (f) => ratio(f.conversations, f.dials), fmt: pct },
  { label: 'Conversations kept alive', me: (w) => ratio(w.kept, w.conversations), floor: (f) => ratio(f.kept, f.conversations), fmt: pct },
  { label: 'Handoffs', me: (w) => w.won, floor: (f) => ratio(f.won, f.agents), fmt: oneDp },
  { label: 'Talk time', me: (w) => w.talk_seconds, floor: (f) => ratio(f.talk_seconds, f.agents), fmt: hours },
  { label: 'Callbacks kept', me: (w) => ratio(w.cb_done, w.cb_done + w.cb_missed), floor: (f) => ratio(f.cb_done, f.cb_done + f.cb_missed), fmt: pct },
]

/** Four weeks as a thin line: the shape, not the scale (the numbers sit beside it). */
function Spark({ values }: { values: (number | null)[] }) {
  const pts = values.map((v, i) => (v == null ? null : { i, v })).filter(Boolean) as { i: number; v: number }[]
  if (!pts.length) return null
  const max = Math.max(...pts.map((p) => p.v))
  const min = Math.min(...pts.map((p) => p.v))
  const w = 72, h = 20, pad = 3
  const x = (i: number) => pad + (i * (w - 2 * pad)) / Math.max(1, values.length - 1)
  const y = (v: number) => (max === min ? h / 2 : h - pad - ((v - min) * (h - 2 * pad)) / (max - min))
  const last = pts[pts.length - 1]
  return (
    <svg className="spark" width={w} height={h} viewBox={`0 0 ${w} ${h}`} aria-hidden="true">
      {pts.length > 1 && <polyline points={pts.map((p) => `${x(p.i)},${y(p.v)}`).join(' ')} />}
      <circle cx={x(last.i)} cy={y(last.v)} r={2.5} />
    </svg>
  )
}

function weekLabel(iso: string, thisWeek: string): string {
  if (iso === thisWeek) return 'This week'
  return new Date(`${iso}T12:00:00`).toLocaleDateString([], { month: 'short', day: 'numeric' })
}

/** E6: the weekly scorecard, for a 15-minute review with receipts. */
export default function ScorecardView({ agent }: { agent: string }) {
  const [sc, setSc] = useState<Scorecard | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [key, setKey] = useState('')

  useEffect(() => {
    let live = true
    supabase.rpc('scorecard', { p_agent: agent, p_weeks: 4 }).then(({ data, error: e }) => {
      if (!live) return
      if (e) { setError(e.message); setSc(null) } else { setError(null); setSc(data as Scorecard) }
      setKey(agent)
    })
    return () => { live = false }
  }, [agent])

  if (error) return <div className="card alertcard">{error}</div>
  if (!sc) return <div className="emptystate">Loading the scorecard…</div>
  const cur = sc.weeks[sc.weeks.length - 1]

  return (
    <div className={`scorecard ${key !== agent ? 'stale' : ''}`} data-print-root="scorecard">
      <div className="sectionhead">
        <h3>{sc.agent?.name ?? 'Scorecard'} · week of {new Date(`${sc.this_week}T12:00:00`).toLocaleDateString([], { month: 'long', day: 'numeric' })}</h3>
        <span className="muted small">the floor = the average agent who dialed that week; rates are the floor's overall</span>
        <button className="btn small noprint" style={{ marginLeft: 'auto' }} onClick={() => {
          document.body.classList.add('print-scorecard')
          window.print()
          document.body.classList.remove('print-scorecard')
        }}>Print</button>
      </div>
      <div className="card">
        <div className="tablewrap">
          <table className="data scoretable">
            <thead>
              <tr>
                <th>Metric</th>
                {sc.weeks.map((w) => <th key={w.week} className="num">{weekLabel(w.week, sc.this_week)}</th>)}
                <th className="num">Floor this week</th>
                <th>Trend</th>
              </tr>
            </thead>
            <tbody>
              {METRICS.map((m) => {
                const vals = sc.weeks.map((w) => (w.me.dials || m.label === 'Callbacks kept' ? m.me(w.me) : null))
                const fl = cur.floor.agents ? m.floor(cur.floor) : null
                return (
                  <tr key={m.label}>
                    <td>{m.label}</td>
                    {vals.map((v, i) => (
                      <td key={i} className={`num ${i === vals.length - 1 ? 'cur' : ''}`}>{v == null ? <span className="muted">—</span> : m.fmt(v)}</td>
                    ))}
                    <td className="num muted">{fl == null ? '—' : m.fmt(fl)}</td>
                    <td><Spark values={vals} /></td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </div>

      <div className="digestgrid">
        <div className="card">
          <h4 className="cardhead">Handoffs this week</h4>
          {sc.handoffs.length ? (
            <ul className="receipts">
              {sc.handoffs.map((h, i) => (
                <li key={i}>
                  <b>{h.lead}</b> <span className="muted small">
                    {dispositionLabel(h.kind)} · {new Date(h.at).toLocaleDateString([], { weekday: 'short' })}
                    {h.rating ? ` · rated ${h.rating}/5` : ''}{h.outcome ? ` · ${h.outcome === 'closed' ? 'closed' : 'did not close'}` : ''}
                  </span>
                  {h.summary && <div className="small">{h.summary}</div>}
                </li>
              ))}
            </ul>
          ) : <p className="muted small">None yet this week.</p>}
        </div>
        <div className="card">
          <h4 className="cardhead">Worth talking through</h4>
          {sc.review.length ? (
            <ul className="receipts">
              {sc.review.map((r) => (
                <li key={r.attempt_id}>
                  <b>{r.lead}</b> <span className="muted small">{talkTime(r.duration)} · ended {dispositionLabel(r.disposition).toLowerCase()} · {new Date(r.at).toLocaleDateString([], { weekday: 'short' })}</span>
                  {r.objections.length > 0 && <div className="small">heard: {r.objections.join(', ')}</div>}
                  {r.note && <div className="small muted">{r.note}</div>}
                </li>
              ))}
            </ul>
          ) : <p className="muted small">No long conversation ended in a no this week.</p>}
          <p className="muted small" style={{ marginBottom: 0 }}>The longest conversations that still ended in a no: they had the owner's ear. What lost it?</p>
        </div>
      </div>
      {sc.saved.length > 0 && (
        <div className="card">
          <h4 className="cardhead">Saved to the library this week</h4>
          <ul className="receipts">
            {sc.saved.map((s) => <li key={s.id}>{s.title} <span className="muted small">· {s.scenario}</span></li>)}
          </ul>
        </div>
      )}
      <p className="muted small">No QA scores or call clips: there are no recordings, by design.</p>
    </div>
  )
}
