import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { EFFECTS, KIND_LABEL, LESSON_GROUPS, PICKUPS, RANGE_KINDS, effectKey, effectText, lift, pickupKey, traitsText, word } from '../lib/ai'

/** What the editor opens with: a saved lesson, a proposal, or a lead's traits. */
export interface LessonSeed {
  id?: number; conditions: Record<string, string>; win?: number; answer?: number
  note?: string; source?: 'manual' | 'chat' | 'brief' | 'review'
}

type Choice = { v: string; label: string }
// traits with a handful of values are picked; the rest are typed (or picked from what is on file)
const CHOICES: Record<string, Choice[]> = {
  website: [{ v: 'none', label: 'no website' }, { v: 'social', label: 'social page only' }, { v: 'site', label: 'has a website' }],
  phone: [{ v: 'mobile', label: 'mobile' }, { v: 'landline', label: 'landline' }, { v: 'voip', label: 'VoIP' }],
  tier: [{ v: 'A', label: 'A' }, { v: 'B', label: 'B' }, { v: 'C', label: 'C' }],
  last_outcome: [
    { v: 'none', label: 'never called' }, { v: 'no_answer', label: 'no answer' }, { v: 'voicemail', label: 'voicemail' },
    { v: 'busy_failed', label: 'busy / failed' }, { v: 'disconnected', label: 'disconnected' }, { v: 'gatekeeper_end', label: 'gatekeeper' },
    { v: 'dm_not_in', label: 'decision maker not in' }, { v: 'callback', label: 'callback' }, { v: 'email_requested', label: 'email requested' },
    { v: 'not_interested_soft', label: 'soft no' }, { v: 'not_interested_hard', label: 'hard no' }, { v: 'has_provider', label: 'has a provider' },
    { v: 'language_barrier', label: 'language barrier' }, { v: 'wrong_number', label: 'wrong number' },
  ],
}
// 0047: a number trait takes any range typed, or one of these picked
const RANGE_PICKS: Record<string, string[]> = {
  dials: ['0', '1', '2', '3+', '5+'], pickups: ['0', '1+'], days_since: ['<3', '3-7', '8-30', '30+'],
  reviews: ['0', '1-9', '10-49', '50+'], rating: ['<4', '4-4.4', '4.5+'], score: ['<40', '40-59', '60-79', '80+'],
}
const TYPED_HINT: Record<string, string> = {
  trade: 'add a trade', state: 'add a state (FL)', area: 'add an area code (305)', source: 'add a source',
  city: 'add a city (Austin)', name_has: 'add a word (llc)', intent: 'add a signal',
}
const STATES = 'AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'.split(' ')

const values = (s: string | undefined) => (s ?? '').split(',').map((x) => x.trim()).filter(Boolean)
const isRange = (k: string) => RANGE_KINDS.includes(k)

/** A value as the database keeps it: ">= 3" is 3+, "<= 2" is 0-2, "3 to 5" is 3-5. */
function tidy(k: string, x: string): string {
  const t = x.trim()
  if (k === 'state') return t.toUpperCase()
  if (isRange(k)) {
    return t.toLowerCase().replace(/\s/g, '').replace(/^(?:>=|=>)(.+)$/, '$1+').replace(/^(?:<=|=<)(.+)$/, '0-$1')
      .replace(/^(.+?)(?:to|–|—)(.+)$/, '$1-$2').replace(/^(.+?)(?:ormore|orabove|andup|andabove|plus)$/, '$1+')
  }
  if (k === 'city' || k === 'name_has') return t.toLowerCase().replace(/\s+/g, ' ')
  return t.toLowerCase().replace(/\s+/g, '_')
}
function shown(k: string, v: string): string {
  if (k === 'trade' || k === 'intent') return word(v)
  if (k === 'city') return v.replace(/(^|[\s-])\w/g, (m) => m.toUpperCase())
  if (k === 'name_has') return `“${v}”`
  return v
}

interface Fit { leads: number; dials: number; convos: number; wins: number; win_lift: number; answer_lift: number }

