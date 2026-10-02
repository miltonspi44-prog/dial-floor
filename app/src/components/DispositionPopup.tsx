import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { CONNECTED_DISPOSITIONS, talkTime } from '../lib/types'

interface Props {
  leadName: string
  /** The lead's IANA timezone: callback times are entered on the lead's clock. */
  tz: string | null
  /** The call being logged: a referral hangs off it (G6). */
  attemptId: number | null
  /** The lead's area, the default for a referral's. */
  city: string | null
  state: string | null
  /** Zoom said the call ended after this many seconds (26): shown, so the agent
   *  knows the popup opened itself and only the outcome is left. */
  endedSec?: number | null
  onPick: (code: string, args: Record<string, unknown>) => void
  onClose: () => void
}

// the database falls back to the same zone when a lead has none
const FALLBACK_TZ = 'America/New_York'

/** The lead's zone if the browser knows it (a bad value would crash Intl). */
function validTz(tz: string | null): string {
  try {
    if (tz) { new Intl.DateTimeFormat('en-US', { timeZone: tz }); return tz }
  } catch { /* unknown zone: fall back */ }
  return FALLBACK_TZ
}

function partsIn(tz: string, d: Date) {
  const p = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23', weekday: 'short',
  }).formatToParts(d)
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? ''
  return { y: g('year'), m: g('month'), d: g('day'), hh: g('hour'), mm: g('minute'), wd: g('weekday') }
}
/** This moment on the lead's clock, as a datetime-local value. */
function localValue(tz: string, d: Date): string {
  const x = partsIn(tz, d)
  return `${x.y}-${x.m}-${x.d}T${x.hh}:${x.mm}`
}
/** N days ahead at hh:mm on the lead's clock. */
function dayAt(tz: string, daysAhead: number, hhmm: string): string {
  const x = partsIn(tz, new Date(Date.now() + daysAhead * 86400e3))
  return `${x.y}-${x.m}-${x.d}T${hhmm}`
}
function nextMondayAt(tz: string, hhmm: string): string {
  for (let i = 1; i <= 7; i++) if (partsIn(tz, new Date(Date.now() + i * 86400e3)).wd === 'Mon') return dayAt(tz, i, hhmm)
  return dayAt(tz, 7, hhmm)
}
/** Tomorrow 10:00 on the lead's clock, as a datetime-local value. */
function defaultCallback(tz: string): string {
  return dayAt(tz, 1, '10:00')
}
/** 4pm on the lead's clock — today if it is still ahead, else tomorrow. */
function afterFour(tz: string): string {
  const today = dayAt(tz, 0, '16:00')
  return today > localValue(tz, new Date()) ? today : dayAt(tz, 1, '16:00')
}
/** The 8:00–8:30pm window, approximately: a time outside it waits for the window. */
function outsideWindow(v: string): boolean {
  if (!v || v.length < 16) return false
  const h = Number(v.slice(11, 13)) + Number(v.slice(14, 16)) / 60
  return h < 8 || h > 20.5
}

const NO_REFERRAL = { name: '', phone: '', trade: '', city: '', state: '', note: '' }

