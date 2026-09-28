import { useEffect, useState } from 'react'
import { CONNECTED_DISPOSITIONS } from '../lib/types'

interface Props {
  leadName: string
  onPick: (code: string, args: Record<string, unknown>) => void
  onClose: () => void
}

/** Shown only when a human answered. One keystroke — or one big click. */
export default function DispositionPopup({ leadName, onPick, onClose }: Props) {
  const [pending, setPending] = useState<(typeof CONNECTED_DISPOSITIONS)[number] | null>(null)
  const [note, setNote] = useState('')
  const [dueAt, setDueAt] = useState(defaultCallback())
  const [email, setEmail] = useState('')
  const [summary, setSummary] = useState('')
  const [rating, setRating] = useState(0)

  function defaultCallback() {
    const d = new Date(Date.now() + 24 * 3600 * 1000)
    d.setMinutes(0, 0, 0); d.setHours(10)
    const pad = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
  }

  function choose(opt: (typeof CONNECTED_DISPOSITIONS)[number]) {
    if (opt.needs) { setPending(opt); return }
    onPick(opt.code, note ? { note } : {})
  }

  function saveFollowup() {
    if (!pending) return
    const args: Record<string, unknown> = note ? { note } : {}
    if (pending.needs === 'callback') args.due_at = new Date(dueAt).toISOString()
    if (pending.needs === 'email') {
      if (!email.includes('@')) return
      args.email = email.trim()
    }
    if (pending.needs === 'handoff') {
      args.summary = summary
      if (rating) args.rating = rating
    }
    onPick(pending.code, args)
  }

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') { pending ? setPending(null) : onClose(); return }
      const target = e.target as HTMLElement
      if (target.tagName === 'TEXTAREA' || target.tagName === 'INPUT') {
        if (e.key === 'Enter' && pending && target.tagName !== 'TEXTAREA') { e.preventDefault(); saveFollowup() }
        return
      }
      if (pending) { if (e.key === 'Enter') { e.preventDefault(); saveFollowup() } return }
      const k = e.key.toUpperCase()
      const opt = CONNECTED_DISPOSITIONS.find((o) => o.key === k)
      if (opt) { e.preventDefault(); choose(opt) }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="popup">
        {!pending && (
          <>
            <h3>Call outcome — {leadName}</h3>
            <div className="dispgrid">
              {CONNECTED_DISPOSITIONS.map((o) => (
                <button
                  key={o.code}
                  className={`dispbtn ${o.needs === 'handoff' ? 'exit' : ''} ${o.code === 'dnc' ? 'dncbtn' : ''}`}
                  onClick={() => choose(o)}
                >
                  <span className="kbd">{o.key}</span>
                  <span>
                    {o.label}
                    {o.hint && <span className="hint">{o.hint}</span>}
                  </span>
                </button>
              ))}
            </div>
            <div className="followup">
              <label htmlFor="disp-note">Note (optional)</label>
              <input id="disp-note" value={note} onChange={(e) => setNote(e.target.value)}
                placeholder="anything worth remembering" />
            </div>
          </>
        )}

        {pending?.needs === 'callback' && (
          <>
            <h3>Callback — when did they say?</h3>
            <div className="followup">
              <label htmlFor="cb-when">Their local date &amp; time</label>
              <input id="cb-when" type="datetime-local" value={dueAt} onChange={(e) => setDueAt(e.target.value)} autoFocus />
              <label htmlFor="cb-note">Note</label>
              <input id="cb-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="who to ask for, context…" />
              <div className="actionrow">
                <button className="btn primary" onClick={saveFollowup}>Save callback <span className="kbd">Enter</span></button>
                <button className="btn ghost" onClick={() => setPending(null)}>Back</button>
              </div>
            </div>
          </>
        )}

        {pending?.needs === 'email' && (
          <>
            <h3>Email requested</h3>
            <div className="followup">
              <label htmlFor="em-addr">Their email</label>
              <input id="em-addr" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus placeholder="owner@business.com" />
              <label htmlFor="em-note">Note</label>
              <input id="em-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="what they want to see" />
              <div className="actionrow">
                <button className="btn primary" onClick={saveFollowup} disabled={!email.includes('@')}>Queue email <span className="kbd">Enter</span></button>
                <button className="btn ghost" onClick={() => setPending(null)}>Back</button>
              </div>
            </div>
          </>
        )}

        {pending?.needs === 'handoff' && (
          <>
            <h3>{pending.code === 'chance_website' ? 'Chance given — website' : 'Sale closed — SEO / receptionist'}</h3>
            <p className="muted small" style={{ marginTop: 0 }}>
              This lead leaves the dialer for good: it goes to the handoff ledger and the internal do-not-call list.
            </p>
            <div className="followup">
              <label htmlFor="ho-sum">What was said / agreed</label>
              <textarea id="ho-sum" rows={3} value={summary} onChange={(e) => setSummary(e.target.value)} autoFocus
                placeholder="what they agreed to, what to build, anything the next step needs" />
              <label>Lead quality rating</label>
              <div className="ratingrow">
                {[1, 2, 3, 4, 5].map((n) => (
                  <button key={n} className={rating === n ? 'sel' : ''} onClick={() => setRating(n)}>{n}</button>
                ))}
              </div>
              <div className="actionrow">
                <button className="btn primary" onClick={saveFollowup}>Hand off <span className="kbd">Enter</span></button>
                <button className="btn ghost" onClick={() => setPending(null)}>Back</button>
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