/** 0044: teach the AI a lesson, or change one. 0047: about the calls so far too, any number as a range. */
export default function AiLessonEditor({ seed, onClose, onSaved }: {
  seed: LessonSeed; onClose: () => void; onSaved: (msg: string) => void
}) {
  const [cond, setCond] = useState<Record<string, string>>(seed.conditions)
  const [effect, setEffect] = useState(seed.win != null ? effectKey(seed.win) : 'more')
  const [pickup, setPickup] = useState(seed.answer != null ? pickupKey(seed.answer) : 'same')
  const [note, setNote] = useState(seed.note ?? '')
  const [typing, setTyping] = useState<Record<string, string>>({})
  const [known, setKnown] = useState<{ trade: { key: string; n: number }[]; source: { key: string; n: number }[]; intent: Choice[] }>(
    { trade: [], source: [], intent: [] })
  const [fit, setFit] = useState<{ key: string; fit?: Fit; err?: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const boxRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    boxRef.current?.focus()
    let live = true
    Promise.all([
      supabase.rpc('lead_categories'), supabase.rpc('lead_sources'),
      supabase.from('intents_catalog').select('key, label').order('priority'),
    ]).then(([t, s, i]) => {
      if (!live) return
      setKnown({
        trade: (t.data ?? []) as { key: string; n: number }[], source: (s.data ?? []) as { key: string; n: number }[],
        intent: ((i.data ?? []) as { key: string; label: string }[]).map((x) => ({ v: x.key, label: x.label })),
      })
    })
    return () => { live = false }
  }, [])

  function put(k: string, vs: string[]) { setCond((c) => ({ ...c, [k]: [...new Set(vs)].join(',') })) }
  function toggle(k: string, v: string) {
    const cur = values(cond[k])
    put(k, cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v])
  }
  function addTyped(k: string) {
    const add = (typing[k] ?? '').split(',').map((x) => tidy(k, x)).filter(Boolean)
    if (!add.length) return
    put(k, [...values(cond[k]), ...add])
    setTyping((t) => ({ ...t, [k]: '' }))
  }
  function drop(k: string) { setCond((c) => { const n = { ...c }; delete n[k]; return n }) }

  const clean = Object.fromEntries(Object.entries(cond).filter(([, v]) => values(v).length)) as Record<string, string>
  const win = EFFECTS.find((e) => e.key === effect)?.win ?? 1
  const answer = PICKUPS.find((p) => p.key === pickup)?.answer ?? 1

  // what the lesson fits, asked half a second after the traits stop changing
  const fitKey = JSON.stringify(clean)
  useEffect(() => {
    if (fitKey === '{}') return
    let live = true
    const id = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc('ai_lesson_preview', { p_conditions: JSON.parse(fitKey) })
      if (live) setFit({ key: fitKey, fit: error ? undefined : (data as Fit), err: error?.message })
    }, 500)
    return () => { live = false; window.clearTimeout(id) }
  }, [fitKey])

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

  function picked(k: string, choices: Choice[]) {
    // a value from elsewhere (a proposal, an older lesson) that is not among the choices still shows, and can go
    const extra = values(cond[k]).filter((v) => !choices.some((c) => c.v === v))
    return (
      <>
        {choices.map((c) => {
          const on = values(cond[k]).includes(c.v)
          return <button key={c.v} type="button" className={`choice ${on ? 'sel' : ''}`} aria-pressed={on} onClick={() => toggle(k, c.v)}>{c.label}</button>
        })}
        {extra.map((v) => (
          <span key={v} className="choice sel">{shown(k, v)}
            <button type="button" className="chipx" aria-label={`Remove ${v}`} onClick={() => toggle(k, v)}>×</button>
          </span>
        ))}
      </>
    )
  }

  function typed(k: string) {
    const picks = (RANGE_PICKS[k] ?? []).filter((p) => !values(cond[k]).includes(p))
    const hint = isRange(k) ? (values(cond[k]).length || picks.length ? 'or type: 2-4, 3+, <3' : 'a range: 3, 2-4, 3+, <3') : TYPED_HINT[k]
    return (
      <>
        {values(cond[k]).map((v) => (
          <span key={v} className="choice sel">
            {shown(k, v)}
            <button type="button" className="chipx" aria-label={`Remove ${v}`}
              onClick={() => put(k, values(cond[k]).filter((x) => x !== v))}>×</button>
          </span>
        ))}
        {picks.map((p) => (
          <button key={p} type="button" className="choice pick" aria-label={`${KIND_LABEL[k]}: add ${p}`} onClick={() => put(k, [...values(cond[k]), p])}>{p}</button>
        ))}
        <input className="traitadd" value={typing[k] ?? ''} placeholder={hint} aria-label={`${KIND_LABEL[k]}: ${hint}`}
          list={['trade', 'source', 'state'].includes(k) ? `ai-known-${k}` : undefined}
          onChange={(e) => setTyping((t) => ({ ...t, [k]: e.target.value }))}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ',') { e.preventDefault(); addTyped(k) } }}
          onBlur={() => addTyped(k)} />
      </>
    )
  }

  const choicesFor = (k: string): Choice[] | null => (k === 'intent' ? (known.intent.length ? known.intent : null) : CHOICES[k] ?? null)
  const shownFit = fitKey !== '{}' && fit?.key === fitKey ? fit : null

  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="popup lessonform" ref={boxRef} tabIndex={-1} role="dialog" aria-modal="true" aria-label="Teach a lesson"
        onKeyDown={(e) => { if (e.key === 'Escape') onClose() }}>
        <h3>{seed.id ? 'Change this lesson' : 'Teach the AI a lesson'}</h3>
        <p className="muted small" style={{ marginTop: 0 }}>
          A lesson moves the score of every lead that has <b>all</b> of these traits, on top of what the calls say. A trait can be about
          the business or about its calls so far (times called, times picked up, how the last call ended), and any number can be a range:
          3, 2-4, 3+ or &lt;3. It reaches the scores within a minute, and it's checked against the last 90 days of calls, each judged by
          the lead's history at the time, so you can see whether the floor's record agrees.
        </p>

        <div className="kpilabel">When a lead has all of these</div>
        {Object.keys(cond).length === 0 && <p className="muted small" style={{ margin: '4px 0' }}>No traits yet: add one below.</p>}
        {Object.keys(cond).map((k) => {
          const choices = choicesFor(k)
          return (
            <div className="traitrow" key={k}>
              <span className="traitname">{KIND_LABEL[k] ?? k}</span>
              <span className="traitvals">{choices ? picked(k, choices) : typed(k)}</span>
              <button type="button" className="btn ghost small" onClick={() => drop(k)}>remove</button>
            </div>
          )
        })}
        <datalist id="ai-known-trade">{known.trade.map((t) => <option key={t.key} value={t.key}>{word(t.key)} ({t.n.toLocaleString()})</option>)}</datalist>
        <datalist id="ai-known-source">{known.source.map((t) => <option key={t.key} value={t.key}>{t.key} ({t.n.toLocaleString()})</option>)}</datalist>
        <datalist id="ai-known-state">{STATES.map((s) => <option key={s} value={s} />)}</datalist>
        <select className="traitpick" value="" aria-label="Add a trait"
          onChange={(e) => { if (e.target.value) setCond((c) => ({ ...c, [e.target.value]: '' })) }}>
          <option value="">+ add a trait</option>
          {LESSON_GROUPS.map((g) => (
            <optgroup key={g.label} label={g.label}>
              {g.kinds.filter((k) => !(k in cond)).map((k) => <option key={k} value={k}>{KIND_LABEL[k]}</option>)}
            </optgroup>
          ))}
        </select>

        {fitKey !== '{}' && (
          shownFit?.err ? <div className="warnline" role="status">Not valid yet: {shownFit.err}</div>
            : shownFit?.fit ? (
              <p className={`lessonfits ${shownFit.fit.leads ? '' : 'none'}`} role="status">
                {shownFit.fit.leads
                  ? <>Fits <b>{shownFit.fit.leads.toLocaleString()} lead{shownFit.fit.leads === 1 ? '' : 's'}</b> in play now. </>
                  : <><b>Fits no lead in play right now.</b> </>}
                {shownFit.fit.dials
                  ? <>Dials like these in the last 90 days: {shownFit.fit.dials.toLocaleString()}, {shownFit.fit.convos.toLocaleString()} conversation{shownFit.fit.convos === 1 ? '' : 's'},
                    {' '}{shownFit.fit.wins} win{shownFit.fit.wins === 1 ? '' : 's'} ({lift(shownFit.fit.win_lift)} the floor's win rate, {lift(shownFit.fit.answer_lift)} its pickups)
                    {shownFit.fit.dials < 50 ? ': too few to tell yet' : ''}.</>
                  : <>No dials like these in the last 90 days, so the calls can't check it yet.</>}
              </p>
            ) : <p className="lessonfits" role="status">Checking what it fits…</p>
        )}

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
          placeholder="In your words, e.g. “After three tries with no pickup they never answer: the number is dead or they screen us.”" />

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
