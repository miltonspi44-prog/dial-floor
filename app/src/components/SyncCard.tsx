import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { SyncHealth, SyncRunRow } from '../lib/types'
import LoadError from './LoadError'

/** Wave 5: the lead sync, visible. Eleven days of it running unattended were
 *  only readable through SQL; this is sync_health() on a card, refreshed every
 *  half minute while the page is open, with a button for a pull or a push now. */

function ago(iso: string | null | undefined, now: number): string {
  if (!iso) return 'never'
  const s = Math.max(0, Math.round((now - Date.parse(iso)) / 1000))
  if (s < 60) return 'just now'
  const m = Math.floor(s / 60)
  if (m < 60) return `${m} min ago`
  const h = Math.floor(m / 60)
  if (h < 48) return `${h} h ago`
  return `${Math.floor(h / 24)} days ago`
}

function when(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}

const KIND: Record<SyncRunRow['kind'], string> = { pull_leads: 'pull', push_status: 'push', csv_import: 'import' }

function Chip({ label, value, tone }: { label: string; value: string; tone?: 'ok' | 'bad' | 'warn' }) {
  const color = tone === 'ok' ? 'var(--ok)' : tone === 'bad' ? 'var(--bad)' : tone === 'warn' ? 'var(--warn)' : undefined
  return (
    <span className="chip" style={{ display: 'inline-flex', flexDirection: 'column', padding: '4px 10px', border: '1px solid var(--line)', borderRadius: 8, minWidth: 110 }}>
      <span className="muted small">{label}</span>
      <b style={{ color }}>{value}</b>
    </span>
  )
}

