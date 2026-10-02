import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase, fmtPhone, zoomDial, loadTargets } from '../lib/supabase'
import { BREAK_REASONS, breakLabel, dispositionLabel, hourLabel, talkTime } from '../lib/types'
import type { BestTimes, BreakReason, LeadRow, NextLeadResult, Pace, Profile, Pulse, Targets } from '../lib/types'
import DispositionPopup from '../components/DispositionPopup'
import Battlecards from '../components/Battlecards'
import SprintBanner from '../components/SprintBanner'

type Phase = 'loading' | 'ready' | 'dialing' | 'empty' | 'paused'

/** What the webhook writes on the attempt; the page listens for it (item 26). */
type AttemptLite = {
  id?: number
  disposition: string | null
  auto_logged: boolean
  call_result: string | null
  duration_seconds: number | null
}

type MyCb = { due_at: string; tries: number; leads: { name: string; tz: string | null } | null }

/** An outcome the connection dropped waits here and is sent on the next load (item 34). */
const PENDING_KEY = 'df-pending-outcome'

const REASON_LABEL: Record<string, string> = {
  callback_due: 'CALLBACK DUE — they asked for this call',
  list: 'From your list',
  pool: 'From the pool',
  resume: 'CALL STILL OPEN — log how it went',
}

function addressLine(l: LeadRow): string {
  if (l.address) return l.address
  return [l.addr_city, [l.addr_state, l.zip].filter(Boolean).join(' ')].filter(Boolean).join(', ')
}

function Stat({ label, value, target }: { label: string; value: number; target: number | null | undefined }) {
  return <span className="statchip">{label} <b>{value}</b>{target ? <span className="of"> / {target}</span> : null}</span>
}

/** Dials and talk per active hour against the target's hourly share (A4). */
function PaceChips({ pace }: { pace: Pace | null }) {
  if (!pace || pace.dials_per_hour == null) {
    return pace?.dials ? <span className="statchip" title="Rates settle after the first quarter hour">Pace <b>…</b></span> : null
  }
  const behind = pace.target_per_hour != null && pace.dials_per_hour < 0.8 * pace.target_per_hour
  return (
    <>
      <span className={`statchip ${behind ? 'behind' : ''}`}
        title={pace.target_per_hour ? `${pace.target} a day over a ${pace.shift_hours}-hour shift is ${pace.target_per_hour} an hour` : 'dials per active hour today'}>
        Pace <b>{Math.round(pace.dials_per_hour)}</b>/hr{pace.target_per_hour ? <span className="of"> · need {Math.ceil(pace.target_per_hour)}</span> : null}
      </span>
      {pace.talk_minutes_per_hour != null && (
        <span className="statchip" title="minutes on answered calls per active hour">Talk <b>{Math.round(pace.talk_minutes_per_hour)}</b> min/hr</span>
      )}
    </>
  )
}

