import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { EFFECTS, KINDS, KIND_LABEL, PICKUPS, effectKey, effectText, pickupKey, traitsText, word } from '../lib/ai'

/** What the editor opens with: a saved lesson, a proposal, or a lead's traits. */
export interface LessonSeed {
  id?: number; conditions: Record<string, string>; win?: number; answer?: number
  note?: string; source?: 'manual' | 'chat' | 'brief' | 'review'
}

// traits with a handful of values are picked; the rest are typed (or picked from what is on file)
const CHOICES: Record<string, { v: string; label: string }[]> = {
  website: [{ v: 'none', label: 'no website' }, { v: 'social', label: 'social page only' }, { v: 'site', label: 'has a website' }],
  phone: [{ v: 'mobile', label: 'mobile' }, { v: 'landline', label: 'landline' }, { v: 'voip', label: 'VoIP' }],
  tier: [{ v: 'A', label: 'A' }, { v: 'B', label: 'B' }, { v: 'C', label: 'C' }],
  reviews: [{ v: '0', label: 'none' }, { v: '1-9', label: '1–9' }, { v: '10-49', label: '10–49' }, { v: '50+', label: '50+' }],
  score: [{ v: '<40', label: 'under 40' }, { v: '40-59', label: '40–59' }, { v: '60-79', label: '60–79' }, { v: '80+', label: '80+' }],
}
const TYPED_HINT: Record<string, string> = { trade: 'add a trade', state: 'add a state (FL)', area: 'add an area code (305)', source: 'add a source' }
const STATES = 'AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'.split(' ')

const values = (s: string | undefined) => (s ?? '').split(',').map((x) => x.trim()).filter(Boolean)

