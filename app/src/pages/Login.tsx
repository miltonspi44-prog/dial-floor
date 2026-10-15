import { useState } from 'react'
import { supabase } from '../lib/supabase'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true); setErr(null)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) setErr(error.message)
    setBusy(false)
  }

  return (
    <div className="loginwrap">
      <form className="loginbox card" onSubmit={submit}>
        <h1>Dial Floor</h1>
        <p className="muted small" style={{ margin: 0 }}>Sign in with the account your manager created for you.</p>
        <label htmlFor="login-email" className="small" style={{ fontWeight: 600 }}>Email</label>
        <input id="login-email" type="email" autoComplete="email" placeholder="you@company.com" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus required />
        <label htmlFor="login-password" className="small" style={{ fontWeight: 600 }}>Password</label>
        <input id="login-password" type="password" autoComplete="current-password" placeholder="password" value={password} onChange={(e) => setPassword(e.target.value)} required />
        {err && <div className="small" style={{ color: 'var(--bad)' }}>{err}</div>}
        <button className="btn primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
      </form>
    </div>
  )
}