export default function SyncCard() {
  const [h, setH] = useState<SyncHealth | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [now, setNow] = useState(() => Date.now())
  // after "pull now" the card watches closely for two minutes, so the run is seen arriving
  const fastUntil = useRef(0)

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('sync_health')
    setNow(Date.now())
    if (error) { setErr(error.message); return }
    setErr(null)
    setH(data as SyncHealth)
  }, [])

  useEffect(() => {
    load()
    let tick = 0
    const id = window.setInterval(() => {
      tick++
      if (document.visibilityState !== 'visible') return
      if (Date.now() < fastUntil.current || tick % 6 === 0) load()
    }, 5000)
    return () => window.clearInterval(id)
  }, [load])

  async function request(task: 'pull' | 'push') {
    setBusy(true)
    setMsg(null)
    const { data, error } = await supabase.rpc('sync_request', { p_task: task })
    setBusy(false)
    if (error) { setMsg(error.message); return }
    const d = data as { ok: boolean; why?: string }
    if (!d.ok) { setMsg(d.why ?? 'not available here'); return }
    setMsg(`${task === 'pull' ? 'Pull' : 'Push'} requested — it shows up in the runs below within the minute.`)
    fastUntil.current = Date.now() + 120_000
    window.setTimeout(load, 3000)
  }

  if (err) return <LoadError what="the sync" error={err} onRetry={load} />
  if (!h) return <div className="card"><p className="muted small" style={{ margin: 0 }}>Loading…</p></div>

  const last = h.pull.last
  const lastOk = h.pull.last_ok
  const running = h.pull.running > 0
  const pullTone = running ? 'warn' : last && last.ok === false ? 'bad' : lastOk ? 'ok' : undefined
  const pullValue = running ? 'running now' : lastOk ? `${ago(lastOk.at, now)} · ${lastOk.rows} changed · ${lastOk.secs ?? '?'} s` : 'never'
  const consoleQuiet = h.leads.last_added ? (now - Date.parse(h.leads.last_added)) / 86_400_000 : 0

  return (
    <div className="card synccard">
      <div className="statchips">
        <Chip label="Last good pull" value={pullValue} tone={pullTone} />
        <Chip label="Pulls, 24 h" value={`${h.pull.runs_24h}${h.pull.failed_24h ? ` (${h.pull.failed_24h} failed)` : ''}`} tone={h.pull.failed_24h ? 'warn' : undefined} />
        <Chip label="Leads" value={`${h.leads.total.toLocaleString()} · +${h.leads.added_today} today · +${h.leads.added_7d} this week`} />
        <Chip label="Last new lead" value={ago(h.leads.last_added, now)} tone={consoleQuiet >= 3 ? 'warn' : undefined} />
        <Chip label="Console last changed anything" value={ago(h.leads.last_changed, now)} />
        <Chip label="Waiting to go to the console" value={h.push.waiting ? `${h.push.waiting} (oldest ${ago(h.push.oldest_waiting, now)})` : 'nothing'}
          tone={h.push.waiting && h.push.oldest_waiting && now - Date.parse(h.push.oldest_waiting) > 2 * 3_600_000 ? 'bad' : undefined} />
        <Chip label="Calls outside the dialer" value={`${h.outside_calls.today} today · ${h.outside_calls.week} this week`} tone={h.outside_calls.today ? 'warn' : undefined} />
        <Chip label="Scheduler" value={h.cron ? (h.cron.length ? `${h.cron.length} jobs` : 'no jobs installed') : 'PC loop'} tone={h.cron && !h.cron.length ? 'bad' : undefined} />
        {h.leads.undialable > 0 && <Chip label="Numbers nobody can dial" value={`${h.leads.undialable} kept out`} />}
      </div>
      <div className="actionrow" style={{ flexWrap: 'wrap' }}>
        <button className="btn small" disabled={busy || running} onClick={() => request('pull')}>Pull now</button>
        <button className="btn small" disabled={busy || running} onClick={() => request('push')}>Push now</button>
        {msg && <span className="muted small">{msg}</span>}
        {!msg && <span className="muted small">The sync pulls every 15 minutes and pushes outcomes every minute on its own; these ask for one straight away.</span>}
      </div>
      {h.failures.length > 0 && (
        <div style={{ marginTop: 10 }}>
          <div className="muted small">Failures this week (the latest first) — the console having a bad minute, usually; the next run tries again</div>
          <ul className="alertlist">
            {h.failures.map((f, i) => (
              <li key={i}><span className="alertkind">{f.kind === 'pull_leads' ? 'pull' : 'push'}</span><span>{when(f.at)} <span className="muted">{f.detail ?? 'no detail'}</span></span></li>
            ))}
          </ul>
        </div>
      )}
      <div className="tablewrap" style={{ marginTop: 10 }}><table className="data runs">
        <thead><tr><th>When</th><th>Run</th><th>Result</th><th>Rows</th><th>Took</th><th>Detail</th></tr></thead>
        <tbody>
          {h.runs.map((r) => (
            <tr key={r.id}>
              <td>{when(r.at)}</td>
              <td>{KIND[r.kind] ?? r.kind}</td>
              <td>{r.ok === true ? <span className="tag">ok</span> : r.ok === false ? <span className="tag" style={{ background: 'var(--bad-bg)', color: 'var(--bad)' }}>failed</span> : <span className="tag" style={{ background: 'var(--warn-bg)', color: 'var(--warn)' }}>running</span>}</td>
              <td>{r.rows}</td>
              <td>{r.secs == null ? '—' : `${r.secs} s`}</td>
              <td className="detail small muted">{r.detail ?? ''}</td>
            </tr>
          ))}
          {!h.runs.length && <tr><td colSpan={6} className="muted small">No runs yet.</td></tr>}
        </tbody>
      </table></div>
      {h.cron && h.cron.length > 0 && (
        <div className="muted small" style={{ marginTop: 8 }}>
          Scheduler: {h.cron.map((j) => `${j.name.replace('dial-floor ', '')} (${j.schedule}) last ${j.last_status ?? 'never'} ${ago(j.last_run, now)}`).join(' · ')}
        </div>
      )}
    </div>
  )
}