/** 0044: teach the AI a lesson, or change one. */
export default function AiLessonEditor({ seed, onClose, onSaved }: {
  seed: LessonSeed; onClose: () => void; onSaved: (msg: string) => void
}) {
  const [cond, setCond] = useState<Record<string, string>>(seed.conditions)
  const [effect, setEffect] = useState(seed.win != null ? effectKey(seed.win) : 'more')
  const [pickup, setPickup] = useState(seed.answer != null ? pickupKey(seed.answer) : 'same')
  const [note, setNote] = useState(seed.note ?? '')
  const [typing, setTyping] = useState<Record<string, string>>({})
  const [known, setKnown] = useState<{ trade: { key: string; n: number }[]; source: { key: string; n: number }[] }>({ trade: [], source: [] })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const boxRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    boxRef.current?.focus()
    let live = true
    Promise.all([supabase.rpc('lead_categories'), supabase.rpc('lead_sources')]).then(([t, s]) => {
      if (live) setKnown({ trade: (t.data ?? []) as { key: string; n: number }[], source: (s.data ?? []) as { key: string; n: number }[] })
    })
    return () => { live = false }
  }, [])

  function put(k: string, vs: string[]) { setCond((c) => ({ ...c, [k]: [...new Set(vs)].join(',') })) }
  function toggle(k: string, v: string) {
    const cur = values(cond[k])
    put(k, cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v])
  }
  function addTyped(k: string) {
    const raw = typing[k] ?? ''
    const add = raw.split(',').map((x) => (k === 'state' ? x.trim().toUpperCase() : x.trim().toLowerCase().replace(/\s+/g, '_'))).filter(Boolean)
    if (!add.length) return
    put(k, [...values(cond[k]), ...add])
    setTyping((t) => ({ ...t, [k]: '' }))
  }
  function drop(k: string) { setCond((c) => { const n = { ...c }; delete n[k]; return n }) }

  const clean = Object.fromEntries(Object.entries(cond).filter(([, v]) => values(v).length)) as Record<string, string>
  const win = EFFECTS.find((e) => e.key === effect)?.win ?? 1
  const answer = PICKUPS.find((p) => p.key === pickup)?.answer ?? 1

  async function save() {
    if (!Object.keys(clean).length) { setErr('Pick at least one trait the leads share.'); return }
    if (win === 1 && answer === 1) { setErr('Say what changes: likelier or less likely to convert, or to pick up.'); return }
    if (note.trim().length < 3) { setErr('Say why. Gemini reads your reason, and it shows on every lead the lesson moves.'); return }
    setBusy(true)
    const { error } = await supabase.rpc('ai_lesson_save', {
      p_id: seed.id ?? null, p_conditions: clean, p_win: win, p_answer: answer, p_note: note.trim(), p_source: seed.source ?? 'manual',
    })
    setBusy(false)
    if (error) { setErr(error.message); return }
    onSaved(seed.id ? 'Lesson changed: the scores follow within a minute' : 'Lesson saved: the scores follow within a minute')
    onClose()
  }

  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="popup lessonform" ref={boxRef} tabIndex={-1} role="dialog" aria-modal="true" aria-label="Teach a lesson"
        onKeyDown={(e) => { if (e.key === 'Escape') onClose() }}>
        <h3>{seed.id ? 'Change this lesson' : 'Teach the AI a lesson'}</h3>
        <p className="muted small" style={{ marginTop: 0 }}>
          A lesson moves the score of every lead that has <b>all</b> of these traits, on top of what the calls say. It reaches the
          scores within a minute, and it's checked against the last 90 days of calls so you can see whether the floor's record agrees.
        </p>

        <div className="kpilabel">When a lead has all of these</div>
        {Object.keys(cond).length === 0 && <p className="muted small" style={{ margin: '4px 0' }}>No traits yet: add one below.</p>}
        {Object.keys(cond).map((k) => (
          <div className="traitrow" key={k}>
            <span className="traitname">{KIND_LABEL[k] ?? k}</span>
            <span className="traitvals">
              {CHOICES[k] ? CHOICES[k].map((c) => {
                const on = values(cond[k]).includes(c.v)
                return <button key={c.v} type="button" className={`choice ${on ? 'sel' : ''}`} aria-pressed={on} onClick={() => toggle(k, c.v)}>{c.label}</button>
              }) : (
                <>
                  {values(cond[k]).map((v) => (
                    <span key={v} className="choice sel">
                      {k === 'trade' ? word(v) : v}
                      <button type="button" className="chipx" aria-label={`Remove ${v}`}
                        onClick={() => put(k, values(cond[k]).filter((x) => x !== v))}>×</button>
                    </span>
                  ))}
                  <input className="traitadd" value={typing[k] ?? ''} placeholder={TYPED_HINT[k]} aria-label={TYPED_HINT[k]}
                    list={`ai-known-${k}`}
                    onChange={(e) => setTyping((t) => ({ ...t, [k]: e.target.value }))}
                    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ',') { e.preventDefault(); addTyped(k) } }}
                    onBlur={() => addTyped(k)} />
                </>
              )}
            </span>
            <button type="button" className="btn ghost small" onClick={() => drop(k)}>remove</button>
          </div>
        ))}
        <datalist id="ai-known-trade">{known.trade.map((t) => <option key={t.key} value={t.key}>{word(t.key)} ({t.n.toLocaleString()})</option>)}</datalist>
        <datalist id="ai-known-source">{known.source.map((t) => <option key={t.key} value={t.key}>{t.key} ({t.n.toLocaleString()})</option>)}</datalist>
        <datalist id="ai-known-state">{STATES.map((s) => <option key={s} value={s} />)}</datalist>
        <select className="traitpick" value="" aria-label="Add a trait"
          onChange={(e) => { if (e.target.value) setCond((c) => ({ ...c, [e.target.value]: '' })) }}>
          <option value="">+ add a trait</option>
          {KINDS.filter((k) => !(k in cond)).map((k) => <option key={k} value={k}>{KIND_LABEL[k]}</option>)}
        </select>

        <div className="kpilabel" style={{ marginTop: 14 }}>They are</div>
        <div className="actionrow">
          <select value={effect} onChange={(e) => setEffect(e.target.value)} aria-label="Effect on converting">
            {EFFECTS.map((x) => <option key={x.key} value={x.key}>{x.label}{x.win !== 1 ? ` (${x.win}×)` : ''}</option>)}
          </select>
          <select value={pickup} onChange={(e) => setPickup(e.target.value)} aria-label="Effect on picking up">
            {PICKUPS.map((x) => <option key={x.key} value={x.key}>{x.label}{x.answer !== 1 ? ` (${x.answer}×)` : ''}</option>)}
          </select>
        </div>

        <label className="kpilabel" htmlFor="lesson-why" style={{ display: 'block', marginTop: 14 }}>Because</label>
        <textarea id="lesson-why" rows={3} value={note} maxLength={600} onChange={(e) => setNote(e.target.value)}
          placeholder="In your words, e.g. “After a storm season, Florida roofers are flooded with work and want a site to show it off.”" />

        {Object.keys(clean).length > 0 && (
          <p className="lessonpreview"><b>{traitsText(clean)}</b> → {effectText(win, answer)}</p>
        )}
        {err && <div className="warnline" role="alert">{err}</div>}
        <div className="actionrow" style={{ marginTop: 12 }}>
          <button className="btn primary" disabled={busy} onClick={save}>{busy ? 'Saving…' : seed.id ? 'Save the change' : 'Save lesson'}</button>
          <button className="btn ghost" onClick={onClose}>Cancel</button>
        </div>
      </div>
    </div>
  )
}
