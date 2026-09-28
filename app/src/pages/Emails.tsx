import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

interface EmailRow {
  id: number
  email: string
  status: string
  created_at: string
  leads: { name: string; addr_city: string | null; addr_state: string | null } | null
  profiles: { name: string } | null
}

/** G5: like your SMS ritual, but for email — the system queues and tracks,
 *  a human sends from their own mail client. Nothing is transmitted here. */
export default function Emails() {
  const [rows, setRows] = useState<EmailRow[]>([])
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(() => {
    supabase.from('email_queue')
      .select('id, email, status, created_at, leads(name, addr_city, addr_state), profiles!email_queue_flagged_by_fkey(name)')
      .order('created_at', { ascending: false })
      .limit(100)
      .then(({ data }) => setRows((data ?? []) as unknown as EmailRow[]))
  }, [])

  useEffect(() => { refresh() }, [refresh])

  function copy(text: string) {
    navigator.clipboard?.writeText(text).then(() => {
      setToast('Copied'); window.setTimeout(() => setToast(null), 1500)
    })
  }

  async function mark(id: number, status: 'sent' | 'skipped') {
    await supabase.from('email_queue').update({
      status,
      sent_by: (await supabase.auth.getUser()).data.user?.id,
      sent_at: status === 'sent' ? new Date().toISOString() : null,
    }).eq('id', id)
    refresh()
  }

  const pending = rows.filter((r) => r.status === 'flagged')
  const done = rows.filter((r) => r.status !== 'flagged')

  return (
    <div className="page">
      <div className="sectionhead"><h3>Email queue</h3><span className="muted small">{pending.length} waiting · send from your own mail client, then mark sent</span></div>
      <div className="card">
        <table className="data">
          <thead><tr><th>Flagged</th><th>Lead</th><th>Email</th><th>By</th><th /></tr></thead>
          <tbody>
            {pending.map((r) => (
              <tr key={r.id}>
                <td>{new Date(r.created_at).toLocaleDateString()}</td>
                <td>{r.leads?.name}<br /><span className="muted small">{r.leads?.addr_city}, {r.leads?.addr_state}</span></td>
                <td>{r.email} <button className="copybtn" onClick={() => copy(r.email)}>copy</button></td>
                <td>{r.profiles?.name ?? '—'}</td>
                <td>
                  <button className="btn ghost" onClick={() => mark(r.id, 'sent')}>mark sent</button>
                  <button className="btn ghost" onClick={() => mark(r.id, 'skipped')}>skip</button>
                </td>
              </tr>
            ))}
            {!pending.length && <tr><td colSpan={5} className="muted">Queue is clear.</td></tr>}
          </tbody>
        </table>
      </div>
      {done.length > 0 && (
        <>
          <div className="sectionhead"><h3>History</h3></div>
          <div className="card">
            <table className="data">
              <tbody>
                {done.map((r) => (
                  <tr key={r.id}>
                    <td>{new Date(r.created_at).toLocaleDateString()}</td>
                    <td>{r.leads?.name}</td>
                    <td>{r.email}</td>
                    <td>{r.status}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
