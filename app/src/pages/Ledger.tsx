import { useCallback, useEffect, useState } from 'react'
import { supabase, fmtPhone } from '../lib/supabase'

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
}

/** Your G7-lite: the record of every lead that gave a chance / closed,
 *  with a manager field for whether the sale actually landed. */
export default function Ledger() {
  const [rows, setRows] = useState<LedgerRow[]>([])
  const [note, setNote] = useState<Record<number, string>>({})

  const refresh = useCallback(() => {
    supabase.from('handoff_ledger')
      .select('id, kind, summary, rating, handed_at, outcome, outcome_note, lead_snapshot, profiles!handoff_ledger_agent_id_fkey(name)')
      .order('handed_at', { ascending: false })
      .limit(100)
      .then(({ data }) => setRows((data ?? []) as unknown as LedgerRow[]))
  }, [])

  useEffect(() => { refresh() }, [refresh])

  async function setOutcome(id: number, outcome: 'closed' | 'not_closed') {
    await supabase.from('handoff_ledger').update({
      outcome,
      outcome_note: note[id] ?? null,
      outcome_at: new Date().toISOString(),
      outcome_by: (await supabase.auth.getUser()).data.user?.id,
    }).eq('id', id)
    refresh()
  }

  return (
    <div className="page">
      <div className="sectionhead"><h3>Handoff ledger</h3><span className="muted small">these leads exited the dialer (internal DNC); record here whether the sale landed</span></div>
      <div className="card">
        <table className="data">
          <thead><tr><th>When</th><th>Lead</th><th>Kind</th><th>Agent</th><th>What was said</th><th>★</th><th>Sale outcome</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{new Date(r.handed_at).toLocaleDateString()}</td>
                <td>
                  <b>{r.lead_snapshot?.name}</b><br />
                  <span className="muted small">{fmtPhone(r.lead_snapshot?.phone_display ?? r.lead_snapshot?.phone_norm)} · {r.lead_snapshot?.addr_city}, {r.lead_snapshot?.addr_state}</span>
                </td>
                <td>{r.kind === 'chance_website' ? 'Website chance' : 'SEO/receptionist sale'}</td>
                <td>{r.profiles?.name ?? '—'}</td>
                <td style={{ maxWidth: 280 }}>{r.summary ?? <span className="muted">—</span>}</td>
                <td>{r.rating ?? '—'}</td>
                <td>
                  {r.outcome
                    ? <span>{r.outcome === 'closed' ? '✅ closed' : '✖ not closed'}{r.outcome_note && <span className="muted small"> · {r.outcome_note}</span>}</span>
                    : (
                      <div className="formrow">
                        <input style={{ width: 130 }} placeholder="note" value={note[r.id] ?? ''}
                          onChange={(e) => setNote({ ...note, [r.id]: e.target.value })} />
                        <button className="btn ghost" onClick={() => setOutcome(r.id, 'closed')}>closed</button>
                        <button className="btn ghost" onClick={() => setOutcome(r.id, 'not_closed')}>lost</button>
                      </div>
                    )}
                </td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={7} className="muted">No handoffs yet — they appear the moment an agent hits W or S.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  )
}
