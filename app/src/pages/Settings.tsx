import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, fmtPhone } from '../lib/supabase'
import type { NumberHealthRow, SettingRow } from '../lib/types'
import AlertSettingsCard from '../components/AlertSettingsCard'
import LoadError from '../components/LoadError'

/** Item 36: every tunable that used to need the SQL editor, in one place.
 *  The database owns the whitelist and the validation (settings_set); this page
 *  renders whatever the registry says, so a new setting is one SQL line away. */

interface SuppressionRow { id: number; phone_norm: string; reason: string; at: string; leads: string[] }

function Window({ row, onSave, busy }: { row: SettingRow; onSave: (v: unknown) => void; busy: boolean }) {
  const v = (row.value ?? row.def) as { start: string; end: string; days?: number[] }
  const [start, setStart] = useState(v.start)
  const [end, setEnd] = useState(v.end)
  const [days, setDays] = useState<number[]>(v.days ?? [1, 2, 3, 4, 5])
  const withDays = row.kind === 'window_days'
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
  return (
    <div className="actionrow" style={{ flexWrap: 'wrap' }}>
      <input type="time" value={start} onChange={(e) => setStart(e.target.value)} aria-label={`${row.label} start`} />
      <span className="muted">to</span>
      <input type="time" value={end} onChange={(e) => setEnd(e.target.value)} aria-label={`${row.label} end`} />
      {withDays && names.map((n, i) => (
        <label key={n} className="small" style={{ display: 'inline-flex', gap: 3, alignItems: 'center' }}>
          <input type="checkbox" checked={days.includes(i + 1)}
            onChange={(e) => setDays(e.target.checked ? [...days, i + 1].sort() : days.filter((d) => d !== i + 1))} />
          {n}
        </label>
      ))}
      <button className="btn small" disabled={busy}
        onClick={() => onSave(withDays ? { start, end, days } : { start, end })}>Save</button>
    </div>
  )
}

function JsonBox({ row, onSave, busy }: { row: SettingRow; onSave: (v: unknown) => void; busy: boolean }) {
  const [text, setText] = useState(() => JSON.stringify(row.value ?? row.def, null, 2))
  const [bad, setBad] = useState(false)
  return (
    <div style={{ width: '100%' }}>
      <textarea rows={4} value={text} spellCheck={false} style={{ width: '100%', fontFamily: 'monospace' }}
        aria-label={row.label}
        onChange={(e) => { setText(e.target.value); try { JSON.parse(e.target.value); setBad(false) } catch { setBad(true) } }} />
      <div className="actionrow">
        <button className="btn small" disabled={busy || bad} onClick={() => onSave(JSON.parse(text))}>Save</button>
        {bad && <span className="warnline">not valid JSON yet</span>}
      </div>
    </div>
  )
}

