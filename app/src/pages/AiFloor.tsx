import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase, fmtPhone } from '../lib/supabase'
import { hourLabel } from '../lib/types'
import type { AiFloorData, AiListIdea, AiReason, AiSegment } from '../lib/types'
import LoadError from '../components/LoadError'

/** "1.4×" — a smoothed rate against the floor's own. */
function lift(x: number | null | undefined): string {
  return x == null ? '—' : `${x >= 10 ? Math.round(x) : x.toFixed(x >= 2 ? 1 : 2)}×`
}
function tone(x: number | null | undefined): string {
  return x == null ? '' : x >= 1.15 ? 'up' : x <= 0.87 ? 'down' : ''
}
function pct(x: number | null | undefined, digits = 1): string {
  return x == null ? '—' : `${(x * 100).toFixed(digits)}%`
}
function word(s: string): string { return s.replace(/_/g, ' ') }

const KIND_LABEL: Record<string, string> = {
  trade: 'Trade', state: 'State', area: 'Area code', phone: 'Phone type', website: 'Website', source: 'Source',
  tier: 'Tier', reviews: 'Reviews', score: 'Scraper score',
}
const KINDS = ['trade', 'state', 'area', 'phone', 'website', 'source', 'tier', 'reviews', 'score']

function reasonText(r: AiReason): string {
  const what = r.kind === 'trade' ? word(r.value) : r.kind === 'area' ? `area ${r.value}`
    : r.kind === 'website' ? (r.value === 'none' ? 'no website' : `${r.value} website`)
      : r.kind === 'phone' ? `${r.value} phone` : r.kind === 'reviews' ? `${r.value} reviews`
        : r.kind === 'score' ? `score ${r.value}` : r.kind === 'tier' ? `tier ${r.value}` : r.value
  return `${what}: ${lift(r.win)} wins, ${lift(r.answer)} pickups`
}

function rulesText(rules: AiListIdea['rules']): string {
  return Object.entries(rules).map(([k, v]) => `${word(k)} ${k === 'category' ? word(String(v)) : v}`).join(' · ')
}

/** 0043: the AI floor — who answers, who converts, who should call them, and
 *  Gemini's reading of it all. */
