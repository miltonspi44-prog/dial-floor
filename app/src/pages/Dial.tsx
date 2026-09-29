import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase, fmtPhone, zoomDial, loadTargets } from '../lib/supabase'
import type { LeadRow, NextLeadResult, Profile, Targets } from '../lib/types'
import DispositionPopup from '../components/DispositionPopup'
import Battlecards from '../components/Battlecards'

type Phase = 'loading' | 'ready' | 'dialing' | 'empty'

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

export default function Dial({ profile }: { profile: Profile | null }) {
  const [ws, setWs] = useState<NextLeadResult | null>(null)
  const [phase, setPhase] = useState<Phase>('loading')
  const [attemptId, setAttemptId] = useState<number | null>(null)
  const [popup, setPopup] = useState(false)
  const [vmAsk, setVmAsk] = useState(false)
  const [callSec, setCallSec] = useState(0)
  const [today, setToday] = useState<{ dials: number; connects: number; handoffs: number } | null>(null)
  const [targets, setTargets] = useState<Targets | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const timerRef = useRef<number | null>(null)

  const lead = ws?.lead

  const refreshToday = useCallback(() => {
    if (!profile) return
    supabase.from('v_floor_today').select('dials_today, connects_today, handoffs_today')
      .eq('agent_id', profile.id).maybeSingle()
      .then(({ data }) => data && setToday({
        dials: data.dials_today, connects: data.connects_today, handoffs: data.handoffs_today,
      }))
  }, [profile])

  const applyResult = useCallback((res: NextLeadResult | null) => {
    setPopup(false); setVmAsk(false); stopTimer()
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
    const { data, error } = await supabase.rpc('next_lead')
    if (error) { setToastMsg(error.message); setPhase('empty'); return }
    applyResult(data as NextLeadResult)
  }, [applyResult])

  useEffect(() => {
    loadNext()
    refreshToday()
    supabase.rpc('heartbeat', { p_status: 'idle' }).then(() => {})
  }, [loadNext, refreshToday])

  useEffect(() => { loadTargets().then(setTargets) }, [])

  function setToastMsg(m: string) {
    setToast(m)
    window.setTimeout(() => setToast(null), 2500)
  }
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
    if (error) { setToastMsg(error.message); return }
    refreshToday()
    const next = (data as { next: NextLeadResult }).next
    applyResult(next)
  }

  async function skip() {
    if (!lead || busy) return
    setBusy(true)
    const { data, error } = await supabase.rpc('skip_lead', { p_lead_id: lead.id })
    setBusy(false)
    if (error) { setToastMsg(error.message); return }
    applyResult((data as { next: NextLeadResult }).next)
  }

  // global keys (popup handles its own while open)
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (popup) return
      if (vmAsk) {
        const k = e.key.toUpperCase()
        if (k === 'Y') { e.preventDefault(); log('voicemail', { left_message: true }) }
        if (k === 'N') { e.preventDefault(); log('voicemail', { left_message: false }) }
        if (e.key === 'Escape') { e.preventDefault(); setVmAsk(false) }
        return
      }
      const target = e.target as HTMLElement
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)) return
      const k = e.key.toUpperCase()
      if (phase === 'ready') {
        if (k === 'D' || e.key === 'Enter') { e.preventDefault(); dial() }
        if (k === 'S') { e.preventDefault(); skip() }
      } else if (phase === 'dialing') {
        if (k === 'N') { e.preventDefault(); log('no_answer') }
        if (k === 'V') { e.preventDefault(); setVmAsk(true) }
        if (k === 'B') { e.preventDefault(); log('busy_failed') }
        if (k === 'X') { e.preventDefault(); log('disconnected') }
        if (k === 'C' || e.key === 'Enter') { e.preventDefault(); setPopup(true) }
      } else if (phase === 'empty' && k === 'R') { e.preventDefault(); loadNext() }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  function copy(text: string) {
    navigator.clipboard?.writeText(text).then(() => setToastMsg('Copied'))
  }

  function localTime(tz: string | null): string {
    try {
      return new Intl.DateTimeFormat('en-US', { timeStyle: 'short', timeZone: tz ?? 'America/New_York' }).format(new Date())
    } catch { return '' }
  }

  const mm = String(Math.floor(callSec / 60)).padStart(2, '0')
  const ss = String(callSec % 60).padStart(2, '0')

  return (
    <div className="page">
      <div className="actionrow" style={{ marginBottom: 12 }}>
        <div className="statchips">
          <Stat label="Dials" value={today?.dials ?? 0} target={targets?.dials} />
          <Stat label="Connects" value={today?.connects ?? 0} target={targets?.connects} />
          <Stat label="Handoffs" value={today?.handoffs ?? 0} target={targets?.handoffs} />
        </div>
      </div>

      {phase === 'loading' && <div className="emptystate">Loading the next lead…</div>}

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
              <div style={{ marginTop: 8 }}>
                {(ws?.intents ?? []).slice(0, 4).map((i) => (
                  <span key={i.key} className={`tag ${i.confidence >= 0.95 ? 'hot' : ''}`}>{i.label}</span>
                ))}
              </div>

              <div className="actionzone">
                {phase === 'ready' && (
                  <div className="actionrow">
                    <button className="btn primary big" onClick={dial} disabled={busy}>
                      Dial <span className="kbd">D</span>
                    </button>
                    <button className="btn ghost" onClick={skip} disabled={busy}>Skip <span className="kbd">S</span></button>
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
                      {new Date(h.at).toLocaleDateString()} — {h.agent}: <b>{h.disposition ?? 'no outcome'}</b>
                      {h.note && <span className="muted"> · {h.note}</span>}
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
          onPick={(code, args) => log(code, args)}
          onClose={() => setPopup(false)}
        />
      )}
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
