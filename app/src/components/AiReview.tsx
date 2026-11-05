import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { lift, reasonText, teachableTraits, traitsText } from '../lib/ai'
import { dispositionLabel } from '../lib/types'
import type { AiReviewData, AiReviewRow } from '../lib/types'
import { MarkControl } from './AiControls'
import type { LessonSeed } from './AiLessonEditor'
import LoadError from './LoadError'

const when = (s: string) => new Date(s).toLocaleDateString([], { month: 'short', day: 'numeric' })

/** 0044: the AI page's "Where it went wrong" tab: wins it rated low, hard noes
 *  it rated high, and how its scores held up, each mistake one click from a
 *  verdict or a lesson. */
export default function AiReview({ changed, openEditor, version }: {
  changed: (m: string) => void; openEditor: (seed: LessonSeed) => void; version: number
}) {
  const [days, setDays] = useState(30)
  const [r, setR] = useState<AiReviewData | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('ai_review', { p_days: days })
    if (error) { setErr(error.message); return }
    setErr(null)
    setR(data as AiReviewData)
  }, [days])
  useEffect(() => { load() }, [load, version])

  if (err) return <LoadError what="the review" error={err} onRetry={load} />
  if (!r) return <div className="emptystate">Loading where it went wrong…</div>

  const under = r.rows.filter((x) => x.kind === 'underrated')
  const over = r.rows.filter((x) => x.kind === 'overrated')

  function table(rows: AiReviewRow[], kind: 'underrated' | 'overrated') {
    return (
      <div className="tablewrap">
        <table className="data">
          <thead><tr><th>Lead</th><th>Traits</th><th>It rated</th><th>What happened</th><th>Why it said so</th><th>Teach it</th></tr></thead>
          <tbody>
            {rows.map((x) => (
              <tr key={`${x.kind}${x.lead_id}`}>
                <td>{x.name}<div className="muted small">{[x.city, x.state].filter(Boolean).join(', ')}</div></td>
                <td className="small">{traitsText(teachableTraits(x.traits))}</td>
                <td className={`lift ${kind === 'underrated' ? 'down' : 'up'}`}>
                  {lift(x.win_x)}<div className="muted small" style={{ fontWeight: 400 }}>{x.at_dial ? 'when dialed' : 'its latest score'}</div>
                </td>
                <td className="small">
                  <b>{dispositionLabel(x.outcome)}</b>
                  <div className="muted">{when(x.at)}{x.agent ? ` · ${x.agent}` : ''}</div>
                </td>
                <td className="small why">{x.reasons.length ? x.reasons.map(reasonText).join('; ') : <span className="muted">near average on every trait</span>}</td>
                <td className="small teachcell">
                  <button className="btn ghost small" onClick={() => openEditor({
                    conditions: teachableTraits(x.traits), win: kind === 'underrated' ? 1.5 : 0.67, source: 'review',
                  })}>teach from this</button>
                  <MarkControl leadId={x.lead_id} mark={x.mark} won={kind === 'underrated'} onDone={changed} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    )
  }

  return (
    <div className="aireview">
      <div className="sectionhead">
        <h3>Where it went wrong</h3>
        <span className="muted small">
          wins it rated at or below the floor's average, and hard noes on leads it rated twice the average or more
        </span>
        <div className="rangebar" role="tablist" aria-label="Look back" style={{ margin: '0 0 0 auto' }}>
          {[30, 60, 90].map((n) => (
            <button key={n} role="tab" aria-selected={days === n} className={`rangebtn ${days === n ? 'active' : ''}`} onClick={() => setDays(n)}>{n} days</button>
          ))}
        </div>
      </div>
      <p className="muted small" style={{ marginTop: 0 }}>
        For each one, tell it why: <b>teach from this</b> opens a lesson with the lead's traits filled in (keep the ones that matter),
        or give the lead your word. Gemini also reads these misses, by traits only, before every analysis and reply.
      </p>

      <div className="card">
        <div className="kpilabel">How its scores held up</div>
        {r.calibration.length ? (
          <>
            <div className="tablewrap">
              <table className="data">
                <thead><tr><th>It rated the lead</th><th>Dials</th><th>Wins it expected</th><th>Wins</th></tr></thead>
                <tbody>
                  {r.calibration.map((b) => (
                    <tr key={b.band}>
                      <td>{b.band}</td>
                      <td>{b.dials.toLocaleString()}</td>
                      <td>{b.expected.toLocaleString()}</td>
                      <td className={b.wins > b.expected * 1.5 && b.wins >= 2 ? 'lift up' : b.wins < b.expected / 1.5 && b.expected >= 2 ? 'lift down' : ''}>{b.wins}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="muted small" style={{ marginBottom: 0 }}>
              Dials scored before they happened{r.stamped_since ? `, since ${when(r.stamped_since)}` : ''}. Good scores put more wins in the top rows
              and about as many wins as expected in each; wins are rare, so read a row on a handful of dials as a hint.
            </p>
          </>
        ) : (
          <p className="muted small" style={{ margin: 0 }}>
            From now on every dial keeps the score its lead had when it was dialed; this fills in as calls are made.
          </p>
        )}
      </div>

      <div className="sectionhead"><h3>Wins it rated low</h3><span className="muted small">{under.length} in the last {r.days} days</span></div>
      <div className="card">
        {under.length ? table(under, 'underrated') : <p className="muted small" style={{ margin: 0 }}>None: every win in the last {r.days} days was on a lead it rated above average.</p>}
      </div>

      <div className="sectionhead"><h3>Hard noes it rated high</h3><span className="muted small">{over.length} in the last {r.days} days: not interested (hard), has a provider, do not call</span></div>
      <div className="card">
        {over.length ? table(over, 'overrated') : <p className="muted small" style={{ margin: 0 }}>None in the last {r.days} days.</p>}
      </div>
      <p className="muted small">
        A score from before dials kept their own is the lead's latest one, which for a lead already won is the one it had when it was handed off.
      </p>
    </div>
  )
}