/** Shown only when a human answered. One keystroke — or one big click. */
export default function DispositionPopup({ leadName, tz, attemptId, city, state, endedSec, onPick, onClose }: Props) {
  const leadTz = validTz(tz)
  const [pending, setPending] = useState<(typeof CONNECTED_DISPOSITIONS)[number] | null>(null)
  const [note, setNote] = useState('')
  const [dueAt, setDueAt] = useState(() => defaultCallback(leadTz))
  // 30: "he's back after four" — their four o'clock; empty means the queue's default day
  const [retryAt, setRetryAt] = useState('')
  const [email, setEmail] = useState('')
  const boxRef = useRef<HTMLDivElement>(null)
  const [summary, setSummary] = useState('')
  const [rating, setRating] = useState(0)
  // G6: "talk to my buddy who does gutters"
  const [referring, setReferring] = useState(false)
  const [ref, setRef] = useState({ ...NO_REFERRAL, city: city ?? '', state: state ?? '' })
  const [refBusy, setRefBusy] = useState(false)
  const [refError, setRefError] = useState<string | null>(null)
  const [referred, setReferred] = useState<string[]>([])

  const refDigits = ref.phone.replace(/\D/g, '').replace(/^1(?=\d{10}$)/, '')
  const refReady = ref.name.trim() !== '' && refDigits.length === 10

  function choose(opt: (typeof CONNECTED_DISPOSITIONS)[number]) {
    if (opt.needs) { setPending(opt); return }
    onPick(opt.code, note ? { note } : {})
  }

  function saveFollowup() {
    if (!pending) return
    const args: Record<string, unknown> = note ? { note } : {}
    if (pending.needs === 'callback') {
      // wall-clock time on the lead's side; the database reads it in the lead's timezone
      if (!dueAt) return
      args.due_local = dueAt
    }
    if (pending.needs === 'email') {
      if (!email.includes('@')) return
      args.email = email.trim()
    }
    if (pending.needs === 'retry' && retryAt) {
      // wall-clock time on the lead's side, like the callback's
      args.retry_local = retryAt
    }
    if (pending.needs === 'handoff') {
      args.summary = summary
      if (rating) args.rating = rating
    }
    onPick(pending.code, args)
  }

  async function saveReferral() {
    if (!attemptId || !refReady || refBusy) return
    setRefBusy(true)
    const { data, error } = await supabase.rpc('add_referral', {
      p_attempt_id: attemptId, p_name: ref.name.trim(), p_phone: refDigits,
      p_category: ref.trade.trim() || null, p_city: ref.city.trim() || null,
      p_state: ref.state.trim() || null, p_note: ref.note.trim() || null,
    })
    setRefBusy(false)
    if (error) { setRefError(error.message); return }
    const r = data as { name: string; created: boolean }
    setReferred((xs) => [...xs, r.created ? r.name : `${r.name} (already on file)`])
    setRef({ ...NO_REFERRAL, city: city ?? '', state: state ?? '' })
    setRefError(null)
    setReferring(false)
  }

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.repeat) return
      const target = e.target as HTMLElement
      const typing = target.tagName === 'TEXTAREA' || target.tagName === 'INPUT'
      if (referring) {
        if (e.key === 'Escape') { e.preventDefault(); setReferring(false) }
        else if (e.key === 'Enter' && target.tagName !== 'TEXTAREA') { e.preventDefault(); saveReferral() }
        return
      }
      if (e.key === 'Escape') { if (pending) setPending(null); else onClose(); return }
      if (typing) {
        if (e.key === 'Enter' && pending && target.tagName !== 'TEXTAREA') { e.preventDefault(); saveFollowup(); return }
        // Enter leaves the note box, so the digit keys log the call again (item 31)
        if (e.key === 'Enter' && !pending) { e.preventDefault(); target.blur() }
        return
      }
      if (pending) { if (e.key === 'Enter') { e.preventDefault(); saveFollowup() } return }
      const k = e.key.toUpperCase()
      if (k === 'R' && attemptId) { e.preventDefault(); setReferring(true); return }
      const opt = CONNECTED_DISPOSITIONS.find((o) => o.key === k)
      if (opt) { e.preventDefault(); choose(opt) }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  useEffect(() => { boxRef.current?.focus() }, [])
  function trapTab(e: React.KeyboardEvent) {
    if (e.key !== 'Tab' || !boxRef.current) return
    const els = boxRef.current.querySelectorAll<HTMLElement>('button, input, textarea, select, a[href]')
    if (!els.length) return
    const first = els[0]
    const last = els[els.length - 1]
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus() }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus() }
  }

  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="popup" ref={boxRef} tabIndex={-1} role="dialog" aria-modal="true"
        aria-label={`Call outcome — ${leadName}`} onKeyDown={trapTab}>
        {!pending && !referring && (
          <>
            <h3>Call outcome — {leadName}</h3>
            {endedSec != null && (
              <div className="refsaved">
                Zoom: the call ended{endedSec > 0 ? <> · <b>{talkTime(endedSec)}</b> on the line</> : null} — pick how it went.
              </div>
            )}
            {referred.length > 0 && (
              <div className="refsaved">
                Referral saved: <b>{referred.join(', ')}</b>. It's first on your list; now log how this call ended.
              </div>
            )}
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
            {attemptId && (
              <div className="actionrow" style={{ marginTop: 10 }}>
                <button className="btn" onClick={() => setReferring(true)}>
                  <span className="kbd">R</span> They referred someone
                </button>
                <span className="muted small">saves a new lead for you to call; you still pick how this call ended</span>
              </div>
            )}
          </>
        )}

        {referring && (
          <>
            <h3>Referral from {leadName}</h3>
            <p className="muted small" style={{ marginTop: 0 }}>
              They become a lead marked as a warm referral, first on your own list. A number on the do-not-call list is refused.
            </p>
            <div className="followup">
              <div className="refgrid">
                <label>Who<input autoFocus value={ref.name} onChange={(e) => setRef({ ...ref, name: e.target.value })} placeholder="Mike, Mike's Gutters" /></label>
                <label>Phone<input value={ref.phone} onChange={(e) => setRef({ ...ref, phone: e.target.value })} placeholder="(555) 123-4567" inputMode="tel" /></label>
                <label>Trade<input value={ref.trade} onChange={(e) => setRef({ ...ref, trade: e.target.value })} placeholder="gutters" /></label>
                <label>City<input value={ref.city} onChange={(e) => setRef({ ...ref, city: e.target.value })} /></label>
                <label>State<input value={ref.state} onChange={(e) => setRef({ ...ref, state: e.target.value })} maxLength={2} style={{ width: 70 }} /></label>
              </div>
              <label htmlFor="ref-note">What they said</label>
              <input id="ref-note" value={ref.note} onChange={(e) => setRef({ ...ref, note: e.target.value })} placeholder="his cousin, mention Joe; call after 3" />
              {refError && <div className="warnline">{refError}</div>}
              <div className="actionrow">
                <button className="btn primary" onClick={saveReferral} disabled={!refReady || refBusy}>Save referral <span className="kbd">Enter</span></button>
                <button className="btn ghost" onClick={() => setReferring(false)}>Back <span className="kbd">Esc</span></button>
                {ref.phone && refDigits.length !== 10 && <span className="muted small">a 10-digit number</span>}
              </div>
            </div>
          </>
        )}

        {pending?.needs === 'callback' && (
          <>
            <h3>Callback — when did they say?</h3>
            <div className="followup">
              <div className="actionrow">
                <button className="btn" onClick={() => setDueAt(localValue(leadTz, new Date(Date.now() + 3600e3)))}>In 1 hour</button>
                <button className="btn" onClick={() => setDueAt(dayAt(leadTz, 1, '10:00'))}>Tomorrow 10am</button>
                <button className="btn" onClick={() => setDueAt(nextMondayAt(leadTz, '09:00'))}>Monday 9am</button>
              </div>
              <label htmlFor="cb-when">Their local date &amp; time</label>
              <input id="cb-when" type="datetime-local" value={dueAt} min={localValue(leadTz, new Date())}
                onChange={(e) => setDueAt(e.target.value)} autoFocus />
              {outsideWindow(dueAt) && (
                <span className="warnline">Outside the calling window (8:00 am – 8:30 pm their time) — the queue holds it until the window opens.</span>
              )}
              <span className="muted small">
                For them it's {new Intl.DateTimeFormat('en-US', { timeZone: leadTz, weekday: 'short', hour: 'numeric', minute: '2-digit' }).format(new Date())} now ({leadTz.replace(/_/g, ' ')})
              </span>
              <label htmlFor="cb-note">Note</label>
              <input id="cb-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="who to ask for, context…" />
              <div className="actionrow">
                <button className="btn primary" onClick={saveFollowup}>Save callback <span className="kbd">Enter</span></button>
                <button className="btn ghost" onClick={() => setPending(null)}>Back</button>
              </div>
            </div>
          </>
        )}

        {pending?.needs === 'retry' && (
          <>
            <h3>Decision maker not in — when are they back?</h3>
            <div className="followup">
              <div className="actionrow">
                <button className="btn" onClick={() => setRetryAt(afterFour(leadTz))}>After 4, their time</button>
                <button className="btn" onClick={() => setRetryAt(dayAt(leadTz, 1, '10:00'))}>Tomorrow 10am</button>
              </div>
              <label htmlFor="rt-when">Their local date &amp; time</label>
              <input id="rt-when" type="datetime-local" value={retryAt} min={localValue(leadTz, new Date())}
                onChange={(e) => setRetryAt(e.target.value)} autoFocus />
              <span className="muted small">Didn't say? Leave it empty — the queue tries again tomorrow.</span>
              <label htmlFor="rt-note">Note</label>
              <input id="rt-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="ask for the owner; back after lunch" />
              <div className="actionrow">
                <button className="btn primary" onClick={saveFollowup}>Save <span className="kbd">Enter</span></button>
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
