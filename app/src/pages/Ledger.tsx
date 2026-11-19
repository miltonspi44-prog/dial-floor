import { useCallback, useEffect, useState } from 'react'
import { supabase, fmtPhone } from '../lib/supabase'
import { saveToLibrary } from '../lib/library'

interface LedgerRow {
  id: number
  kind: string
  summary: string | null
  rating: number | null
  handed_at: string
  outcome: string | null
  outcome_note: string | null
  lead_snapshot: { name?: string; phone_display?: string; phone_norm?: string; addr_city?: string; addr_state?: string }
  profiles: { name: string } | null
  agent_id: string | null
  // 0052: the call logged for a handoff recorded by hand; set means it can be given to someone else
  manual_attempt_id: number | null
}

/** Your G7-lite: the record of every lead that gave a chance / closed,
 *  with a manager field for whether the sale actually landed. */
export default function Ledger() {
  const [rows, setRows] = useState<LedgerRow[]>([])
  const [note, setNote] = useState<Record<number, string>>({})
  const [toast, setToast] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  // item 46: find one handoff, fix its outcome, carry the lot to your other system
  const [q, setQ] = useState('')
  const [editing, setEditing] = useState<number | null>(null)
  // 0052: who a handoff recorded by hand can be given to
  const [agents, setAgents] = useState<{ id: string; name: string; role: string }[]>([])

  const refresh = useCallback(() => {
    supabase.from('handoff_ledger')
      .select('id, kind, summary, rating, handed_at, outcome, outcome_note, lead_snapshot, agent_id, manual_attempt_id, profiles!handoff_ledger_agent_id_fkey(name)')
      .order('handed_at', { ascending: false })
      .limit(500)
      .then(({ data, error: e }) => {
        if (e) { setErr(e.message); return }
        setErr(null)
        setRows((data ?? []) as unknown as LedgerRow[])
      })
  }, [])

  useEffect(() => { refresh() }, [refresh])
  useEffect(() => {
    supabase.from('profiles').select('id, name, role').eq('active', true).order('name')
      .then(({ data }) => setAgents((data ?? []) as { id: string; name: string; role: string }[]))
  }, [])

  // 0052: a handoff recorded by hand belongs to whoever took the callback; its call moves with it
  async function reassign(r: LedgerRow, agent: string) {
    if (!agent || agent === r.agent_id) return
    const { data, error } = await supabase.rpc('reassign_handoff', { p_handoff: r.id, p_agent: agent })
    setToast(error ? error.message : `Now ${(data as { name: string }).name}'s handoff: it counts in their stats`)
    window.setTimeout(() => setToast(null), 3000)
    refresh()
  }

  async function keep(r: LedgerRow) {
    const lead = r.lead_snapshot?.name ?? 'a lead'
    const kind = r.kind === 'chance_website' ? 'Website chance' : 'SEO/receptionist sale'
    const { error } = await saveToLibrary({
      title: `${lead}: ${kind}`,
      scenario: r.kind === 'chance_website' ? 'Website pitch' : 'Google visibility pitch',
      body: [`Outcome: ${kind}`, r.summary && `What was said: ${r.summary}`, r.rating && `Lead rating: ${r.rating}/5`]
        .filter(Boolean).join('\n'),
      lead_name: r.lead_snapshot?.name ?? null, agent_name: r.profiles?.name ?? null,
    })
    setToast(error ? error.message : 'Saved to the library (Playbook tab)')
    window.setTimeout(() => setToast(null), 2500)
  }

  async function setOutcome(id: number, outcome: 'closed' | 'not_closed') {
    // item 46: write and correct through the one RPC, so a settled row can change
    const { error } = await supabase.rpc('update_handoff', {
      p_id: id, p_outcome: outcome, p_note: note[id] ?? null,
    })
    if (error) { setToast(error.message); window.setTimeout(() => setToast(null), 3000); return }
    setEditing(null)
    refresh()
  }

  const shown = q.trim()
    ? rows.filter((r) => {
        const hay = `${r.lead_snapshot?.name ?? ''} ${r.lead_snapshot?.phone_norm ?? ''} ${r.profiles?.name ?? ''} ${r.summary ?? ''} ${r.outcome_note ?? ''}`.toLowerCase()
        return hay.includes(q.trim().toLowerCase())
      })
    : rows

  // item 46: the export your other system imports — what is on screen, as CSV
  function exportCsv() {
    const esc = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`
    const lines = [
      ['handed_at', 'lead', 'phone', 'city', 'state', 'kind', 'agent', 'rating', 'summary', 'outcome', 'outcome_note'].join(','),
      ...shown.map((r) => [
        r.handed_at, r.lead_snapshot?.name, r.lead_snapshot?.phone_norm,
        r.lead_snapshot?.addr_city, r.lead_snapshot?.addr_state,
        r.kind, r.profiles?.name, r.rating, r.summary, r.outcome, r.outcome_note,
      ].map(esc).join(',')),
    ]
    const blob = new Blob([lines.join('\n')], { type: 'text/csv' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `handoffs-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(a.href)
  }

  return (
    <div className="page">
      <div className="sectionhead">
        <h3>Handoffs</h3>
        <span className="muted small">these leads exited the dialer (internal DNC); record here whether the sale landed</span>
        <input placeholder="search lead, number, agent…" value={q} onChange={(e) => setQ(e.target.value)}
          aria-label="Search the handoffs" style={{ marginLeft: 'auto', width: 220 }} />
        <button className="btn ghost small" onClick={exportCsv} disabled={!shown.length}>Export CSV</button>
      </div>
      {err && <div className="card alertcard">The handoffs did not load: {err}</div>}
      <div className="card">
        <div className="tablewrap">
        <table className="data">
          <thead><tr><th>When</th><th>Lead</th><th>Kind</th><th>Agent</th><th>What was said</th><th>★</th><th>Sale outcome</th><th /></tr></thead>
          <tbody>
            {shown.map((r) => (
              <tr key={r.id}>
                <td>{new Date(r.handed_at).toLocaleDateString()}</td>
                <td>
                  <b>{r.lead_snapshot?.name}</b><br />
                  <span className="muted small">{fmtPhone(r.lead_snapshot?.phone_display ?? r.lead_snapshot?.phone_norm)} · {r.lead_snapshot?.addr_city}, {r.lead_snapshot?.addr_state}</span>
                </td>
                <td>{r.kind === 'chance_website' ? 'Website chance' : 'SEO/receptionist sale'}</td>
                <td>
                  {r.manual_attempt_id != null ? (
                    <>
                      <select value={r.agent_id ?? ''} onChange={(e) => reassign(r, e.target.value)}
                        aria-label={`Whose handoff: ${r.lead_snapshot?.name ?? 'this lead'}`}
                        title="Recorded by hand: give it to whoever took the callback, and it counts in their stats">
                        {/* the agent it is credited to stays shown even if they have left */}
                        {r.agent_id && !agents.some((a) => a.id === r.agent_id) && <option value={r.agent_id}>{r.profiles?.name ?? '—'}</option>}
                        {agents.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
                      </select>
                      <div className="muted small">recorded by hand</div>
                    </>
                  ) : (r.profiles?.name ?? '—')}
                </td>
                <td style={{ maxWidth: 280 }}>{r.summary ?? <span className="muted">—</span>}</td>
                <td>{r.rating ?? '—'}</td>
                <td>
                  {r.outcome && editing !== r.id
                    ? <span>
                        {r.outcome === 'closed' ? '✅ closed' : '✖ not closed'}
                        {r.outcome_note && <span className="muted small"> · {r.outcome_note}</span>}
                        <button className="copybtn" title="Correct this outcome"
                          onClick={() => { setEditing(r.id); setNote({ ...note, [r.id]: r.outcome_note ?? '' }) }}>edit</button>
                      </span>
                    : (
                      <div className="formrow">
                        <input style={{ width: 130 }} placeholder="note" value={note[r.id] ?? ''}
                          onChange={(e) => setNote({ ...note, [r.id]: e.target.value })} />
                        <button className="btn ghost" onClick={() => setOutcome(r.id, 'closed')}>closed</button>
                        <button className="btn ghost" onClick={() => setOutcome(r.id, 'not_closed')}>lost</button>
                        {editing === r.id && <button className="btn ghost" onClick={() => setEditing(null)}>keep as is</button>}
                      </div>
                    )}
                </td>
                <td className="rowactions">
                  <button className="btn ghost small" title="Keep this call in the Playbook library" onClick={() => keep(r)}>save</button>
                </td>
              </tr>
            ))}
            {!shown.length && <tr><td colSpan={8} className="muted">{err ? 'The ledger could not be read.' : q ? 'Nothing matches that search.' : 'No handoffs yet — they appear the moment an agent hits W or S.'}</td></tr>}
          </tbody>
        </table>
        </div>
      </div>
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
