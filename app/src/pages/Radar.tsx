import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { RadarData } from '../lib/types'
import RecyclePanel from '../components/RecyclePanel'

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
    say(n ? `Each proposed radar list holds ${n} leads` : 'Radar lists are off')
    load()
  }

  // 0037: the radar proposes, a manager approves. "Propose now" is the morning run's
  // dealing step on demand: a list closes when it is dialed through, and every
  // agent with none waiting and none being dialed is proposed a fresh one.
  async function proposeNow() {
    setBusy(true)
    const { data: r, error: e } = await supabase.rpc('radar_deal_now')
    setBusy(false)
    if (e) { say(e.message); return }
    const out = r as { dealt: unknown[]; closed: number }
    const n = out.dealt.length
    say(n ? `Proposed ${n} radar list${n === 1 ? '' : 's'}: approve ${n === 1 ? 'it' : 'them'} below`
      : out.closed ? `Closed ${out.closed} list${out.closed === 1 ? '' : 's'} dialed through; nobody is free for a new one yet`
        : 'Nobody is free for a new list: every active agent has one waiting for approval or still being dialed')
    load()
  }

  async function approve(l: RadarData['lists'][number]) {
    const who = l.agent ?? 'everyone'
    if (!window.confirm(`Approve “${l.name}” for ${who}? ${who} is served its ${l.total} leads ahead of the general pool, and the radar proposes nothing more for them until it is dialed through.`)) return
    const { error: e } = await supabase.rpc('approve_list', { p_list: l.list_id })
    if (e) { say(e.message); return }
    say(`Approved: ${who} is served from “${l.name}” from their next lead on`)
    load()
  }

  async function discard(l: RadarData['lists'][number]) {
    if (!window.confirm(`Discard “${l.name}”? Nothing on it has been dialed. Its leads go back to the pool, and the radar proposes ${l.agent ?? 'a'} fresh list on its next run.`)) return
    const { error: e } = await supabase.from('lists').update({ status: 'archived' }).eq('id', l.list_id)
    if (e) { say(e.message); return }
    say(`Discarded “${l.name}”`)
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
            ? `ranked and proposed at ${when(data.last_run.at)}`
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
        <h3>Radar lists</h3>
        <span className="muted small">the radar proposes each free agent the leads they are likeliest to convert (see the AI tab); a manager approves the list, and nothing more is proposed for that agent until it is dialed through</span>
      </div>
      <div className="card">
        {data.lists.length ? (
          <div className="tablewrap">
            <table className="data">
              <thead><tr><th>Agent</th><th>List</th><th>Status</th><th className="barcol">Worked</th><th /></tr></thead>
              <tbody>
                {data.lists.map((l) => (
                  <tr key={l.list_id}>
                    <td>{l.agent ?? '— shared —'}</td>
                    <td>{l.name}</td>
                    <td>
                      {l.status === 'draft' ? <span className="tag">awaiting approval</span>
                        : l.status === 'active' ? <span className="small">{l.approved_by ? `approved by ${l.approved_by}` : 'approved'}{l.approved_at ? ` · ${new Date(l.approved_at).toLocaleDateString()}` : ''}</span>
                          : <span className="tag off">{l.status === 'done' ? 'closed' : l.status}</span>}
                    </td>
                    <td className="barcol">
                      <span className="barcell">
                        <span className="minibar"><i style={{ width: `${l.total ? (100 * l.served) / l.total : 0}%` }} /></span>
                        <span className="n">{l.served}/{l.total}{l.status === 'active' ? ` · ${l.left} left` : ''}</span>
                      </span>
                    </td>
                    <td className="rowactions">
                      {l.status === 'draft' && (
                        <>
                          <button className="btn small primary" disabled={busy} onClick={() => approve(l)}>Approve</button>
                          <button className="btn ghost small" disabled={busy} onClick={() => discard(l)}>discard</button>
                        </>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <span className="muted small">{data.per_agent ? 'Nothing in play: no proposal waiting and no list being dialed. The morning run proposes one for each free agent, or use Propose now.' : 'Radar lists are off.'}</span>}
        <div className="formrow" style={{ marginTop: 12 }}>
          <label>Leads per proposed list (0 = off)
            <input type="number" min={0} max={1000} style={{ width: 110 }} value={perAgent} onChange={(e) => setPerAgent(e.target.value)} />
          </label>
          <button className="btn" onClick={saveSize} disabled={String(data.per_agent) === perAgent}>Save</button>
          <button className="btn" onClick={proposeNow} disabled={busy || !data.per_agent} title="Closes lists dialed through, then proposes a list to every active agent with none waiting and none being dialed">Propose now</button>
          <Link to="/lists" className="small">all lists</Link>
        </div>
      </div>

      <RecyclePanel />
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
