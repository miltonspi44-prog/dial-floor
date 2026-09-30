import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { dispositionLabel, talkTime } from '../lib/types'
import type { Leaderboard, Sprint } from '../lib/types'
import SprintBanner from './SprintBanner'

/** E5: activity only (dials and conversations), streaks at the daily target,
 *  the call of the day, and the power hour a manager can start. */
export default function LeaderboardCard({ today, sprint, me, isManager, onChanged }: {
  today: Leaderboard | null
  sprint: Sprint | null
  me: string
  isManager: boolean
  onChanged: () => void
}) {
  const [period, setPeriod] = useState<'today' | 'week'>('today')
  const [week, setWeek] = useState<Leaderboard | null>(null)
  const [form, setForm] = useState({ name: 'Power hour', metric: 'conversations', minutes: '60', goal: '' })
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (period !== 'week') return
    let live = true
    supabase.rpc('leaderboard', { p_period: 'week' }).then(({ data }) => { if (live && data) setWeek(data as Leaderboard) })
    return () => { live = false }
  }, [period, today])

  async function start() {
    setBusy(true)
    const { error } = await supabase.rpc('start_sprint', {
      p_name: form.name, p_metric: form.metric, p_minutes: Number(form.minutes) || 60,
      p_goal: form.goal.trim() ? Number(form.goal) : null,
    })
    setBusy(false)
    setErr(error ? error.message : null)
    if (!error) onChanged()
  }

  async function end() {
    setBusy(true)
    const { error } = await supabase.rpc('end_sprint')
    setBusy(false)
    setErr(error ? error.message : null)
    if (!error) onChanged()
  }

  const lb = period === 'today' ? today : week
  const cotd = today?.call_of_the_day
  const maxConv = Math.max(1, ...(lb?.rows ?? []).map((r) => r.conversations))

  return (
    <>
      <div className="sectionhead">
        <h3>Leaderboard</h3>
        <span className="muted small">activity only: dials and conversations. Streak = working days in a row at the dial target</span>
        <div className="rangebar" style={{ margin: '0 0 0 auto' }}>
          {(['today', 'week'] as const).map((p) => (
            <button key={p} className={`rangebtn ${period === p ? 'active' : ''}`} onClick={() => setPeriod(p)}>{p === 'today' ? 'Today' : 'This week'}</button>
          ))}
        </div>
      </div>
      <div className="boardgrid">
        <div className={`card ${lb ? '' : 'stale'}`}>
          {lb?.rows.length ? (
            <table className="data">
              <thead><tr><th>#</th><th>Agent</th><th className="barcol">Conversations</th><th className="num">Dials</th><th className="num">Streak</th></tr></thead>
              <tbody>
                {lb.rows.map((r, i) => (
                  <tr key={r.agent_id} className={r.agent_id === me ? 'me' : ''}>
                    <td className="muted">{i + 1}</td>
                    <td>{r.name}{r.agent_id === me ? <span className="muted"> (you)</span> : null}</td>
                    <td className="barcol">
                      <span className="barcell">
                        <span className="minibar"><i style={{ width: `${(100 * r.conversations) / maxConv}%` }} /></span>
                        <span className="n">{r.conversations}</span>
                      </span>
                    </td>
                    <td className="num">{r.dials}</td>
                    <td className="num">{r.streak ? `${r.streak} day${r.streak === 1 ? '' : 's'}` : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : <span className="muted small">{lb ? 'No agents on the floor yet.' : 'Loading…'}</span>}
          <p className="small" style={{ marginBottom: 0 }}>
            {cotd
              ? <>Call of the day: <b>{cotd.agent}</b> with {cotd.lead} ({dispositionLabel(cotd.disposition)}{cotd.duration ? `, ${talkTime(cotd.duration)}` : ''}), {cotd.votes} vote{cotd.votes === 1 ? '' : 's'}</>
              : <span className="muted">Call of the day: vote for a teammate's conversation in Recent calls below (one vote a day).</span>}
          </p>
        </div>

        <div>
          {sprint && <SprintBanner sprint={sprint} me={me} />}
          {isManager && (
            <div className="card sprintform">
              {sprint?.running ? (
                <div className="actionrow">
                  <span className="small">A race is on until {new Date(sprint.ends_at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}.</span>
                  <button className="btn small" onClick={end} disabled={busy}>End it now</button>
                </div>
              ) : (
                <>
                  <div className="kpilabel" style={{ marginBottom: 6 }}>Start a power hour</div>
                  <div className="formrow">
                    <label>Name<input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} style={{ width: 150 }} /></label>
                    <label>Race on
                      <select value={form.metric} onChange={(e) => setForm({ ...form, metric: e.target.value })}>
                        <option value="conversations">Conversations</option>
                        <option value="dials">Dials</option>
                      </select>
                    </label>
                    <label>Minutes<input type="number" min={5} max={240} value={form.minutes} onChange={(e) => setForm({ ...form, minutes: e.target.value })} style={{ width: 80 }} /></label>
                    <label>First to (optional)<input type="number" min={1} value={form.goal} onChange={(e) => setForm({ ...form, goal: e.target.value })} style={{ width: 90 }} placeholder="—" /></label>
                    <button className="btn primary" onClick={start} disabled={busy}>Start</button>
                  </div>
                  <p className="muted small" style={{ marginBottom: 0 }}>Everyone sees the race here and on their Dial page. Without a goal, the most by the end wins.</p>
                </>
              )}
              {err && <div className="warnline">{err}</div>}
            </div>
          )}
          {!sprint && !isManager && <div className="card muted small">No power hour running. Your manager starts them.</div>}
        </div>
      </div>
    </>
  )
}
