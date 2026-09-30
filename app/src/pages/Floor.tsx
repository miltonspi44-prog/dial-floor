import { useCallback, useEffect, useState } from 'react'
import { supabase, fmtPhone, loadTargets } from '../lib/supabase'
import { dispositionLabel, tapsByObjection } from '../lib/types'
import { callBody, saveToLibrary, scenarioFor } from '../lib/library'
import type { FloorRow, RecentCall, Targets } from '../lib/types'

interface NumberRow {
  number: string
  dials_7d: number | null
  connects_7d: number | null
  rate_7d: number | null
  rate_prev_7d: number | null
}
interface CallbackRow {
  id: number
  due_at: string
  lead_id: number
  agent_id: string
  leads: { name: string } | null
  profiles: { name: string } | null
}

/** "4m", "1h 5m" since a timestamp. */
function since(ts: string | null): string {
  if (!ts) return ''
  const m = Math.max(0, Math.round((Date.now() - Date.parse(ts)) / 60000))
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`
}

function statusLine(r: FloorRow): string {
  if (r.status === 'offline') return r.last_seen ? `offline · seen ${since(r.last_seen)} ago` : 'offline'
  return r.since ? `${r.status} · ${since(r.since)}` : r.status
}

/** Talk time from Zoom, once its event has matched the call. */
function talkTime(c: RecentCall): string {
  if (!c.matched) return 'waiting for Zoom'
  const s = c.duration_seconds ?? 0
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

function Count({ value, target, label }: { value: number; target: number | null; label: string }) {
  return <span><b>{value}</b>{label}{target ? <span className="of"> / {target}</span> : null}</span>
}

export default function Floor({ isManager }: { isManager: boolean }) {
  const [rows, setRows] = useState<FloorRow[]>([])
  const [numbers, setNumbers] = useState<NumberRow[]>([])
  const [callbacks, setCallbacks] = useState<CallbackRow[]>([])
  const [calls, setCalls] = useState<RecentCall[]>([])
  const [targets, setTargets] = useState<Targets>({ dials: null, connects: null, handoffs: null })
  const [dropPts, setDropPts] = useState(10)
  const [aiOn, setAiOn] = useState(false)
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(() => {
    supabase.from('v_floor_today').select('*').order('name')
      .then(({ data }) => setRows((data ?? []) as FloorRow[]))
    supabase.from('v_number_health').select('*').order('dials_7d', { ascending: false })
      .then(({ data }) => setNumbers((data ?? []) as NumberRow[]))
    supabase.from('attempts')
      .select('id, clicked_at, duration_seconds, call_result, disposition, note, matched, ai_summary, leads(name), profiles!attempts_agent_id_fkey(name), card_taps(counter, battlecards(objection))')
      .order('clicked_at', { ascending: false }).limit(25)
      .then(({ data }) => setCalls((data ?? []) as unknown as RecentCall[]))
    if (isManager) {
      supabase.from('callbacks')
        .select('id, due_at, lead_id, agent_id, leads(name), profiles!callbacks_agent_id_fkey(name)')
        .eq('status', 'scheduled').order('due_at').limit(20)
        .then(({ data }) => setCallbacks((data ?? []) as unknown as CallbackRow[]))
    }
  }, [isManager])

  useEffect(() => {
    loadTargets().then(setTargets)
    // spam_alert_drop_pts: the week-over-week drop (in points) that flags a number;
    // ai_summaries_enabled: off on a Zoom plan without AI Companion, so no summary column
    supabase.from('app_settings').select('key, value').in('key', ['spam_alert_drop_pts', 'ai_summaries_enabled'])
      .then(({ data }) => {
        for (const s of data ?? []) {
          if (s.key === 'spam_alert_drop_pts') {
            const v = Number(s.value)
            if (Number.isFinite(v) && v > 0) setDropPts(v)
          }
          if (s.key === 'ai_summaries_enabled') setAiOn(s.value === true || s.value === 'true')
        }
      })
  }, [])

  useEffect(() => {
    refresh()
    const chan = supabase
      .channel('floor')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'agent_status' }, refresh)
      .subscribe()
    const iv = window.setInterval(refresh, 30000)
    return () => { supabase.removeChannel(chan); window.clearInterval(iv) }
  }, [refresh])

  function flash(m: string) {
    setToast(m); window.setTimeout(() => setToast(null), 2500)
  }

  function copy(text: string) {
    navigator.clipboard?.writeText(text).then(() => flash('Copied'))
  }

  async function requeue(cb: CallbackRow) {
    const { error } = await supabase.rpc('release_lead', { p_lead_id: cb.lead_id })
    if (error) flash(error.message)
    refresh()
  }

  async function keep(c: RecentCall) {
    const lead = c.leads?.name ?? 'a lead'
    const { error } = await saveToLibrary({
      title: `${lead}: ${dispositionLabel(c.disposition)}`,
      scenario: scenarioFor(c.disposition),
      body: callBody({ disposition: c.disposition, duration: c.duration_seconds, note: c.note,
        taps: tapsByObjection(c.card_taps ?? []), summary: c.ai_summary?.summary }),
      attempt_id: c.id, lead_name: c.leads?.name ?? null, agent_name: c.profiles?.name ?? null,
    })
    flash(error ? error.message : 'Saved to the library (Playbook tab)')
  }

  function spamFlag(n: NumberRow): boolean {
    if (n.rate_7d == null) return false
    if (n.rate_prev_7d != null && n.rate_prev_7d - n.rate_7d >= dropPts) return true
    return (n.dials_7d ?? 0) >= 60 && n.rate_7d < 8
  }
  const flagged = numbers.filter(spamFlag)

  return (
    <div className="page">
      {flagged.length > 0 && (
        <div className="card alertcard">
          <b>Possible spam label</b>
          {flagged.map((n) => (
            <div key={n.number} className="small">
              {fmtPhone(n.number)}: connect rate {n.rate_prev_7d != null ? `${n.rate_prev_7d}% → ` : ''}{n.rate_7d}% over the last 7 days
            </div>
          ))}
          <div className="small">Swap it for a fresh number in Zoom, then watch the new one here.</div>
        </div>
      )}

      <div className="floorgrid">
        {rows.map((r) => {
          const pct = targets.dials ? Math.min(100, Math.round((100 * r.dials_today) / targets.dials)) : null
          return (
            <div className="card agenttile" key={r.agent_id}>
              <div className="aname"><span className={`statusdot ${r.status}`} />{r.name}</div>
              <div className="small muted" style={{ minHeight: 20 }}>
                {statusLine(r)}
                {r.lead_name && <> · {r.lead_name}</>}
              </div>
              {r.phone_display && (
                <div className="small">
                  {fmtPhone(r.phone_display)}
                  <button className="copybtn" onClick={() => copy(r.phone_display!)}>copy</button>
                </div>
              )}
              <div className="tilecounts">
                <Count value={r.dials_today} target={targets.dials} label="dials" />
                <Count value={r.connects_today} target={targets.connects} label="connects" />
                <Count value={r.handoffs_today} target={targets.handoffs} label="handoffs" />
                <span><b>{r.emails_today}</b>emails</span>
              </div>
              {pct != null && (
                <div className="targetbar" title={`${pct}% of today's dial target`}><i style={{ width: `${pct}%` }} /></div>
              )}
            </div>
          )
        })}
        {!rows.length && <div className="muted">No active agents yet — create logins in Supabase Auth.</div>}
      </div>

      {isManager && (
        <>
          <div className="sectionhead"><h3>Scheduled callbacks</h3><span className="muted small">locked to their agent — push back to the queue if needed</span></div>
          <div className="card">
            {callbacks.length ? (
              <table className="data">
                <thead><tr><th>Due</th><th>Lead</th><th>Agent</th><th /></tr></thead>
                <tbody>
                  {callbacks.map((c) => (
                    <tr key={c.id}>
                      <td>{new Date(c.due_at).toLocaleString()}</td>
                      <td>{c.leads?.name ?? c.lead_id}</td>
                      <td>{c.profiles?.name ?? '—'}</td>
                      <td><button className="btn ghost small" onClick={() => requeue(c)}>push back to queue</button></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : <span className="muted small">None scheduled.</span>}
          </div>
        </>
      )}

      <div className="sectionhead"><h3>Recent calls</h3><span className="muted small">talk time from Zoom{aiOn ? '; the AI summary appears a few minutes after the call' : ''}</span></div>
      <div className="card">
        {calls.length ? (
          <table className="data">
            <thead><tr><th>When</th><th>Agent</th><th>Lead</th><th>Talk</th><th>Outcome</th><th>Call log</th>{aiOn && <th>AI summary</th>}{isManager && <th />}</tr></thead>
            <tbody>
              {calls.map((c) => (
                <tr key={c.id}>
                  <td>{new Date(c.clicked_at).toLocaleString([], { dateStyle: 'short', timeStyle: 'short' })}</td>
                  <td>{c.profiles?.name ?? '—'}</td>
                  <td>{c.leads?.name ?? '—'}</td>
                  <td>{talkTime(c)}</td>
                  <td>{dispositionLabel(c.disposition)}</td>
                  <td>
                    {tapsByObjection(c.card_taps ?? []).map((t) => (
                      <div key={t.objection} className="small">
                        heard “{t.objection}”{t.counters.length ? <span className="muted"> → said: {t.counters.join(' / ')}</span> : null}
                      </div>
                    ))}
                    {c.note ? <div className="small">{c.note}</div> : !c.card_taps?.length && <span className="muted small">—</span>}
                  </td>
                  {aiOn && (
                    <td>
                      {c.ai_summary?.summary ? (
                        <div className="aisum">
                          {c.ai_summary.summary}
                          {c.ai_summary.next_steps && <div className="muted">Next: {c.ai_summary.next_steps}</div>}
                        </div>
                      ) : <span className="muted small">—</span>}
                    </td>
                  )}
                  {isManager && (
                    <td className="rowactions">
                      {c.disposition && <button className="btn ghost small" title="Keep this call in the Playbook library" onClick={() => keep(c)}>save</button>}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        ) : <span className="muted small">No calls yet.</span>}
      </div>

      <div className="sectionhead"><h3>Number health</h3><span className="muted small">a connect rate down {dropPts}+ points on the week = probable spam label — swap that number in Zoom</span></div>
      <div className="card">
        {numbers.length ? (
          <table className="data">
            <thead><tr><th>Number</th><th>Dials 7d</th><th>Connects 7d</th><th>Rate</th><th>Prev wk</th><th /></tr></thead>
            <tbody>
              {numbers.map((n) => (
                <tr key={n.number}>
                  <td>{fmtPhone(n.number)}</td>
                  <td>{n.dials_7d ?? 0}</td>
                  <td>{n.connects_7d ?? 0}</td>
                  <td>{n.rate_7d != null ? `${n.rate_7d}%` : '—'}</td>
                  <td>{n.rate_prev_7d != null ? `${n.rate_prev_7d}%` : '—'}</td>
                  <td>{spamFlag(n) && <span className="tag" style={{ background: 'var(--bad-bg)', color: 'var(--bad)' }}>possible spam flag</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <span className="muted small">No dial data yet — stats appear after the first webhook-matched calls.</span>}
      </div>
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
