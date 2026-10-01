import { Fragment, useCallback, useEffect, useState } from 'react'
import { supabase, callAdmin } from '../lib/supabase'
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
  return parts.join(' and ')
}

type Panel =
  | { kind: 'remove'; id: string; handBack: boolean }
  | { kind: 'password'; id: string; own: boolean; typed: string }
  | { kind: 'email'; id: string; email: string }

interface NewUser { name: string; email: string; role: 'agent' | 'manager'; own: boolean; password: string }
interface Creds { title: string; email: string; password: string }

/** Everyone who can sign in: add logins, manage them, remove them. No Supabase dashboard needed. */
export default function Users({ me }: { me: string }) {
  const [rows, setRows] = useState<TeamMember[]>([])
  const [error, setError] = useState<string | null>(null)
  const [names, setNames] = useState<Record<string, string>>({}) // renames being typed
  const [busy, setBusy] = useState(false)
  const [adding, setAdding] = useState<NewUser | null>(null)
  const [panel, setPanel] = useState<Panel | null>(null)
  const [creds, setCreds] = useState<Creds | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  function say(msg: string) {
    setToast(msg)
    window.setTimeout(() => setToast(null), 2600)
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
    setBusy(true)
    const { error: e } = await supabase.rpc('set_member', { p_id: m.id, ...patch })
    setBusy(false)
    if (e) { say(e.message); return }
    if (patch.p_name !== undefined) setNames((prev) => { const next = { ...prev }; delete next[m.id]; return next })
    say(done)
    refresh()
  }

  function setRole(m: TeamMember, role: string) {
    if (role === m.role) return
    const ask = role === 'manager'
      ? `Make ${m.name} a manager? Managers see every page and can manage users.`
      : `Make ${m.name} an agent? They lose the manager pages.`
    if (window.confirm(ask)) change(m, { p_role: role }, `${m.name} is now ${role === 'manager' ? 'a manager' : 'an agent'}`)
  }

  function setActive(m: TeamMember, active: boolean) {
    if (active) { change(m, { p_active: true }, `${m.name} is back on the floor`); return }
    const held = holds(m)
    const ask = `Take ${m.name} off the floor? They can still sign in, but get no leads and can't dial until you bring them back `
      + '(a call already open can still be logged).'
      + (held ? `\n\nThey still hold ${held}: use “hand back” to pass them to the team.` : '')
    if (window.confirm(ask)) change(m, { p_active: false }, `${m.name} is off the floor`)
  }

  async function handBack(m: TeamMember, quiet = false) {
    const { data, error: e } = await supabase.rpc('release_member', { p_id: m.id })
    if (e) { say(e.message); return false }
    const r = data as { callbacks: number; lists: number }
    if (!quiet) say(`Handed back ${r.callbacks} callback${r.callbacks === 1 ? '' : 's'} and ${r.lists} list${r.lists === 1 ? '' : 's'}`)
    refresh()
    return true
  }

  async function create() {
    if (!adding) return
    setBusy(true)
    const { data, error: e } = await callAdmin<{ email: string; password: string | null }>('create', {
      name: adding.name, email: adding.email, role: adding.role, password: adding.own ? adding.password : '',
    })
    setBusy(false)
    if (e || !data) { say(e ?? 'Could not create the login'); return }
    setCreds({ title: `Login ready for ${adding.name.trim()}`, email: data.email, password: data.password ?? adding.password })
    setAdding(null)
    refresh()
  }

  async function confirmPanel(m: TeamMember) {
    if (!panel) return
    setBusy(true)
    if (panel.kind === 'remove') {
      if (panel.handBack && holds(m) && !(await handBack(m, true))) { setBusy(false); return }
      // The dialog has already told the manager which of the two this is, from the
      // same counts the function checks, so say which one we meant: without it the
      // function keeps the login every time and "Delete login" quietly blocks instead.
      const { data, error: e } = await callAdmin<{ deleted?: boolean; removed?: boolean }>(
        'remove', { user_id: m.id, keep_history: m.has_history })
      setBusy(false)
      if (e) { say(e); return }
      say(data?.deleted ? `${m.name}’s login is deleted` : `${m.name} is removed: their history stays in the reports`)
    } else if (panel.kind === 'password') {
      const { data, error: e } = await callAdmin<{ password: string | null }>('reset_password', {
        user_id: m.id, password: panel.own ? panel.typed : '',
      })
      setBusy(false)
      if (e) { say(e); return }
      setCreds({ title: `New password for ${m.name}`, email: m.email ?? '', password: data?.password ?? panel.typed })
    } else {
      const { error: e } = await callAdmin('set_email', { user_id: m.id, email: panel.email })
      setBusy(false)
      if (e) { say(e); return }
      say(`${m.name} now signs in as ${panel.email.trim().toLowerCase()}`)
    }
    setPanel(null)
    refresh()
  }

  async function restore(m: TeamMember) {
    if (!window.confirm(`Restore ${m.name}? They can sign in again and are back on the floor.`)) return
    setBusy(true)
    const { error: e } = await callAdmin('restore', { user_id: m.id })
    setBusy(false)
    if (e) { say(e); return }
    say(`${m.name} is restored`)
    refresh()
  }

  function copy(text: string, msg: string) {
    navigator.clipboard?.writeText(text).then(() => say(msg))
  }

  const current = rows.filter((m) => !m.removed)
  const removed = rows.filter((m) => m.removed)
  const signIn = window.location.origin

  return (
    <div className="page">
      <div className="sectionhead">
        <h3>Users</h3>
        <span className="muted small">who can sign in, and what they can do</span>
        <button className="btn primary" style={{ marginLeft: 'auto' }} disabled={!!adding}
          onClick={() => { setCreds(null); setAdding({ name: '', email: '', role: 'agent', own: false, password: '' }) }}>
          Add user
        </button>
      </div>
      {error && <div className="card alertcard">{error}</div>}

      {creds && (
        <div className="card credcard">
          <b>{creds.title}</b>
          <div className="factrow"><span>Sign in at</span><span className="v">{signIn}</span></div>
          <div className="factrow"><span>Email</span><span className="v">{creds.email}</span></div>
          <div className="factrow"><span>Password</span><span className="v mono">{creds.password}</span></div>
          <div className="actionrow">
            <button className="btn primary" onClick={() => copy(`Dial Floor: ${signIn}\nEmail: ${creds.email}\nPassword: ${creds.password}`, 'Sign-in details copied')}>
              Copy sign-in details
            </button>
            <button className="btn ghost" onClick={() => setCreds(null)}>Done</button>
          </div>
          <p className="muted small" style={{ margin: 0 }}>Shown once: nobody can read a password back later. Hand it over privately; they can sign in right away.</p>
        </div>
      )}

      {adding && (
        <div className="card tpleditor" style={{ marginBottom: 12 }}>
          <div className="formrow">
            <label>Name<input value={adding.name} onChange={(e) => setAdding({ ...adding, name: e.target.value })} autoFocus /></label>
            <label>Email (their login)<input type="email" style={{ width: 260 }} value={adding.email} onChange={(e) => setAdding({ ...adding, email: e.target.value })} /></label>
            <label>Role
              <select value={adding.role} onChange={(e) => setAdding({ ...adding, role: e.target.value as NewUser['role'] })}>
                <option value="agent">Agent</option>
                <option value="manager">Manager</option>
              </select>
            </label>
          </div>
          <div className="formrow" style={{ marginTop: 10, alignItems: 'center' }}>
            <label className="radio"><input type="radio" checked={!adding.own} onChange={() => setAdding({ ...adding, own: false })} /> Generate a password</label>
            <label className="radio"><input type="radio" checked={adding.own} onChange={() => setAdding({ ...adding, own: true })} /> I’ll set it</label>
            {adding.own && <input type="text" placeholder="8+ characters" value={adding.password} onChange={(e) => setAdding({ ...adding, password: e.target.value })} />}
          </div>
          <div className="actionrow">
            <button className="btn primary" disabled={busy} onClick={create}>Create login</button>
            <button className="btn ghost" onClick={() => setAdding(null)}>Cancel</button>
          </div>
        </div>
      )}

      <div className="card">
        <div className="tablewrap">
          <table className="data team">
            <thead><tr><th>Name</th><th>Login</th><th>Role</th><th>Status</th><th>Last sign-in</th><th>Still holds</th><th /></tr></thead>
            <tbody>
              {current.map((m) => {
                const self = m.id === me
                const typed = names[m.id]
                const renamed = typed !== undefined && typed.trim() !== '' && typed.trim() !== m.name
                const held = holds(m)
                const open = panel?.id === m.id ? panel : null
                return (
                  <Fragment key={m.id}>
                    <tr className={m.active ? '' : 'inactive'}>
                      <td>
                        <div className="formrow">
                          <input style={{ width: 160 }} value={typed ?? m.name} aria-label={`Name of ${m.name}`}
                            onChange={(e) => setNames({ ...names, [m.id]: e.target.value })}
                            onKeyDown={(e) => { if (e.key === 'Enter' && renamed) change(m, { p_name: typed }, 'Renamed') }} />
                          {renamed && <button className="btn ghost" disabled={busy} onClick={() => change(m, { p_name: typed }, 'Renamed')}>save</button>}
                        </div>
                        {self && <span className="muted small">you</span>}
                      </td>
                      <td className="small">
                        {m.email ?? '—'}{' '}
                        <button className="copybtn" onClick={() => setPanel({ kind: 'email', id: m.id, email: m.email ?? '' })}>change</button>
                      </td>
                      <td>
                        <select value={m.role} disabled={self || busy} onChange={(e) => setRole(m, e.target.value)}
                          title={self ? 'You can’t change your own role: ask another manager' : undefined}>
                          <option value="agent">Agent</option>
                          <option value="manager">Manager</option>
                        </select>
                      </td>
                      <td>
                        <span className={`tag ${m.active ? 'hot' : 'off'}`}>{m.active ? 'active' : 'off the floor'}</span>
                        {!self && (
                          <button className="btn ghost" disabled={busy} onClick={() => setActive(m, !m.active)}>
                            {m.active ? 'take off' : 'bring back'}
                          </button>
                        )}
                      </td>
                      <td className="small">{ago(m.last_sign_in_at)}</td>
                      <td className="small">
                        {held ? (
                          <>
                            <span className={m.active ? 'muted' : 'warnline'}>{held}</span>{' '}
                            <button className="copybtn" disabled={busy} onClick={() => handBack(m)} title="Callbacks back to the queue, lists shared with everyone">hand back</button>
                          </>
                        ) : <span className="muted">—</span>}
                      </td>
                      <td className="rowactions">
                        <button className="btn ghost" onClick={() => setPanel({ kind: 'password', id: m.id, own: false, typed: '' })}>reset password</button>
                        {!self && <button className="btn ghost" onClick={() => setPanel({ kind: 'remove', id: m.id, handBack: !!held })}>remove</button>}
                      </td>
                    </tr>
                    {open && (
                      <tr className="composerrow">
                        <td colSpan={7}>
                          {open.kind === 'remove' && (
                            <div className="panelbody">
                              {m.has_history ? (
                                <p style={{ margin: 0 }}>
                                  <b>Remove {m.name}?</b> They can’t sign in any more and come off the floor. Their calls and
                                  records stay in every report, and you can restore them from the Removed list.
                                </p>
                              ) : (
                                <p style={{ margin: 0 }}><b>Delete {m.name}’s login?</b> Nothing is on file for them yet, so nothing else is lost.</p>
                              )}
                              {held && (
                                <label className="radio">
                                  <input type="checkbox" checked={open.handBack} onChange={(e) => setPanel({ ...open, handBack: e.target.checked })} />
                                  Hand their {held} back to the team
                                </label>
                              )}
                              <div className="actionrow">
                                <button className="btn danger" disabled={busy} onClick={() => confirmPanel(m)}>{m.has_history ? `Remove ${m.name}` : 'Delete login'}</button>
                                <button className="btn ghost" onClick={() => setPanel(null)}>Cancel</button>
                              </div>
                            </div>
                          )}
                          {open.kind === 'password' && (
                            <div className="panelbody">
                              <p style={{ margin: 0 }}><b>New password for {m.name}.</b> Their old one stops working.</p>
                              <div className="formrow" style={{ alignItems: 'center' }}>
                                <label className="radio"><input type="radio" checked={!open.own} onChange={() => setPanel({ ...open, own: false })} /> Generate one</label>
                                <label className="radio"><input type="radio" checked={open.own} onChange={() => setPanel({ ...open, own: true })} /> I’ll set it</label>
                                {open.own && <input type="text" placeholder="8+ characters" value={open.typed} onChange={(e) => setPanel({ ...open, typed: e.target.value })} />}
                              </div>
                              <div className="actionrow">
                                <button className="btn primary" disabled={busy} onClick={() => confirmPanel(m)}>Set password</button>
                                <button className="btn ghost" onClick={() => setPanel(null)}>Cancel</button>
                              </div>
                            </div>
                          )}
                          {open.kind === 'email' && (
                            <div className="panelbody">
                              <div className="formrow">
                                <label>{m.name} signs in as<input type="email" style={{ width: 280 }} value={open.email} autoFocus
                                  onChange={(e) => setPanel({ ...open, email: e.target.value })} /></label>
                                <button className="btn primary" disabled={busy} onClick={() => confirmPanel(m)}>Change email</button>
                                <button className="btn ghost" onClick={() => setPanel(null)}>Cancel</button>
                              </div>
                            </div>
                          )}
                        </td>
                      </tr>
                    )}
                  </Fragment>
                )
              })}
              {!current.length && !error && <tr><td colSpan={7} className="muted">Loading…</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      {removed.length > 0 && (
        <>
          <div className="sectionhead"><h3>Removed</h3><span className="muted small">can’t sign in; their calls stay in every report</span></div>
          <div className="card">
            <table className="data team">
              <tbody>
                {removed.map((m) => (
                  <tr key={m.id} className="inactive">
                    <td>{m.name}</td>
                    <td className="small">{m.email ?? '—'}</td>
                    <td className="small">last signed in {ago(m.last_sign_in_at)}</td>
                    <td className="rowactions"><button className="btn ghost" disabled={busy} onClick={() => restore(m)}>restore</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
      <p className="muted small">
        A manager can’t remove, demote or take themselves off the floor, so there is always an active manager.
      </p>
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