export default function AiFloor() {
  const [d, setD] = useState<AiFloorData | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [kind, setKind] = useState('trade')
  const [busy, setBusy] = useState(false)
  const [waiting, setWaiting] = useState<number | null>(null) // the last attempt id when an analysis was asked for
  const [toast, setToast] = useState<string | null>(null)
  const poll = useRef<number | null>(null)

  function say(m: string) { setToast(m); window.setTimeout(() => setToast(null), 4000) }

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('ai_floor')
    if (error) { setErr(error.message); return null }
    setErr(null)
    setD(data as AiFloorData)
    return data as AiFloorData
  }, [])

  useEffect(() => { load() }, [load])
  useEffect(() => () => { if (poll.current) window.clearInterval(poll.current) }, [])

  async function ask() {
    setBusy(true)
    const before = d?.last_attempt?.id ?? 0
    const { data, error } = await supabase.rpc('ai_brief_request')
    setBusy(false)
    if (error) { say(error.message); return }
    const r = data as { ok: boolean; why?: string }
    if (!r.ok) { say(r.why ?? 'The analysis could not be asked for.'); return }
    setWaiting(before)
    let tries = 0
    if (poll.current) window.clearInterval(poll.current)
    poll.current = window.setInterval(async () => {
      tries++
      const fresh = await load()
      if ((fresh?.last_attempt?.id ?? 0) > before || tries > 36) {
        if (poll.current) window.clearInterval(poll.current)
        poll.current = null
        setWaiting(null)
        if (tries > 36) say('No analysis came back within three minutes. Check that floor-ai is deployed.')
      }
    }, 5000)
  }

  async function buildIdea(idea: AiListIdea) {
    setBusy(true)
    const { data, error } = await supabase.rpc('build_list', { p_name: idea.name, p_agent: null, p_rules: { ...idea.rules, ai_order: true }, p_limit: 200 })
    setBusy(false)
    if (error) { say(error.message); return }
    const n = (data as { count: number }).count
    say(n ? `“${idea.name}” built with ${n} leads, best first: shared, assign it on the Lists tab` : 'No eligible leads match that list right now.')
  }

  async function proposeNow() {
    setBusy(true)
    const { data, error } = await supabase.rpc('radar_deal_now')
    setBusy(false)
    if (error) { say(error.message); return }
    const r = data as { dealt: unknown[]; matched?: boolean }
    say(r.dealt.length
      ? `Proposed ${r.dealt.length} list${r.dealt.length === 1 ? '' : 's'}${r.matched ? ', matched to each agent' : ''}: approve them on the Leads tab`
      : 'Nobody is free for a new list: every agent has one waiting for approval or still being dialed.')
    load()
  }

  if (err) return <div className="page"><LoadError what="the AI floor" error={err} onRetry={load} /></div>
  if (!d) return <div className="page"><div className="emptystate">Loading the AI floor…</div></div>

  const m = d.model
  const brief = d.brief
  const failed = d.last_attempt && !d.last_attempt.ok && (!brief || d.last_attempt.id > brief.id) ? d.last_attempt : null
  const keyMissing = failed?.error?.includes('GEMINI_API_KEY')
  const segs: AiSegment[] = d.segments[kind] ?? []

  return (
    <div className="page aifloor">
      <div className="sectionhead">
        <h3>AI floor</h3>
        <span className="muted small">
          Learned from {m.dials?.toLocaleString() ?? 0} dials, {m.convos?.toLocaleString() ?? 0} conversations and {m.wins ?? 0} wins
          in the last {m.days ?? 90} days · {m.scored?.toLocaleString() ?? 0} leads scored
          {m.at ? ` at ${new Date(m.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}` : ''} · scores refresh hourly
        </span>
      </div>

      <div className="card aibrief">
        <div className="sectionhead" style={{ margin: '0 0 8px' }}>
          <h3>Gemini's analysis</h3>
          {brief && <span className="muted small">{new Date(brief.created_at).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' })} · {brief.model}</span>}
          <button className="btn small primary" style={{ marginLeft: 'auto' }} disabled={busy || waiting != null} onClick={ask}>
            {waiting != null ? 'Gemini is writing… (about a minute)' : 'Ask Gemini for a fresh analysis'}
          </button>
        </div>
        {failed && (
          <div className="warnline" role="alert">
            {keyMissing
              ? <>Gemini isn't connected yet: add your key as <b>GEMINI_API_KEY</b> in Supabase → Edge Functions → Secrets, then ask again. The scores, matching and tables below work without it.</>
              : <>The last analysis failed ({new Date(failed.created_at).toLocaleString([], { hour: 'numeric', minute: '2-digit' })}): {failed.error}</>}
          </div>
        )}
        {brief ? (
          <>
            <p className="aiheadline">{brief.brief.headline}</p>
            <p>{brief.brief.summary}</p>
            {brief.brief.findings.length > 0 && (
              <ul className="ailist">
                {brief.brief.findings.map((f, i) => <li key={i}><b>{f.title}</b> {f.detail} <span className="muted small">{f.evidence}</span></li>)}
              </ul>
            )}
            {brief.brief.where_to_call.length > 0 && (
              <>
                <div className="kpilabel" style={{ marginTop: 12 }}>Where and when to call</div>
                <ul className="ailist">
                  {brief.brief.where_to_call.map((w, i) => <li key={i}><b>{w.segment}</b>{w.when ? ` · ${w.when}` : ''} <span className="muted small">{w.why}</span></li>)}
                </ul>
              </>
            )}
            {brief.brief.agent_matching.length > 0 && (
              <>
                <div className="kpilabel" style={{ marginTop: 12 }}>Who should call what</div>
                <ul className="ailist">
                  {brief.brief.agent_matching.map((a, i) => <li key={i}><b>{a.agent}</b>: {a.focus} <span className="muted small">{a.why}</span></li>)}
                </ul>
              </>
            )}
            {brief.brief.lists.length > 0 && (
              <>
                <div className="kpilabel" style={{ marginTop: 12 }}>Lists worth building</div>
                <ul className="ailist">
                  {brief.brief.lists.map((l, i) => (
                    <li key={i}>
                      <b>{l.name}</b> <span className="muted small">{rulesText(l.rules)}</span>
                      <button className="btn ghost small" style={{ marginLeft: 8 }} disabled={busy} onClick={() => buildIdea(l)}>build it</button>
                      <div className="muted small">{l.why}</div>
                    </li>
                  ))}
                </ul>
              </>
            )}
            {brief.brief.cautions.length > 0 && <p className="muted small" style={{ marginBottom: 0 }}>Caution: {brief.brief.cautions.join(' · ')}</p>}
          </>
        ) : !failed && (
          <p className="muted small" style={{ margin: 0 }}>
            No analysis yet. Gemini writes one every morning at 12:35 UTC, before the radar proposes the day's lists, or whenever you ask.
          </p>
        )}
      </div>

      <div className="sectionhead">
        <h3>Who should call what</h3>
        <span className="muted small">
          {d.radar.matched
            ? 'The radar proposes each agent the leads they are likeliest to convert: the lead\'s chance of a win × the agent\'s record with that trade and state.'
            : 'Matching is off (Settings → AI): the radar proposes lists round-robin.'}
        </span>
      </div>
      <div className="card">
        <div className="tablewrap">
          <table className="data">
            <thead><tr><th>Agent</th><th>Conversations</th><th>Wins</th><th>Kept alive</th><th>Record vs floor</th><th>Strongest with</th><th>Weakest with</th></tr></thead>
            <tbody>
              {d.agents.map((a) => (
                <tr key={a.agent}>
                  <td>{a.agent}</td>
                  <td>{a.conversations}</td>
                  <td>{a.wins}</td>
                  <td>{a.kept_alive}</td>
                  <td className={`lift ${tone(a.fit)}`}>{lift(a.fit)}</td>
                  <td>{a.strong.map((s) => <span key={s.kind + s.value} className="tag hot">{word(s.value)} {lift(s.lift)}</span>)}{!a.strong.length && <span className="muted">—</span>}</td>
                  <td>{a.weak.map((s) => <span key={s.kind + s.value} className="tag off">{word(s.value)} {lift(s.lift)}</span>)}{!a.weak.length && <span className="muted">—</span>}</td>
                </tr>
              ))}
              {!d.agents.length && <tr><td colSpan={7} className="muted">No active agents.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="actionrow" style={{ marginTop: 10 }}>
          <button className="btn" disabled={busy} onClick={proposeNow}>Propose matched lists now</button>
          <span className="muted small">
            {d.radar.waiting_approval} waiting for approval · {d.radar.being_dialed} being dialed · {d.radar.per_agent} leads a list ·{' '}
            <Link to="/leads">approve on the Leads tab</Link>
          </span>
        </div>
        <p className="muted small" style={{ marginBottom: 0 }}>
          A record is per conversation: a win counts 1, a callback or email 0.3, pulled toward the floor average until an agent has about 40 conversations.
        </p>
      </div>

      <div className="sectionhead">
        <h3>Where leads answer and convert</h3>
        <div className="rangebar" role="tablist" aria-label="Break down by" style={{ margin: 0, flexWrap: 'wrap' }}>
          {KINDS.filter((k) => d.segments[k]?.length).map((k) => (
            <button key={k} role="tab" aria-selected={kind === k} className={`rangebtn ${kind === k ? 'active' : ''}`} onClick={() => setKind(k)}>{KIND_LABEL[k]}</button>
          ))}
        </div>
      </div>
      <div className="card">
        <div className="tablewrap">
          <table className="data">
            <thead><tr><th>{KIND_LABEL[kind]}</th><th>Dials</th><th>Conversation rate</th><th>Wins</th><th>Pickup vs floor</th><th>Wins vs floor</th></tr></thead>
            <tbody>
              {segs.map((s) => (
                <tr key={s.value}>
                  <td>{kind === 'trade' ? word(s.value) : s.value}</td>
                  <td>{s.dials.toLocaleString()}</td>
                  <td>{pct(s.dials ? s.convos / s.dials : null)}</td>
                  <td>{s.wins}</td>
                  <td className={`lift ${tone(s.answer_lift)}`}>{lift(s.answer_lift)}</td>
                  <td className={`lift ${tone(s.win_lift)}`}>{lift(s.win_lift)}</td>
                </tr>
              ))}
              {!segs.length && <tr><td colSpan={6} className="muted">Not enough dials yet (15 or more per group).</td></tr>}
            </tbody>
          </table>
        </div>
        <p className="muted small" style={{ marginBottom: 0 }}>
          Floor average: {pct(m.answer_rate)} of dials reach a conversation, {pct(m.win_rate, 2)} end in a win. A group on few dials is pulled toward 1×.
        </p>
      </div>

      {(d.trade_hours.length > 0 || d.floor_hours.length > 0) && (
        <>
          <div className="sectionhead"><h3>When they pick up</h3><span className="muted small">hours on the lead's own clock</span></div>
          <div className="card">
            {d.floor_hours.length > 0 && (
              <p style={{ marginTop: 0 }}>
                <b>Whole floor:</b>{' '}
                {[...d.floor_hours].filter((h) => h.lift > 1).sort((a, b) => b.lift - a.lift).slice(0, 3).map((h) => `${hourLabel(h.hour)} (${pct(h.pickup, 0)} pick up)`).join(', ') || 'no hour stands out yet'}
                {d.floor_hours.some((h) => h.lift < 1) && (
                  <span className="muted small"> · worst: {[...d.floor_hours].filter((h) => h.lift < 1).sort((a, b) => a.lift - b.lift).slice(0, 2).map((h) => hourLabel(h.hour)).join(', ')}</span>
                )}
              </p>
            )}
            <ul className="ailist">
              {d.trade_hours.filter((t) => t.best_hours?.length).map((t) => (
                <li key={t.trade}><b>{word(t.trade)}</b>: {t.best_hours!.map((h) => `${hourLabel(h.hour)} (${lift(h.lift)})`).join(', ')} <span className="muted small">{t.dials} dials</span></li>
              ))}
            </ul>
          </div>
        </>
      )}

      <div className="sectionhead">
        <h3>Likeliest to convert, still to call</h3>
        <span className="muted small">
          {d.pool.dialable.toLocaleString()} dialable · {Object.entries(d.pool.bands).map(([b, n]) => `${n.toLocaleString()} ${b}`).join(' · ')}
        </span>
      </div>
      <div className="card">
        <div className="tablewrap">
          <table className="data">
            <thead><tr><th>Lead</th><th>Where</th><th>Trade</th><th>Pickup</th><th>Win</th><th>Best hour</th><th>Why</th></tr></thead>
            <tbody>
              {d.top_leads.map((l) => (
                <tr key={l.lead_id}>
                  <td>{l.name}<div className="muted small">{fmtPhone(l.phone)}{l.callable_now ? '' : ' · outside calling hours now'}</div></td>
                  <td>{[l.city, l.state].filter(Boolean).join(', ') || '—'}</td>
                  <td>{word(l.trade)}</td>
                  <td className={`lift ${tone(l.answer_lift)}`}>{lift(l.answer_lift)}</td>
                  <td className={`lift ${tone(l.win_lift)}`}>{lift(l.win_lift)}</td>
                  <td>{l.best_hour != null ? `${hourLabel(l.best_hour)} theirs` : '—'}</td>
                  <td className="small why">{l.reasons.map(reasonText).join('; ') || <span className="muted">near average on every trait</span>}</td>
                </tr>
              ))}
              {!d.top_leads.length && <tr><td colSpan={7} className="muted">No dialable leads are scored yet.</td></tr>}
            </tbody>
          </table>
        </div>
        {d.pool.best_cells.length > 0 && (
          <p className="small" style={{ marginBottom: 0 }}>
            <b>Richest pockets still to call:</b>{' '}
            {d.pool.best_cells.slice(0, 6).map((c) => `${word(c.trade)} in ${c.state} (${c.leads})`).join(' · ')}
          </p>
        )}
      </div>

      <p className="muted small">
        Gemini sees only these aggregates: rates, counts and lifts, and each agent's name and record. It never sees a lead's name, number or call notes.
        {d.outside_calls_7d > 0 && ` ${d.outside_calls_7d} calls placed straight from Zoom this week are not in any of this.`}
      </p>
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