/** "0:07" */
function clock(sec: number): string {
  const s = Math.max(0, Math.round(sec))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

/** The hour of day on the lead's clock, 0–23. */
function localHour(tz: string | null): number | null {
  try {
    return Number(new Intl.DateTimeFormat('en-US', { hour: 'numeric', hourCycle: 'h23', timeZone: tz ?? 'America/New_York' }).format(new Date()))
  } catch { return null }
}

/** C6: the lead's trade's best hours on their clock, once the model has the data. */
function bestHint(b: BestTimes | null, lead: LeadRow): string | null {
  if (!b?.ready) return null
  const key = (lead.category_key ?? '').split(',')[0] || '(none)'
  const t = b.trades.find((x) => x.trade === key)
  if (!t?.cells.length) return null
  const pct = (r: number) => `${Math.round(r * 100)}%`
  const now = t.cells.find((c) => c.hour === localHour(lead.tz))
  const trade = (t.label ?? key.replace(/_/g, ' ')).toLowerCase()
  return `Best hours for ${trade}: ${t.cells.slice(0, 2).map((c) => `${hourLabel(c.hour)} (${pct(c.rate)} pick up)`).join(', ')} their time, vs ${pct(t.rate)} all day${now ? `; this hour ${pct(now.rate)}` : ''}`
}

export default function Dial({ profile }: { profile: Profile | null }) {
  const [ws, setWs] = useState<NextLeadResult | null>(null)
  const [phase, setPhase] = useState<Phase>('loading')
  const [attemptId, setAttemptId] = useState<number | null>(null)
  const [popup, setPopup] = useState(false)
  const [vmAsk, setVmAsk] = useState(false)
  const [callSec, setCallSec] = useState(0)
  const [pace, setPace] = useState<Pace | null>(null)
  const [targets, setTargets] = useState<Targets | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  // A4: the wrap-up countdown after a logged call, and pausing with a reason
  const [wrapAt, setWrapAt] = useState<number | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const [pauseOpen, setPauseOpen] = useState(false)
  const [pauseOther, setPauseOther] = useState(false)
  const [pauseNote, setPauseNote] = useState('')
  // E5 + E4: the race and the bell; C6: the best-time model
  const [pulse, setPulse] = useState<Pulse | null>(null)
  const [best, setBest] = useState<BestTimes | null>(null)
  // 26: the call's end, straight from Zoom
  const [endedSec, setEndedSec] = useState<number | null>(null)
  // 29: the agent's own scheduled callbacks, in one glance
  const [myCbs, setMyCbs] = useState<MyCb[]>([])
  const timerRef = useRef<number | null>(null)
  const toastRef = useRef<number | null>(null)
  const wrapIdleSent = useRef(false)
  const seenWins = useRef<Set<string> | null>(null)
  const autoHandled = useRef<number | null>(null)

  const lead = ws?.lead

  function setToastMsg(m: string, ms = 2500) {
    setToast(m)
    if (toastRef.current) window.clearTimeout(toastRef.current)
    toastRef.current = window.setTimeout(() => setToast(null), ms)
  }

  const refreshPace = useCallback(() => {
    supabase.rpc('my_pace').then(({ data }) => { if (data) setPace(data as Pace) })
  }, [])

  const refreshPulse = useCallback(() => {
    supabase.rpc('floor_pulse').then(({ data }) => {
      const p = data as Pulse | null
      if (!p) return
      setPulse(p)
      // a teammate's win rings once; wins already on the board when the page opened don't
      const fresh = seenWins.current ? p.wins.filter((w) => !seenWins.current!.has(w.key)) : []
      seenWins.current = new Set([...(seenWins.current ?? []), ...p.wins.map((w) => w.key)])
      if (fresh.length) setToastMsg(`Bell! ${fresh[0].title}: ${fresh[0].detail}`, 7000)
    })
  }, [])

  const applyResult = useCallback((res: NextLeadResult | null) => {
    setPopup(false); setVmAsk(false); setEndedSec(null); stopTimer()
    setWs(res)
    if (!res || res.empty || res.error || !res.lead) {
      setAttemptId(null); setPhase('empty')
    } else if (res.attempt_id) {
      // reloaded mid-call: pick the open call back up so its outcome gets logged
      setAttemptId(res.attempt_id); setPhase('dialing')
      startTimer(res.clicked_at ? Date.parse(res.clicked_at) : Date.now())
    } else {
      setAttemptId(null); setPhase('ready')
    }
  }, [])

  const loadNext = useCallback(async () => {
    setPhase('loading')
    setWrapAt(null)
    const { data, error } = await supabase.rpc('next_lead')
    if (error) { setToastMsg(error.message); setPhase('empty'); return }
    const res = data as NextLeadResult
    applyResult(res)
    // the tile tells the truth: a mid-call reload says on_call, not idle (item 32)
    supabase.rpc('heartbeat', { p_status: res?.attempt_id ? 'on_call' : 'idle' }).then(() => {})
  }, [applyResult])

  const refreshCbs = useCallback(() => {
    if (!profile?.id) { setMyCbs([]); return }
    supabase.from('callbacks').select('due_at, tries, leads(name, tz)')
      .eq('agent_id', profile.id).eq('status', 'scheduled')
      .order('due_at').limit(6)
      .then(({ data }) => setMyCbs((data ?? []) as unknown as MyCb[]))
  }, [profile?.id])

  useEffect(() => {
    // an outcome the connection dropped goes first (item 34): the queue must hear
    // how the call went before it decides what to serve
    let stash: { attemptId: number; code: string; args: Record<string, unknown> } | null = null
    try { const raw = localStorage.getItem(PENDING_KEY); if (raw) stash = JSON.parse(raw) } catch { stash = null }
    const sent = stash
      ? supabase.rpc('log_disposition', { p_attempt_id: stash.attemptId, p_dispo: stash.code, p_args: stash.args })
          .then(({ error }) => {
            if (!error || /already|not found|not your/i.test(error.message)) {
              try { localStorage.removeItem(PENDING_KEY) } catch { /* ignore */ }
              if (!error) setToastMsg('The outcome from before the connection dropped is saved.')
            }
          })
      : Promise.resolve()
    sent.then(() => {
      // a pause survives a reload: come back to it rather than to a lead
      supabase.rpc('my_pace').then(({ data }) => {
        const p = data as Pace | null
        if (p) setPace(p)
        if (p?.break) { setPhase('paused'); return }
        // the first Dial page of the business day runs the radar (it deals the
        // morning lists), so it goes before the first lead; later pages return at once.
        // loadNext reports the honest status itself: on_call on a resume, else idle.
        supabase.rpc('radar_daily').then(() => loadNext())
      })
    })
  }, [loadNext])

  useEffect(() => {
    loadTargets().then(setTargets)
    supabase.rpc('best_times').then(({ data }) => { if (data) setBest(data as BestTimes) })
  }, [])

  useEffect(() => { refreshCbs() }, [refreshCbs])

  // leaving the page stops the call clock with it (item 35)
  useEffect(() => () => { if (timerRef.current) window.clearInterval(timerRef.current) }, [])

  // the race, the bell and the pace rates, once a minute
  useEffect(() => {
    refreshPulse()
    const iv = window.setInterval(() => { refreshPulse(); refreshPace() }, 60_000)
    return () => window.clearInterval(iv)
  }, [refreshPulse, refreshPace])

  // a one-second clock while the wrap-up counts or a pause runs
  const ticking = (wrapAt != null && phase === 'ready') || phase === 'paused'
  useEffect(() => {
    if (!ticking) return
    const iv = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(iv)
  }, [ticking])

  const wrapSecs = pace?.wrapup_seconds ?? 0
  const wrapLeft = wrapAt != null && phase === 'ready' ? wrapSecs - (now - wrapAt) / 1000 : null
  // the countdown ran out: the floor board shows the agent ready (idle) again
  useEffect(() => {
    if (wrapLeft != null && wrapLeft <= 0 && !wrapIdleSent.current) {
      wrapIdleSent.current = true
      supabase.rpc('heartbeat', { p_status: 'idle' }).then(() => {})
    }
  }, [wrapLeft])

  // 26: Zoom's result lands on the attempt within seconds of the call ending.
  // The page listens and moves by itself: a no-answer advances with no keystroke,
  // a pickup opens the outcome popup the moment the call ends. The handler lives
  // on a ref so the channel subscribes once per call, not once per render; a slow
  // poll backs the socket up when realtime drops.
  const attemptEventRef = useRef<(row: AttemptLite) => void>(() => {})
  attemptEventRef.current = (row) => {
    if (!attemptId || (row.id != null && row.id !== attemptId)) return
    if (autoHandled.current === attemptId) return
    if (row.disposition && !row.auto_logged && row.disposition !== 'not_placed') {
      // settled elsewhere (a manager relogged it, another tab): nothing left here
      autoHandled.current = attemptId
      setToastMsg('This call was logged elsewhere - moving on.')
      loadNext()
      return
    }
    if (row.auto_logged && row.disposition === 'no_answer' && !popup && !vmAsk) {
      autoHandled.current = attemptId
      setToastMsg('Zoom: no answer - moving on.')
      log('no_answer')
      return
    }
    if (row.call_result === 'answered' && !popup && !vmAsk) {
      autoHandled.current = attemptId
      setEndedSec(row.duration_seconds ?? null)
      setPopup(true)
    }
  }

  useEffect(() => {
    if (phase !== 'dialing' || !attemptId) return
    autoHandled.current = null
    const ch = supabase.channel(`attempt-${attemptId}`)
      .on('postgres_changes',
          { event: 'UPDATE', schema: 'public', table: 'attempts', filter: `id=eq.${attemptId}` },
          (p) => attemptEventRef.current(p.new as AttemptLite))
      .subscribe()
    const iv = window.setInterval(async () => {
      const { data } = await supabase.from('attempts')
        .select('id, disposition, auto_logged, call_result, duration_seconds')
        .eq('id', attemptId).maybeSingle()
      if (data) attemptEventRef.current(data as AttemptLite)
    }, 8000)
    return () => { supabase.removeChannel(ch); window.clearInterval(iv) }
  }, [phase, attemptId])

  function stopTimer() {
    if (timerRef.current) { window.clearInterval(timerRef.current); timerRef.current = null }
    setCallSec(0)
  }
  function startTimer(t0: number) {
    stopTimer()
    const tick = () => setCallSec(Math.max(0, Math.round((Date.now() - t0) / 1000)))
    tick()
    timerRef.current = window.setInterval(tick, 1000)
  }

  async function dial() {
    if (!lead || busy) return
    setBusy(true)
    const { data, error } = await supabase.rpc('start_attempt', { p_lead_id: lead.id })
    setBusy(false)
    if (error) { setToastMsg(error.message); loadNext(); return }
    setWrapAt(null)
    setAttemptId((data as { attempt_id: number }).attempt_id)
    setPhase('dialing')
    startTimer(Date.now())
    zoomDial(lead.phone_norm)
  }

  async function log(code: string, args: Record<string, unknown> = {}) {
    if (!attemptId || busy) return
    setBusy(true)
    const { data, error } = await supabase.rpc('log_disposition', {
      p_attempt_id: attemptId, p_dispo: code, p_args: args,
    })
    setBusy(false)
    if (error) {
      // the connection went, not the call: keep the outcome on this device and
      // it goes first thing on the next load (item 34)
      if (/fetch|network|load failed/i.test(error.message)) {
        try { localStorage.setItem(PENDING_KEY, JSON.stringify({ attemptId, code, args })) } catch { /* full/blocked */ }
        setToastMsg('No connection - the outcome is saved on this device and goes out when the page reconnects.', 7000)
      } else {
        setToastMsg(error.message)
      }
      return
    }
    refreshPace()
    refreshCbs()
    const next = (data as { next: NextLeadResult }).next
    applyResult(next)
    // wrap-up: a visible countdown before the next dial. It never dials by itself
    if (wrapSecs > 0 && next?.lead && !next.attempt_id) {
      wrapIdleSent.current = false
      setNow(Date.now())
      setWrapAt(Date.now())
      supabase.rpc('heartbeat', { p_status: 'wrap' }).then(() => {})
    }
    if (code === 'chance_website' || code === 'sale_closed') refreshPulse()
  }

  async function skip() {
    if (!lead || busy) return
    setBusy(true)
    const { data, error } = await supabase.rpc('skip_lead', { p_lead_id: lead.id })
    setBusy(false)
    if (error) { setToastMsg(error.message); return }
    setWrapAt(null)
    applyResult((data as { next: NextLeadResult }).next)
  }

  function openPause() {
    setPauseOpen(true); setPauseOther(false); setPauseNote('')
  }

  async function pause(reason: BreakReason) {
    if (busy) return
    if (reason === 'other' && !pauseNote.trim()) { setPauseOther(true); return }
    setBusy(true)
    const { data, error } = await supabase.rpc('pause_work', { p_reason: reason, p_note: reason === 'other' ? pauseNote.trim() : null })
    setBusy(false)
    if (error) { setToastMsg(error.message); return }
    const b = data as { reason: BreakReason; note: string | null; started_at: string }
    setPace((p) => (p ? { ...p, break: { reason: b.reason, note: b.note, since: b.started_at } } : p))
    setPauseOpen(false); setPauseOther(false); setPauseNote('')
    setWrapAt(null); setWs(null); setNow(Date.now()); setPhase('paused')
  }

  async function resume() {
    if (busy) return
    setBusy(true)
    const { error } = await supabase.rpc('resume_work')
    setBusy(false)
    if (error) { setToastMsg(error.message); return }
    setPace((p) => (p ? { ...p, break: null } : p))
    refreshPace()
    loadNext()
  }

  // global keys (popup handles its own while open)
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      // a held key is one keystroke, not a stream of them (item 27)
      if (e.repeat) return
      if (popup) return
      const target = e.target as HTMLElement
      const typing = ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)
      if (pauseOpen) {
        if (e.key === 'Escape') { e.preventDefault(); setPauseOpen(false); return }
        if (typing) { if (e.key === 'Enter' && pauseOther) { e.preventDefault(); pause('other') } return }
        const r = BREAK_REASONS[Number(e.key) - 1]
        if (r) { e.preventDefault(); pause(r.key) }
        return
      }
      if (vmAsk) {
        const k = e.key.toUpperCase()
        if (k === 'Y') { e.preventDefault(); log('voicemail', { left_message: true }) }
        if (k === 'N') { e.preventDefault(); log('voicemail', { left_message: false }) }
        if (e.key === 'Escape') { e.preventDefault(); setVmAsk(false) }
        return
      }
      if (typing) return
      const k = e.key.toUpperCase()
      if (phase === 'ready') {
        // D only: Enter used to dial the next lead unseen when held through a save (item 27)
        if (k === 'D') { e.preventDefault(); dial() }
        if (k === 'S') { e.preventDefault(); skip() }
        if (k === 'P') { e.preventDefault(); openPause() }
      } else if (phase === 'dialing') {
        if (k === 'N') { e.preventDefault(); log('no_answer') }
        if (k === 'V') { e.preventDefault(); setVmAsk(true) }
        if (k === 'B') { e.preventDefault(); log('busy_failed') }
        if (k === 'X') { e.preventDefault(); log('disconnected') }
        if (k === 'C' || e.key === 'Enter') { e.preventDefault(); setPopup(true) }
      } else if (phase === 'empty') {
        if (k === 'R') { e.preventDefault(); loadNext() }
        if (k === 'P') { e.preventDefault(); openPause() }
      } else if (phase === 'paused' && (e.key === 'Enter' || k === 'R')) {
        e.preventDefault(); resume()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  function copy(text: string) {
    navigator.clipboard?.writeText(text).then(() => setToastMsg('Copied'))
  }

  /** "Tue, Sep 29, 9:10 AM" on the lead's clock (the C4 proof). */
  function theirTime(iso: string, tz: string | null): string {
    try {
      return new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: tz ?? 'America/New_York' })
        .format(new Date(iso))
    } catch { return new Date(iso).toLocaleString() }
  }

  function localTime(tz: string | null): string {
    try {
      return new Intl.DateTimeFormat('en-US', { timeStyle: 'short', timeZone: tz ?? 'America/New_York' }).format(new Date())
    } catch { return '' }
  }

  const mm = String(Math.floor(callSec / 60)).padStart(2, '0')
  const ss = String(callSec % 60).padStart(2, '0')
  const hint = lead ? bestHint(best, lead) : null
  const pausedFor = pace?.break ? (now - Date.parse(pace.break.since)) / 1000 : 0

  return (
    <div className="page">
      <div className="actionrow" style={{ marginBottom: 12 }}>
        <div className="statchips">
          <Stat label="Dials" value={pace?.dials ?? 0} target={targets?.dials} />
          <Stat label="Conversations" value={pace?.conversations ?? 0} target={targets?.conversations} />
          <Stat label="Handoffs" value={pace?.handoffs ?? 0} target={targets?.handoffs} />
          <PaceChips pace={pace} />
        </div>
        {(phase === 'ready' || phase === 'empty') && !pauseOpen && (
          <button className="btn ghost small" style={{ marginLeft: 'auto' }} onClick={openPause} disabled={busy}>
            Pause <span className="kbd">P</span>
          </button>
        )}
      </div>

      {pulse?.sprint && <SprintBanner sprint={pulse.sprint} me={profile?.id ?? null} compact />}

      {myCbs.length > 0 && (phase === 'ready' || phase === 'empty') && (
        <div className="card" style={{ padding: '8px 14px', marginBottom: 12 }}>
          <span className="kpilabel">My callbacks</span>{' '}
          <span className="small">
            {myCbs.map((c, i) => {
              const due = Date.parse(c.due_at) <= Date.now()
              return (
                <span key={`${c.due_at}-${i}`} className="muted">
                  {i > 0 ? ' · ' : ''}
                  <b>{c.leads?.name ?? 'lead'}</b>{' '}
                  {due ? <span style={{ color: 'var(--bad)' }}>due now</span>
                       : `${theirTime(c.due_at, c.leads?.tz ?? null)} their time`}
                </span>
              )
            })}
          </span>
        </div>
      )}

      {pauseOpen && (
        <div className="card pausepanel">
          <div className="kpilabel">Pause: what for?</div>
          <div className="actionrow">
            {BREAK_REASONS.map((b, i) => (
              <button key={b.key} className={`btn ${pauseOther && b.key === 'other' ? 'primary' : ''}`} onClick={() => pause(b.key)} disabled={busy}>
                <span className="kbd">{i + 1}</span> {b.label}
              </button>
            ))}
            <button className="btn ghost" onClick={() => setPauseOpen(false)}>Cancel <span className="kbd">Esc</span></button>
          </div>
          {pauseOther && (
            <div className="formrow">
              <input autoFocus value={pauseNote} onChange={(e) => setPauseNote(e.target.value)} placeholder="what the pause is for" style={{ minWidth: 260 }} />
              <button className="btn primary" onClick={() => pause('other')} disabled={!pauseNote.trim() || busy}>Pause <span className="kbd">Enter</span></button>
            </div>
          )}
          <p className="muted small" style={{ marginBottom: 0 }}>The lead on screen goes back to the queue, the floor board shows the reason, and your pace leaves the time out.</p>
        </div>
      )}

      {phase === 'loading' && <div className="emptystate">Loading the next lead…</div>}

      {phase === 'paused' && (
        <div className="card emptystate">
          <p><b>Paused: {breakLabel(pace?.break?.reason)}</b>{pace?.break?.note ? ` (${pace.break.note})` : ''} · {clock(pausedFor)}</p>
          <p className="small">The floor board shows you on {breakLabel(pace?.break?.reason).toLowerCase()}. Nothing is served to you until you're back.</p>
          <button className="btn primary" onClick={resume} disabled={busy}>Back to dialing <span className="kbd">Enter</span></button>
        </div>
      )}

      {phase === 'empty' && (
        <div className="card emptystate">
          <p><b>Nothing to dial right now.</b></p>
          <p className="small">{ws?.hint ?? ws?.error ?? 'Ask your manager for a list, or try again.'}</p>
          <button className="btn primary" onClick={loadNext}>Check again <span className="kbd">R</span></button>
        </div>
      )}

      {(phase === 'ready' || phase === 'dialing') && lead && (
        <div className="dialgrid">
          <div>
            <div className="card">
              <div className="leadhead">
                {ws?.reason && (
                  <span className={`reasonchip ${ws.reason === 'callback_due' ? 'callback' : ''}`}>
                    {REASON_LABEL[ws.reason] ?? ws.reason}
                  </span>
                )}
              </div>
              <div className="leadhead" style={{ marginTop: 6 }}>
                <h2>{lead.name}</h2>
                <span className="leadphone">{fmtPhone(lead.phone_display ?? lead.phone_norm)}</span>
                <button className="copybtn" onClick={() => copy(lead.phone_norm)}>copy</button>
              </div>
              <div className="leadmeta">
                {[lead.category, lead.addr_city && `${lead.addr_city}, ${lead.addr_state}`,
                  lead.tz && `their time: ${localTime(lead.tz)}`].filter(Boolean).join(' · ')}
              </div>
              {hint && <div className="besthint">{hint}</div>}
              <div style={{ marginTop: 8 }}>
                {(ws?.intents ?? []).slice(0, 4).map((i) => (
                  <span key={i.key} className={`tag ${i.confidence >= 0.95 ? 'hot' : ''}`}>{i.label}</span>
                ))}
              </div>

              {ws?.referral && (
                <div className="proof warm">
                  Warm referral{ws.referral.from ? <> from <b>{ws.referral.from}</b></> : null}
                  {ws.referral.agent ? ` (${ws.referral.agent}, ${new Date(ws.referral.at).toLocaleDateString([], { month: 'short', day: 'numeric' })})` : ''}
                  {ws.referral.note ? `: “${ws.referral.note}”` : ''}
                  {ws.referral.from && <div className="muted small">Open with it: “{ws.referral.from} said I should give you a call.”</div>}
                </div>
              )}
              {ws?.missed && (
                <div className="proof">
                  No pickup on <b>{ws.missed.count} tries</b> during their business hours
                  ({ws.missed.times.map((t) => theirTime(t, lead.tz)).join('; ')}; their time).
                  <div className="muted small">Open with it: “I’ve tried you {ws.missed.count} times during work hours. Your customers get the same.”</div>
                </div>
              )}
              {ws?.ab && (
                <div className="opener">
                  <div className="kpilabel">Opener to use · A/B test “{ws.ab.test}”, version {ws.ab.variant}</div>
                  <div>{ws.ab.text}</div>
                </div>
              )}

              <div className="actionzone">
                {phase === 'ready' && (
                  <div className="actionrow">
                    <button className="btn primary big" onClick={dial} disabled={busy}>
                      Dial <span className="kbd">D</span>
                    </button>
                    <button className="btn ghost" onClick={skip} disabled={busy}>Skip <span className="kbd">S</span></button>
                    {wrapLeft != null && (wrapLeft > 0
                      ? <span className="wrapchip" title="Wrap-up: a breath and a look at the next lead. The dial is always yours to press.">Wrap-up {clock(wrapLeft)}</span>
                      : <span className="wrapchip over">Ready to dial · +{clock(-wrapLeft)}</span>)}
                  </div>
                )}

                {phase === 'dialing' && !vmAsk && (
                  <>
                    <div className="actionrow">
                      <span className="calltimer">on the line · {mm}:{ss}</span>
                    </div>
                    <div className="outcomebar">
                      <button className="btn" onClick={() => log('no_answer')} disabled={busy}>No answer <span className="kbd">N</span></button>
                      <button className="btn" onClick={() => setVmAsk(true)} disabled={busy}>Voicemail <span className="kbd">V</span></button>
                      <button className="btn" onClick={() => log('busy_failed')} disabled={busy}>Busy / failed <span className="kbd">B</span></button>
                      <button className="btn" onClick={() => log('disconnected')} disabled={busy}>Disconnected <span className="kbd">X</span></button>
                      <button className="btn primary" onClick={() => setPopup(true)} disabled={busy}>Connected → outcome <span className="kbd">C</span></button>
                    </div>
                  </>
                )}

                {phase === 'dialing' && vmAsk && (
                  <div className="actionrow">
                    <span className="muted">Voicemail —</span>
                    <button className="btn" onClick={() => log('voicemail', { left_message: true })}>left a message <span className="kbd">Y</span></button>
                    <button className="btn" onClick={() => log('voicemail', { left_message: false })}>hung up <span className="kbd">N</span></button>
                    <button className="btn ghost" onClick={() => setVmAsk(false)}>back</button>
                  </div>
                )}
              </div>
            </div>
          </div>

          <aside className="ctx">
            <div className="card">
              <h4>Why this lead</h4>
              {(ws?.intents ?? []).map((i) => (
                <div className="factrow" key={i.key}><span>{i.label}</span></div>
              ))}
              {!ws?.intents?.length && <div className="muted small">No intent signals yet.</div>}
            </div>
            <div className="card">
              <h4>Business facts</h4>
              <div className="factrow"><span>Address</span><span className="v">{addressLine(lead) || '—'}</span></div>
              <div className="factrow"><span>Rating</span><span className="v">{lead.rating ?? '—'} ({lead.review_count ?? 0} reviews)</span></div>
              <div className="factrow"><span>Website</span><span className="v">{lead.website_type === 'none' ? 'NONE' : (lead.platform_detail ?? lead.platform ?? lead.website_type ?? '—')}</span></div>
              <div className="factrow"><span>Line type</span><span className="v">{lead.phone_type ?? '—'}</span></div>
              <div className="factrow"><span>Tier / score</span><span className="v">{lead.tier ?? '—'} / {lead.score ?? '—'}</span></div>
              <div className="factrow"><span>Trades</span><span className="v">{(lead.categories ?? [lead.category]).filter(Boolean).join(', ') || '—'}</span></div>
              <div className="actionrow" style={{ marginTop: 6 }}>
                {lead.maps_url && <a className="small" href={lead.maps_url} target="_blank" rel="noreferrer">Maps listing</a>}
                {lead.website && <a className="small" href={lead.website} target="_blank" rel="noreferrer">their site</a>}
              </div>
            </div>
            <div className="card">
              <h4>Previous touches</h4>
              {ws?.history?.length ? (
                <ul className="hist">
                  {ws.history.map((h, i) => (
                    <li key={i}>
                      {new Date(h.at).toLocaleDateString()} — {h.agent}: <b>{dispositionLabel(h.disposition)}</b>
                      {h.duration ? <span className="muted"> · {talkTime(h.duration)}</span> : null}
                      {(h.taps ?? []).map((t) => (
                        <div key={t.objection} className="small">
                          heard “{t.objection}”{t.counters.length ? <span className="muted"> → said: {t.counters.join(' / ')}</span> : null}
                        </div>
                      ))}
                      {h.note && <div className="muted small">{h.note}</div>}
                      {h.ai_summary && (
                        <div className="aisum">
                          {h.ai_summary}
                          {h.next_steps && <div className="muted">Next: {h.next_steps}</div>}
                        </div>
                      )}
                    </li>
                  ))}
                </ul>
              ) : <div className="muted small">First touch — fresh lead.</div>}
            </div>
            <Battlecards attemptId={attemptId} agentId={profile?.id} />
          </aside>
        </div>
      )}

      {popup && lead && (
        <DispositionPopup
          leadName={lead.name}
          tz={lead.tz}
          attemptId={attemptId}
          city={lead.addr_city}
          state={lead.addr_state}
          endedSec={endedSec}
          onPick={(code, args) => log(code, args)}
          onClose={() => { setPopup(false); setEndedSec(null) }}
        />
      )}
      {toast && <div className={popup ? 'toast top' : 'toast'}>{toast}</div>}
    </div>
  )
}
