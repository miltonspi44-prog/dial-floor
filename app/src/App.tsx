import { useEffect, useState } from 'react'
import { Routes, Route, NavLink, Navigate } from 'react-router-dom'
import type { Session } from '@supabase/supabase-js'
import { supabase, heartbeatOffline } from './lib/supabase'
import type { Profile } from './lib/types'
import Login from './pages/Login'
import Dial from './pages/Dial'
import Floor from './pages/Floor'
import Lists from './pages/Lists'
import Ledger from './pages/Ledger'
import Emails from './pages/Emails'
import Funnel from './pages/Funnel'

export default function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [profileFor, setProfileFor] = useState<string | null>(null) // user id the profile was fetched for
  const [ready, setReady] = useState(false)

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

  if (!ready) return null
  if (!session) return <Login />
  // The manager routes only exist once the role is known; routing before that
  // sent a manager who reloaded /lists (or /funnel, /ledger, /emails) to /dial.
  if (profileFor !== session.user.id) return null

  const isManager = profile?.role === 'manager'

  return (
    <>
      <header className="topnav">
        <span className="brand">Dial Floor</span>
        <nav>
          <NavLink to="/dial" className={({ isActive }) => (isActive ? 'active' : '')}>Dial</NavLink>
          <NavLink to="/floor" className={({ isActive }) => (isActive ? 'active' : '')}>Floor</NavLink>
          {isManager && <NavLink to="/funnel" className={({ isActive }) => (isActive ? 'active' : '')}>Funnel</NavLink>}
          {isManager && <NavLink to="/lists" className={({ isActive }) => (isActive ? 'active' : '')}>Lists</NavLink>}
          {isManager && <NavLink to="/ledger" className={({ isActive }) => (isActive ? 'active' : '')}>Handoffs</NavLink>}
          {isManager && <NavLink to="/emails" className={({ isActive }) => (isActive ? 'active' : '')}>Emails</NavLink>}
        </nav>
        <div className="userbox">
          <span>{profile?.name ?? '…'}{isManager ? ' · manager' : ''}</span>
          <button className="btn ghost" onClick={() => supabase.auth.signOut()}>Sign out</button>
        </div>
      </header>
      <Routes>
        <Route path="/dial" element={<Dial profile={profile} />} />
        <Route path="/floor" element={<Floor isManager={isManager} />} />
        {isManager && <Route path="/funnel" element={<Funnel />} />}
        {isManager && <Route path="/lists" element={<Lists />} />}
        {isManager && <Route path="/ledger" element={<Ledger />} />}
        {isManager && <Route path="/emails" element={<Emails />} />}
        <Route path="*" element={<Navigate to="/dial" replace />} />
      </Routes>
    </>
  )
}