export default function Settings() {
  const [rows, setRows] = useState<SettingRow[] | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [saved, setSaved] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const [numbers, setNumbers] = useState<NumberHealthRow[]>([])
  const [dropPts, setDropPts] = useState(10)
  // item 46: the do-not-call list
  const [supQ, setSupQ] = useState('')
  const [sup, setSup] = useState<SuppressionRow[] | null>(null)
  const [supErr, setSupErr] = useState<string | null>(null)
  const [addPhone, setAddPhone] = useState('')
  const [addReason, setAddReason] = useState('dnc')

  const load = useCallback(() => {
    supabase.rpc('settings_all').then(({ data, error }) => {
      if (error) { setErr(error.message); return }
      setErr(null)
      const all = (data ?? []) as SettingRow[]
      setRows(all)
      const d: Record<string, string> = {}
      for (const r of all) if (r.kind === 'int' || r.kind === 'num' || r.kind === 'tz') d[r.key] = String(r.value ?? '')
      setDrafts(d)
      const sp = all.find((r) => r.key === 'spam_alert_drop_pts')
      if (sp && Number(sp.value) > 0) setDropPts(Number(sp.value))
    })
    supabase.from('v_number_health').select('*').order('dials_7d', { ascending: false })
      .then(({ data }) => setNumbers((data ?? []) as NumberHealthRow[]))
  }, [])

  const loadSuppression = useCallback((q: string) => {
    supabase.rpc('suppression_list', { p_query: q || null, p_limit: 100 }).then(({ data, error }) => {
      if (error) { setSupErr(error.message); return }
      setSupErr(null)
      setSup((data ?? []) as SuppressionRow[])
    })
  }, [])

  useEffect(() => { load(); loadSuppression('') }, [load, loadSuppression])

  async function save(key: string, value: unknown) {
    setBusyKey(key)
    const { error } = await supabase.rpc('settings_set', { p_key: key, p_value: value })
    setBusyKey(null)
    if (error) { setSaved(null); setErr(error.message); return }
    setErr(null)
    setSaved(key)
    window.setTimeout(() => setSaved((k) => (k === key ? null : k)), 2000)
    load()
  }

  async function addSuppression() {
    if (!window.confirm(`Add ${addPhone} to the do-not-call list?\n\nEvery lead record carrying it is suppressed and the console is told.`)) return
    const { data, error } = await supabase.rpc('add_suppression', { p_phone: addPhone, p_reason: addReason })
    if (error) { setSupErr(error.message); return }
    setSupErr(null)
    setAddPhone('')
    setSaved('suppression')
    loadSuppression(supQ)
    void data
  }

  const groups = useMemo(() => {
    const g = new Map<string, SettingRow[]>()
    for (const r of rows ?? []) {
      if (r.key === 'alerts') continue // the alert card below edits this one properly
      if (!g.has(r.grp)) g.set(r.grp, [])
      g.get(r.grp)!.push(r)
    }
    return [...g.entries()]
  }, [rows])

  function spamFlag(n: NumberHealthRow): boolean {
    if (n.rate_7d == null) return false
    if (n.rate_prev_7d != null && n.rate_prev_7d - n.rate_7d >= dropPts) return true
    return (n.dials_7d ?? 0) >= 60 && n.rate_7d < 8
  }

  return (
    <div className="page">
      <div className="sectionhead"><h3>Settings</h3><span className="muted small">what used to need the SQL editor; each value checks itself before it lands</span></div>
      {err && <LoadError what="the settings" error={err} onRetry={load} />}

      {groups.map(([grp, items]) => (
        <div className="card" key={grp}>
          <h4>{grp}</h4>
          {items.map((r) => (
            <div className="factrow" key={r.key} style={{ alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <span style={{ minWidth: 280 }}>
                {r.label}
                {r.help && <div className="muted small">{r.help}</div>}
              </span>
              <span className="v" style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap', flex: 1 }}>
                {(r.kind === 'int' || r.kind === 'num') && (
                  <>
                    <input type="number" style={{ width: 110 }} min={r.min} max={r.max}
                      step={r.kind === 'int' ? 1 : 0.5} aria-label={r.label}
                      value={drafts[r.key] ?? ''} onChange={(e) => setDrafts({ ...drafts, [r.key]: e.target.value })} />
                    <button className="btn small" disabled={busyKey === r.key || drafts[r.key] === String(r.value)}
                      onClick={() => save(r.key, Number(drafts[r.key]))}>Save</button>
                  </>
                )}
                {r.kind === 'bool' && (
                  <input type="checkbox" checked={r.value === true} aria-label={r.label}
                    disabled={busyKey === r.key} onChange={(e) => save(r.key, e.target.checked)} />
                )}
                {r.kind === 'tz' && (
                  <>
                    <input style={{ width: 220 }} list="tz-list" aria-label={r.label}
                      value={drafts[r.key] ?? ''} onChange={(e) => setDrafts({ ...drafts, [r.key]: e.target.value })} />
                    <datalist id="tz-list">
                      {['America/New_York', 'America/Chicago', 'America/Denver', 'America/Phoenix', 'America/Los_Angeles', 'America/Anchorage', 'Pacific/Honolulu'].map((z) => <option key={z} value={z} />)}
                    </datalist>
                    <button className="btn small" disabled={busyKey === r.key}
                      onClick={() => save(r.key, drafts[r.key])}>Save</button>
                  </>
                )}
                {(r.kind === 'window' || r.kind === 'window_days') && (
                  <Window row={r} onSave={(v) => save(r.key, v)} busy={busyKey === r.key} />
                )}
                {r.kind === 'json' && <JsonBox row={r} onSave={(v) => save(r.key, v)} busy={busyKey === r.key} />}
                {saved === r.key && <span className="tag">saved</span>}
              </span>
            </div>
          ))}
        </div>
      ))}

      <div className="sectionhead"><h3>Alerts</h3><span className="muted small">what the floor board raises, and when</span></div>
      <AlertSettingsCard onSaved={load} />

      <div className="sectionhead"><h3>Number health</h3><span className="muted small">a connect rate down {dropPts}+ points on the week = probable spam label — swap that number in Zoom</span></div>
      <div className="card">
        {numbers.length ? (
          <div className="tablewrap"><table className="data">
            <thead><tr><th>Number</th><th>Dials 7d</th><th>Connects 7d</th><th>Rate</th><th>Prev wk</th><th /></tr></thead>
            <tbody>
              {numbers.map((n) => (
                <tr key={n.number}>
                  <td>{fmtPhone(n.number)}</td>
                  <td>{n.dials_7d ?? 0}</td>
                  <td>{n.connects_7d ?? 0}</td>
                  <td>{n.rate_7d != null ? `${n.rate_7d}%` : '—'}</td>
                  <td>{n.rate_prev_7d != null ? `${n.rate_prev_7d}%` : '—'}</td>
                  <td>{spamFlag(n) && <span className="tag" style={{ background: 'var(--bad-bg)', color: 'var(--bad)' }}>possible spam flag</span>}</td>
                </tr>
              ))}
            </tbody>
          </table></div>
        ) : <span className="muted small">No dial data yet — stats appear after the first webhook-matched calls.</span>}
      </div>

      <div className="sectionhead"><h3>Do-not-call list</h3><span className="muted small">numbers the dialer refuses; adding one suppresses every record carrying it and tells the console</span></div>
      <div className="card">
        <div className="actionrow" style={{ flexWrap: 'wrap' }}>
          <input placeholder="search by number" value={supQ} inputMode="tel" aria-label="Search the do-not-call list"
            onChange={(e) => { setSupQ(e.target.value); loadSuppression(e.target.value) }} style={{ width: 180 }} />
          <span style={{ flex: 1 }} />
          <input placeholder="(305) 555-0123" value={addPhone} inputMode="tel" aria-label="Number to add"
            onChange={(e) => setAddPhone(e.target.value)} style={{ width: 160 }} />
          <select value={addReason} onChange={(e) => setAddReason(e.target.value)} aria-label="Reason">
            <option value="dnc">asked not to be called</option>
            <option value="wrong_number">wrong number</option>
            <option value="disconnected">disconnected</option>
          </select>
          <button className="btn" onClick={addSuppression} disabled={addPhone.replace(/\D/g, '').length < 10}>Add</button>
          {saved === 'suppression' && <span className="tag">added</span>}
        </div>
        {supErr && <div className="warnline">{supErr}</div>}
        {sup && (sup.length ? (
          <div className="tablewrap"><table className="data">
            <thead><tr><th>Number</th><th>Reason</th><th>Since</th><th>Lead records</th></tr></thead>
            <tbody>
              {sup.map((s) => (
                <tr key={s.id}>
                  <td>{fmtPhone(s.phone_norm)}</td>
                  <td>{s.reason}</td>
                  <td>{new Date(s.at).toLocaleDateString()}</td>
                  <td className="small">{s.leads.join(', ') || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table></div>
        ) : <span className="muted small">Nothing matches.</span>)}
      </div>
    </div>
  )
}
