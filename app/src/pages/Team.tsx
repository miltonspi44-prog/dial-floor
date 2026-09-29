import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { TeamMember } from '../lib/types'

function ago(iso: string | null): string {
  if (!iso) return 'never'
  const min = Math.round((Date.now() - Date.parse(iso)) / 60000)
  if (min < 1) return 'just now'
  if (min < 60) return `${min} min ago`
  const h = Math.round(min / 60)
  if (h < 24) return `${h} h ago`
  const d = Math.round(h / 24)
  return d < 30 ? `${d} d ago` : new Date(iso).toLocaleDateString()
}

function holds(m: TeamMember): string {
  const parts = []
  if (m.callbacks) parts.push(`${m.callbacks} callback${m.callbacks === 1 ? '' : 's'}`)
  if (m.lists) parts.push(`${m.lists} list${m.lists === 1 ? '' : 's'}`)
  return parts.join(' · ')
}

/** Who can sign in and what they can do. Logins themselves are created in
 *  Supabase Auth; they show up here as agents. */
export default function Team({ me }: { me: string }) {
  const [rows, setRows] = useState<TeamMember[]>([])
  const [error, setError] = useState<string | null>(null)
  const [names, setNames] = useState<Record<string, string>>({}) // renames being typed
  const [busy, setBusy] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  function say(msg: string) {
    setToast(msg)
    window.setTimeout(() => setToast(null), 2200)
  }

  const refresh = useCallback(() => {
    supabase.rpc('team').then(({ data, error: e }) => {
      if (e) { setError(e.message); return }
      setError(null)
      setRows((data ?? []) as TeamMember[])
    })
  }, [])

  useEffect(() => { refresh() }, [refresh])

  async function change(m: TeamMember, patch: { p_name?: string; p_role?: string; p_active?: boolean }, done: string) {
    setBusy(m.id)
    const { error: e } = await supabase.rpc('set_member', { p_id: m.id, ...patch })
    setBusy(null)
    if (e) { say(e.message); return }
    if (patch.p_name !== undefined) setNames((prev) => { const next = { ...prev }; delete next[m.id]; return next })
    say(done)
    refresh()
  }

  function setRole(m: TeamMember, role: string) {
    if (role === m.role) return
    const ask = role === 'manager'
      ? `Make ${m.name} a manager? Managers see every page and can change the team.`
      : `Make ${m.name} an agent? They lose the manager pages.`
    if (window.confirm(ask)) change(m, { p_role: role }, `${m.name} is now ${role === 'manager' ? 'a manager' : 'an agent'}`)
  }

  function setActive(m: TeamMember, active: boolean) {
    if (active) { change(m, { p_active: true }, `${m.name} is back on the floor`); return }
    const held = holds(m)
    const ask = `Take ${m.name} off the floor? They'll be served no leads and can't dial until reactivated `
      + '(a call already open can still be logged).'
      + (held ? `\n\nThey still hold ${held}: push callbacks back on the Floor page, and reassign lists on the Lists page.` : '')
    if (window.confirm(ask)) change(m, { p_active: false }, `${m.name} is off the floor`)
  }

  return (
    <div className="page">
      <div className="sectionhead"><h3>Team</h3><span className="muted small">who can sign in, and what they can do</span></div>
      {error && <div className="card alertcard">{error}</div>}
      <div className="card">
        <div className="tablewrap">
          <table className="data team">
            <thead><tr><th>Name</th><th>Login</th><th>Role</th><th>Status</th><th>Last sign-in</th><th>Still holds</th></tr></thead>
            <tbody>
              {rows.map((m) => {
                const self = m.id === me
                const typed = names[m.id]
                const renamed = typed !== undefined && typed.trim() !== '' && typed.trim() !== m.name
                const held = holds(m)
                return (
                  <tr key={m.id} className={m.active ? '' : 'inactive'}>
                    <td>
                      <div className="formrow">
                        <input style={{ width: 170 }} value={typed ?? m.name} aria-label={`Name of ${m.name}`}
                          onChange={(e) => setNames({ ...names, [m.id]: e.target.value })}
                          onKeyDown={(e) => { if (e.key === 'Enter' && renamed) change(m, { p_name: typed }, 'Renamed') }} />
                        {renamed && <button className="btn ghost" disabled={busy === m.id} onClick={() => change(m, { p_name: typed }, 'Renamed')}>save</button>}
                      </div>
                      {self && <span className="muted small">you</span>}
                    </td>
                    <td className="muted small">{m.email ?? '—'}</td>
                    <td>
                      <select value={m.role} disabled={self || busy === m.id} onChange={(e) => setRole(m, e.target.value)}
                        title={self ? "You can't change your own role: ask another manager" : undefined}>
                        <option value="agent">Agent</option>
                        <option value="manager">Manager</option>
                      </select>
                    </td>
                    <td>
                      <span className={`tag ${m.active ? 'hot' : 'off'}`}>{m.active ? 'active' : 'off the floor'}</span>
                      {!self && (
                        <button className="btn ghost" disabled={busy === m.id} onClick={() => setActive(m, !m.active)}>
                          {m.active ? 'deactivate' : 'reactivate'}
                        </button>
                      )}
                    </td>
                    <td className="small">{ago(m.last_sign_in_at)}</td>
                    <td className="small">
                      {held
                        ? <span className={m.active ? 'muted' : 'warnline'}>{held}{!m.active && ': push back or reassign'}</span>
                        : <span className="muted">—</span>}
                    </td>
                  </tr>
                )
              })}
              {!rows.length && !error && <tr><td colSpan={6} className="muted">Loading…</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
      <p className="muted small">
        Adding someone: create their login in Supabase → Authentication → Add user (email and password). They appear here as an
        agent; set their name and role here. A manager can't demote or deactivate themselves, so the team always keeps an active manager.
      </p>
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
