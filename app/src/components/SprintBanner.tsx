import { useEffect, useState } from 'react'
import type { Sprint } from '../lib/types'

function minutesLeft(ends: string, now: number): string {
  const m = Math.max(0, Math.ceil((Date.parse(ends) - now) / 60000))
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m left` : `${m} min left`
}

/** E5: the power hour — a race on dials or conversations, never on outcomes.
 *  Compact on the Dial page (the standings in a line, gone 15 minutes after the
 *  finish); in full on the floor board. */
export default function SprintBanner({ sprint, me, compact = false }: { sprint: Sprint; me: string | null; compact?: boolean }) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = window.setInterval(() => setNow(Date.now()), 15_000)
    return () => window.clearInterval(iv)
  }, [])

  if (compact && !sprint.running && now - Date.parse(sprint.ends_at) > 15 * 60_000) return null
  const unit = sprint.metric === 'dials' ? 'dials' : 'conversations'
  const race = sprint.goal ? `first to ${sprint.goal} ${unit}` : `most ${unit}`
  const status = sprint.running ? minutesLeft(sprint.ends_at, now) : 'finished'
  const tie = !sprint.winner && (sprint.winners?.length ?? 0) > 1 ? sprint.winners! : null
  const winner = tie
    ? `Dead heat — ${tie.map((r) => (r.agent_id === me ? 'you' : r.name)).join(' & ')} with ${tie[0].count}`
    : sprint.winner
    ? `${sprint.winner.agent_id === me ? 'You' : sprint.winner.name} ${sprint.running ? 'got there first' : 'won'} with ${sprint.winner.count}`
    : sprint.running ? null : 'nobody scored'
  const lead = Math.max(1, ...sprint.rows.map((r) => r.count))

  if (compact) {
    const shown = sprint.rows.filter((r) => r.count > 0 || r.agent_id === me).slice(0, 4)
    return (
      <div className="sprintbar">
        <b>{sprint.name}</b> · {race} · {status}
        {winner && <span className="sprintwin"> · {winner}</span>}
        {shown.length > 0 && (
          <span className="muted">
            {' · '}{shown.map((r) => `${r.agent_id === me ? 'You' : r.name} ${r.count}`).join(' · ')}
          </span>
        )}
      </div>
    )
  }

  return (
    <div className={`card sprintcard ${sprint.running ? 'live' : ''}`}>
      <div className="sectionhead" style={{ margin: '0 0 8px' }}>
        <h3>{sprint.name}</h3>
        <span className="muted small">{race} · {status}</span>
        {winner && <span className="sprintwin small">{winner}</span>}
      </div>
      <table className="data">
        <tbody>
          {sprint.rows.map((r) => (
            <tr key={r.agent_id}>
              <td style={{ width: '28%' }}>{r.name}{r.agent_id === me ? <span className="muted"> (you)</span> : null}</td>
              <td className="barcol">
                <span className="barcell">
                  <span className="minibar"><i style={{ width: `${Math.min(100, (100 * r.count) / (sprint.goal ?? lead))}%` }} /></span>
                  <span className="n">{r.count}{sprint.goal ? <span className="muted">/{sprint.goal}</span> : null}</span>
                </span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
