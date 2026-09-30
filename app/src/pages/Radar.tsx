import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { RadarData } from '../lib/types'

function trade(key: string): string {
  return key.replace(/_/g, ' ')
}

function when(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
}

/** C3 + C4: the morning brief. Honest rules over real data: nothing here is a guess. */
export default function Radar() {
  const [data, setData] = useState<RadarData | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [perAgent, setPerAgent] = useState('')
  const [busy, setBusy] = useState(false)
  const [toast, setToast] = useState<string | null>(null)

  function say(msg: string) {
    setToast(msg)
    window.setTimeout(() => setToast(null), 3000)
  }

  const load = useCallback(() => {
    supabase.rpc('radar').then(({ data: d, error: e }) => {
      if (e) { setError(e.message); return }
      setError(null)
      const r = d as RadarData
      setData(r)
      setPerAgent(String(r.per_agent))
    })
  }, [])

  // the day's run happens on the first Dial or Radar page of the business day
  useEffect(() => {
    supabase.rpc('radar_daily').then(() => load())
  }, [load])

  async function build(name: string, rules: Record<string, unknown>) {
    setBusy(true)
    const { data: r, error: e } = await supabase.rpc('build_list', { p_name: name, p_agent: null, p_rules: rules, p_limit: 300 })
    setBusy(false)
    if (e) { say(e.message); return }
    const n = (r as { count: number }).count
    say(n ? `“${name}” built with ${n} leads: shared by everyone, assign it on the Lists tab` : 'No eligible leads right now (all waiting on lists, resting, or dialed)')
    load()
  }

  async function saveSize() {
    const n = Math.max(0, Math.min(1000, Math.round(Number(perAgent))))
    if (!Number.isFinite(n)) return
    const { error: e } = await supabase.from('app_settings').update({ value: n, updated_at: new Date().toISOString() }).eq('key', 'radar_deal_per_agent')
    if (e) { say(e.message); return }
    say(n ? `Each agent gets ${n} leads a morning` : 'Morning radar lists are off')
    load()
  }

  async function dealNow() {
    setBusy(true)
    const { data: r, error: e } = await supabase.rpc('radar_deal_now')
    setBusy(false)
    if (e) { say(e.message); return }
    const dealt = (r as { dealt: unknown[] }).dealt.length
    say(dealt ? `Dealt ${dealt} radar list${dealt === 1 ? '' : 's'}` : 'Every active agent already has today’s radar list')
    load()
  }

  if (error) return <div className="page"><div className="card alertcard">{error}</div></div>
  if (!data) return <div className="page"><div className="emptystate">Loading the radar…</div></div>

  const today = new Date(`${data.date}T12:00:00`).toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })
  const open = data.seasons.filter((s) => s.open)
  const soon = data.seasons.filter((s) => s.opens_next_month)
  // list names carry the business day, not the browser's date
  const stamp = new Date(`${data.date}T12:00:00`).toLocaleDateString([], { month: 'short', day: 'numeric' })

  return (
    <div className="page">
      <div className="sectionhead">
        <h3>Radar · {today}</h3>
        <span className="muted small">
          {data.last_run?.date === data.date
            ? `ranked and dealt at ${when(data.last_run.at)}`
            : 'runs with the first Dial page of the day'}
        </span>
      </div>

      <div className="radargrid">
        <div className="card radarcard">
          <div className="kpilabel">Callbacks due today</div>
          <div className="kpivalue">{data.callbacks.due_today}</div>
          <div className="kpisub">
            {data.callbacks.overdue ? <span className="warnline">{data.callbacks.overdue} overdue · </span> : null}
            {data.callbacks.by_agent.map((a) => `${a.name} ${a.due}`).join(' · ') || 'none waiting'}
          </div>
        </div>

        <div className="card radarcard">
          <div className="kpilabel">Never answer their phone</div>
          <div className="kpivalue">{data.never_answers.total}</div>
          <div className="kpisub">
            {data.never_answers.new_this_week} crossed {data.threshold} unanswered tries in business hours this week ·{' '}
            {data.never_answers.dialable} dialable now. They miss their customers’ calls too: the AI-receptionist list.
          </div>
          {data.never_answers.dialable > 0 && (
            <button className="btn" disabled={busy} onClick={() => build(`AI receptionist · never answers · ${stamp}`, { intent: 'never_answers' })}>
              Build the AI-receptionist list
            </button>
          )}
        </div>

        <div className="card radarcard">
          <div className="kpilabel">New this week, no website</div>
          {data.fresh_no_site.length ? (
            <ul className="radarlist">
              {data.fresh_no_site.map((c) => (
                <li key={`${c.category_key}-${c.city}-${c.state}`}>
                  <span><b>{c.count}</b> new no-website {trade(c.category_key)} in {c.city}, {c.state}</span>
                  <button className="btn ghost small" disabled={busy}
                    onClick={() => build(`New no-site ${trade(c.category_key)} · ${c.city} · ${stamp}`,
                      { category: c.category_key, city: c.city, state: c.state, website_type: 'none', fresh_days: 7 })}>
                    build list
                  </button>
                </li>
              ))}
            </ul>
          ) : <div className="kpisub">No clusters yet: 3+ new no-website businesses in one trade and city.</div>}
        </div>

        <div className="card radarcard">
          <div className="kpilabel">Seasons</div>
          {open.length || soon.length ? (
            <ul className="radarlist">
              {open.map((s) => (
                <li key={s.label}>
                  <span><b>{s.label}</b>: in season · {s.dialable} dialable{s.resting ? `, ${s.resting} resting` : ''}</span>
                  {s.dialable > 0 && (
                    <button className="btn ghost small" disabled={busy}
                      onClick={() => build(`${s.label} · ${stamp}`, { category: s.keys.join(','), intent: 'seasonal_window' })}>
                      build list
                    </button>
                  )}
                </li>
              ))}
              {soon.map((s) => (
                <li key={s.label}><span><b>{s.label}</b>: opens next month · {s.dialable} dialable{s.resting ? `, ${s.resting} resting` : ''}</span></li>
              ))}
            </ul>
          ) : <div className="kpisub">No season open or opening next month.</div>}
        </div>

        <div className="card radarcard">
          <div className="kpilabel">Connecting above average (30 days)</div>
          {data.converting.length ? (
            <ul className="radarlist">
              {data.converting.map((c) => (
                <li key={`${c.kind}-${c.label}`}>
                  <span><b>{c.kind === 'trade' ? trade(c.label) : c.label}</b>: {c.rate}% of {c.dials} dials reach a conversation vs {c.floor}% overall</span>
                </li>
              ))}
            </ul>
          ) : <div className="kpisub">Nothing stands out yet: needs 20+ dials and 1.5× the floor’s rate. The morning ranking already weights what connects.</div>}
        </div>
      </div>

      <div className="sectionhead">
        <h3>Today’s radar lists</h3>
        <span className="muted small">every active agent gets their best leads each morning, dealt round-robin down the ranking</span>
      </div>
      <div className="card">
        {data.lists.length ? (
          <div className="tablewrap">
            <table className="data">
              <thead><tr><th>Agent</th><th>List</th><th className="barcol">Worked</th></tr></thead>
              <tbody>
                {data.lists.map((l) => (
                  <tr key={l.list_id}>
                    <td>{l.agent ?? '—'}</td>
                    <td>{l.name}{l.status !== 'active' && <span className="tag off" style={{ marginLeft: 8 }}>{l.status}</span>}</td>
                    <td className="barcol">
                      <span className="barcell">
                        <span className="minibar"><i style={{ width: `${l.total ? (100 * l.served) / l.total : 0}%` }} /></span>
                        <span className="n">{l.served}/{l.total}</span>
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <span className="muted small">{data.per_agent ? 'None dealt yet today (no active agents, or the day’s run hasn’t happened).' : 'Morning radar lists are off.'}</span>}
        <div className="formrow" style={{ marginTop: 12 }}>
          <label>Leads per agent each morning (0 = off)
            <input type="number" min={0} max={1000} style={{ width: 110 }} value={perAgent} onChange={(e) => setPerAgent(e.target.value)} />
          </label>
          <button className="btn" onClick={saveSize} disabled={String(data.per_agent) === perAgent}>Save</button>
          <button className="btn" onClick={dealNow} disabled={busy || !data.per_agent} title="Deals to active agents who don’t have today’s list yet">Deal now</button>
          <Link to="/lists" className="small">all lists</Link>
        </div>
      </div>
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
