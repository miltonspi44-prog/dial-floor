import { useCallback, useEffect, useState } from 'react'
import { supabase, fmtPhone } from '../lib/supabase'
import type { FloorRow } from '../lib/types'

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

export default function Floor({ isManager }: { isManager: boolean }) {
  const [rows, setRows] = useState<FloorRow[]>([])
  const [numbers, setNumbers] = useState<NumberRow[]>([])
  const [callbacks, setCallbacks] = useState<CallbackRow[]>([])
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(() => {
    supabase.from('v_floor_today').select('*').order('name')
      .then(({ data }) => setRows((data ?? []) as FloorRow[]))
    supabase.from('v_number_health').select('*').order('dials_7d', { ascending: false })
      .then(({ data }) => setNumbers((data ?? []) as NumberRow[]))
    if (isManager) {
      supabase.from('callbacks')
        .select('id, due_at, lead_id, agent_id, leads(name), profiles!callbacks_agent_id_fkey(name)')
        .eq('status', 'scheduled').order('due_at').limit(20)
        .then(({ data }) => setCallbacks((data ?? []) as unknown as CallbackRow[]))
    }
  }, [isManager])

  useEffect(() => {
    refresh()
    const chan = supabase
      .channel('floor')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'agent_status' }, refresh)
      .subscribe()
    const iv = window.setInterval(refresh, 30000)
    return () => { supabase.removeChannel(chan); window.clearInterval(iv) }
  }, [refresh])

  function copy(text: string) {
    navigator.clipboard?.writeText(text).then(() => {
      setToast('Copied'); window.setTimeout(() => setToast(null), 1500)
    })
  }

  async function requeue(cb: CallbackRow) {
    await supabase.rpc('release_lead', { p_lead_id: cb.lead_id })
    refresh()
  }

  function spamFlag(n: NumberRow): boolean {
    if (n.rate_7d == null) return false
    if (n.rate_prev_7d != null && n.rate_prev_7d - n.rate_7d >= 10) return true
    return (n.dials_7d ?? 0) >= 60 && n.rate_7d < 8
  }

  return (
    <div className="page">
      <div className="floorgrid">
        {rows.map((r) => (
          <div className="card agenttile" key={r.agent_id}>
            <div className="aname"><span className={`statusdot ${r.status}`} />{r.name}</div>
            <div className="small muted" style={{ minHeight: 20 }}>
              {r.status === 'offline' ? 'offline' : r.status}
              {r.lead_name && <> · {r.lead_name}</>}
            </div>
            {r.phone_display && (
              <div className="small">
                {fmtPhone(r.phone_display)}
                <button className="copybtn" onClick={() => copy(r.phone_display!)}>copy</button>
              </div>
            )}
            <div className="tilecounts">
              <span><b>{r.dials_today}</b>dials</span>
              <span><b>{r.connects_today}</b>connects</span>
              <span><b>{r.handoffs_today}</b>handoffs</span>
              <span><b>{r.emails_today}</b>emails</span>
            </div>
          </div>
        ))}
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

      <div className="sectionhead"><h3>Number health</h3><span className="muted small">connect-rate collapse = probable spam label — swap that number in Zoom</span></div>
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
