import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { AlertSettings } from '../lib/types'

const DEFAULTS: AlertSettings = {
  idle_minutes: 10, long_call_minutes: 15, pace_pct: 80, callback_overdue_minutes: 15, celebrate: true, spam: true,
}

const NUMBERS: { key: 'idle_minutes' | 'long_call_minutes' | 'pace_pct' | 'callback_overdue_minutes'; label: string; unit: string }[] = [
  { key: 'idle_minutes', label: 'Idle (a lead up, no dial) after', unit: 'min' },
  { key: 'long_call_minutes', label: 'One call running past', unit: 'min' },
  { key: 'pace_pct', label: 'Behind pace: on track for under', unit: '% of the dial target' },
  { key: 'callback_overdue_minutes', label: 'Callback overdue by', unit: 'min' },
]

/** E4's triggers, for managers: 0 (or unticked) turns one off. */
export default function AlertSettingsCard({ onSaved }: { onSaved: () => void }) {
  const [draft, setDraft] = useState<Record<string, string | boolean> | null>(null)
  const [saved, setSaved] = useState<string | null>(null)

  useEffect(() => {
    supabase.from('app_settings').select('value').eq('key', 'alerts').maybeSingle().then(({ data }) => {
      const v = { ...DEFAULTS, ...((data?.value ?? {}) as Partial<AlertSettings>) }
      setDraft({
        idle_minutes: String(v.idle_minutes), long_call_minutes: String(v.long_call_minutes),
        pace_pct: String(v.pace_pct), callback_overdue_minutes: String(v.callback_overdue_minutes),
        celebrate: v.celebrate, spam: v.spam,
      })
    })
  }, [])

  async function save() {
    if (!draft) return
    const n = (k: string) => Math.max(0, Math.round(Number(draft[k]) || 0))
    const value: AlertSettings = {
      idle_minutes: n('idle_minutes'), long_call_minutes: n('long_call_minutes'), pace_pct: Math.min(100, n('pace_pct')),
      callback_overdue_minutes: n('callback_overdue_minutes'), celebrate: draft.celebrate === true, spam: draft.spam === true,
    }
    const { error } = await supabase.from('app_settings').upsert({ key: 'alerts', value, updated_at: new Date().toISOString() })
    setSaved(error ? error.message : 'Saved')
    window.setTimeout(() => setSaved(null), 2000)
    if (!error) onSaved()
  }

  return (
    <details className="card settingscard">
      <summary>Alert settings</summary>
      {draft ? (
        <div className="panelbody" style={{ marginTop: 10 }}>
          <div className="formrow">
            {NUMBERS.map((f) => (
              <label key={f.key}>{f.label}
                <span className="actionrow" style={{ gap: 6 }}>
                  <input type="number" min={0} style={{ width: 90 }} value={draft[f.key] as string}
                    onChange={(e) => setDraft({ ...draft, [f.key]: e.target.value })} />
                  <span className="muted small">{f.unit}</span>
                </span>
              </label>
            ))}
          </div>
          <label className="radio"><input type="checkbox" checked={draft.celebrate === true}
            onChange={(e) => setDraft({ ...draft, celebrate: e.target.checked })} /> Ring the bell for a chance given or a sale closed (everyone sees it)</label>
          <label className="radio"><input type="checkbox" checked={draft.spam === true}
            onChange={(e) => setDraft({ ...draft, spam: e.target.checked })} /> Flag a caller number whose connect rate collapses</label>
          <div className="actionrow">
            <button className="btn primary" onClick={save}>Save</button>
            {saved && <span className="muted small">{saved}</span>}
            <span className="muted small">0 turns an alert off. Pace alerts start after an agent's first hour.</span>
          </div>
        </div>
      ) : <p className="muted small">Loading…</p>}
    </details>
  )
}
