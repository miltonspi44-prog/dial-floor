import { lazy, Suspense, useEffect, useState } from 'react'
import { Routes, Route, NavLink, Navigate } from 'react-router-dom'
import type { Session } from '@supabase/supabase-js'
import { supabase, heartbeatOffline } from './lib/supabase'
import type { Profile } from './lib/types'
import Login from './pages/Login'
import Dial from './pages/Dial'

// Item 55: an agent's day is the Dial page, so that is the whole first load;
// every other page — the floor board included — arrives as its own chunk.
const Floor = lazy(() => import('./pages/Floor'))
const Coaching = lazy(() => import('./pages/Coaching'))
const LeadsHub = lazy(() => import('./pages/LeadsHub'))
const ReportsHub = lazy(() => import('./pages/ReportsHub'))
const Playbook = lazy(() => import('./pages/Playbook'))
const Users = lazy(() => import('./pages/Users'))
const Settings = lazy(() => import('./pages/Settings'))

const lazyFallback = <div className="page"><div className="emptystate">Loading…</div></div>

export default function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [profileFor, setProfileFor] = useState<string | null>(null) // user id the profile was fetched for
  const [ready, setReady] = useState(false)
  const [stale, setStale] = useState(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setReady(true)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) { setProfile(null); setProfileFor(null); return }
    const uid = session.user.id
    supabase.from('profiles').select('*').eq('id', uid).single()
      .then(({ data }) => { setProfile(data as Profile | null); setProfileFor(uid) })
  }, [session])

  // "still here" every minute: a tab that crashed or lost its connection stops,
  // and the floor board shows that agent offline instead of dialing forever
  useEffect(() => {
    if (!session) return
    const iv = window.setInterval(() => { supabase.rpc('heartbeat', { p_status: 'ping' }).then(() => {}) }, 60_000)
    return () => window.clearInterval(iv)
  }, [session])

  useEffect(() => {
    if (!session) return
    // pagehide, not beforeunload: opening zoomphonecall:// fires beforeunload
    // without leaving the page, which marked every dialing agent offline.
    const bye = () => heartbeatOffline(session.access_token)
    window.addEventListener('pagehide', bye)
    return () => window.removeEventListener('pagehide', bye)
  }, [session])

  // Item 54: an all-day tab learns a new build shipped and offers one reload.
  useEffect(() => {
    const current = document.querySelector<HTMLScriptElement>('script[type="module"][src*="/assets/"]')?.src ?? ''
    if (!current) return
    let stop = false
    async function check() {
      try {
        const html = await (await fetch('/index.html', { cache: 'no-store' })).text()
        const m = html.match(/\/assets\/index-[\w-]+\.js/)
        if (!stop && m && !current.endsWith(m[0])) setStale(true)
      } catch { /* offline: nothing to say */ }
    }
    const iv = window.setInterval(check, 10 * 60_000)
    const onShow = () => { if (!document.hidden) check() }
    document.addEventListener('visibilitychange', onShow)
    return () => { stop = true; window.clearInterval(iv); document.removeEventListener('visibilitychange', onShow) }
  }, [])

  if (!ready) return null
  if (!session) return <Login />
  // The manager routes only exist once the role is known; routing before that
  // sent a manager who reloaded a manager page to /dial.
  if (profileFor !== session.user.id) return null

  const isManager = profile?.role === 'manager'

  return (
    <>
      <header className="topnav">
        <span className="brand">Dial Floor</span>
        <nav>
          <NavLink to="/dial" className={({ isActive }) => (isActive ? 'active' : '')}>Dial</NavLink>
          <NavLink to="/floor" className={({ isActive }) => (isActive ? 'active' : '')}>Floor</NavLink>
          {!isManager && <NavLink to="/coaching" className={({ isActive }) => (isActive ? 'active' : '')}>Coaching</NavLink>}
          {isManager && <NavLink to="/leads" className={({ isActive }) => (isActive ? 'active' : '')}>Leads</NavLink>}
          {isManager && <NavLink to="/reports" className={({ isActive }) => (isActive ? 'active' : '')}>Reports</NavLink>}
          {isManager && <NavLink to="/playbook" className={({ isActive }) => (isActive ? 'active' : '')}>Playbook</NavLink>}
          {isManager && <NavLink to="/team" className={({ isActive }) => (isActive ? 'active' : '')}>Team</NavLink>}
          {isManager && <NavLink to="/settings" className={({ isActive }) => (isActive ? 'active' : '')}>Settings</NavLink>}
        </nav>
        <div className="userbox">
          <span>{profile?.name ?? '…'}{isManager ? ' · manager' : ''}</span>
          <button className="btn ghost" onClick={async () => {
            // the tile goes offline now, not five quiet minutes from now
            try { await supabase.rpc('heartbeat', { p_status: 'offline' }) } catch { /* signing out anyway */ }
            supabase.auth.signOut()
          }}>Sign out</button>
        </div>
      </header>
      {stale && (
        <div className="updatebar" role="status">
          A new version of the app shipped. <button className="btn small" onClick={() => window.location.reload()}>Reload</button>
        </div>
      )}
      <Suspense fallback={lazyFallback}>
        <Routes>
          <Route path="/dial" element={<Dial profile={profile} />} />
          <Route path="/floor" element={<Floor isManager={isManager} me={session.user.id} />} />
          <Route path="/coaching" element={<Coaching profile={profile} />} />
          {isManager && <Route path="/leads" element={<LeadsHub myName={profile?.name ?? ''} />} />}
          {isManager && <Route path="/reports" element={<ReportsHub profile={profile} />} />}
          {isManager && <Route path="/playbook" element={<Playbook />} />}
          {isManager && <Route path="/team" element={<Users me={session.user.id} />} />}
          {isManager && <Route path="/settings" element={<Settings />} />}
          {/* the old addresses still arrive somewhere sensible */}
          {isManager && <Route path="/radar" element={<Navigate to="/leads" replace />} />}
          {isManager && <Route path="/lists" element={<Navigate to="/leads" replace />} />}
          {isManager && <Route path="/emails" element={<Navigate to="/leads" replace />} />}
          {isManager && <Route path="/funnel" element={<Navigate to="/reports" replace />} />}
          {isManager && <Route path="/ledger" element={<Navigate to="/reports" replace />} />}
          {isManager && <Route path="/users" element={<Navigate to="/team" replace />} />}
          <Route path="*" element={<Navigate to="/dial" replace />} />
        </Routes>
      </Suspense>
    </>
  )
}
