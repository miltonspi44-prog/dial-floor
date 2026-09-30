import { useEffect, useRef, useState } from 'react'
import { fmtPhone } from '../lib/supabase'
import { bellOn, canNotify, chime, disableNotify, enableNotify, notify, notifyOn, setBell } from '../lib/notify'
import type { FloorAlert } from '../lib/types'

const KIND: Record<FloorAlert['kind'], string> = {
  idle: 'Idle', long_call: 'Long call', pace: 'Pace', callback: 'Callback', spam: 'Number', win: 'Win',
}

function at(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
}

function body(a: FloorAlert): string {
  return a.kind === 'spam' && a.number ? `${fmtPhone(a.number)}: ${a.detail}` : a.detail
}

/** E4: what the floor board raises right now. A win rings for everyone; managers
 *  also get the nudges, and can have them as notifications on this device. */
export default function AlertsPanel({ alerts, isManager }: { alerts: FloorAlert[] | null; isManager: boolean }) {
  const [notifying, setNotifying] = useState(notifyOn)
  const [bell, setBellState] = useState(bellOn)
  const [msg, setMsg] = useState<string | null>(null)
  const seen = useRef<Set<string> | null>(null)

  // each alert once: the ones already up when the page opened stay quiet
  useEffect(() => {
    if (!alerts) return
    const fresh = seen.current ? alerts.filter((a) => !seen.current!.has(a.key)) : []
    seen.current = new Set([...(seen.current ?? []), ...alerts.map((a) => a.key)])
    for (const a of fresh) {
      notify(a.kind === 'win' ? `Bell! ${a.title}` : a.title, body(a), a.key)
      if (a.kind === 'win' && bell) chime()
    }
  }, [alerts, bell])

  async function toggleNotify() {
    if (notifying) { disableNotify(); setNotifying(false); setMsg(null); return }
    const why = await enableNotify()
    setMsg(why)
    setNotifying(!why)
  }

  function toggleBell() {
    setBell(!bell)
    setBellState(!bell)
    if (!bell) chime()  // a click lets the page play sound; and it's a preview
  }

  const wins = (alerts ?? []).filter((a) => a.kind === 'win')
  const nudges = (alerts ?? []).filter((a) => a.kind !== 'win')

  return (
    <>
      {wins.map((w) => (
        <div key={w.key} className="card wincard">
          <b>Bell!</b> {w.title}: {w.detail} <span className="muted small">· {at(w.at)}</span>
        </div>
      ))}
      {isManager && (
        <div className="card alertspanel">
          <div className="sectionhead" style={{ margin: '0 0 6px' }}>
            <h3>Alerts</h3>
            <span className="muted small">{nudges.length ? `${nudges.length} now` : 'all quiet'}</span>
            <span style={{ marginLeft: 'auto' }} className="actionrow">
              {canNotify() && (
                <button className={`btn small ${notifying ? 'primary' : ''}`} onClick={toggleNotify}
                  title="System notifications on this device while this tab is open">
                  {notifying ? 'Notifying this device' : 'Notify me on this device'}
                </button>
              )}
              <button className={`btn small ${bell ? 'primary' : ''}`} onClick={toggleBell} title="A chime when someone gets a chance or closes a sale">
                {bell ? 'Bell on' : 'Bell off'}
              </button>
            </span>
          </div>
          {msg && <div className="warnline">{msg}</div>}
          {nudges.length ? (
            <ul className="alertlist">
              {nudges.map((a) => (
                <li key={a.key}>
                  <span className={`alertkind ${a.kind}`}>{KIND[a.kind]}</span>
                  <span><b>{a.title}</b> <span className="muted">{body(a)}</span></span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="muted small" style={{ margin: 0 }}>No one idle, no call running long, pace on track, callbacks on time, numbers healthy.</p>
          )}
        </div>
      )}
    </>
  )
}
