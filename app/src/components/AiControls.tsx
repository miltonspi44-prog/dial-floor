// 0044: the small controls the AI page teaches with: a verdict on a lead, a word
// on a finding, and a lesson Gemini proposed, saved in one click.
import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { draftMults, effectText, traitsText } from '../lib/ai'
import type { AiCorrection, AiLesson, AiLessonDraft, AiMark } from '../lib/types'
import type { LessonSeed } from './AiLessonEditor'

/** good or bad, with an optional why; on a lead still to call it moves the score. */
export function MarkControl({ leadId, mark, onDone, won }: {
  leadId: number; mark: AiMark | null | undefined; onDone: (msg: string) => void; won?: boolean
}) {
  const [open, setOpen] = useState<'good' | 'bad' | null>(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)

  async function save(verdict: 'good' | 'bad' | null) {
    setBusy(true)
    const { error } = await supabase.rpc('ai_mark_lead', { p_lead: leadId, p_verdict: verdict, p_note: verdict ? note : null })
    setBusy(false)
    if (error) { onDone(error.message); return }
    setOpen(null)
    setNote('')
    onDone(!verdict ? 'Verdict cleared' : won ? 'Noted: Gemini reads why from now on'
      : `Marked a ${verdict} lead: its score follows within a minute`)
  }

  if (open) {
    return (
      <span className="markform">
        <input autoFocus value={note} maxLength={600} onChange={(e) => setNote(e.target.value)}
          placeholder={open === 'good' ? (won ? 'why did it convert?' : 'why is it a good lead? (optional)') : 'why is it a bad lead? (optional)'}
          aria-label={`Why is it a ${open} lead`}
          onKeyDown={(e) => { if (e.key === 'Enter') save(open); if (e.key === 'Escape') setOpen(null) }} />
        <button className="btn small primary" disabled={busy} onClick={() => save(open)}>Save</button>
        <button className="btn ghost small" onClick={() => setOpen(null)}>Cancel</button>
      </span>
    )
  }
  if (mark) {
    return (
      <span className="markshow">
        <span className={`tag ${mark.verdict === 'good' ? 'hot' : 'bad'}`}>{mark.verdict} lead</span>
        {mark.note && <span className="muted small">“{mark.note}”</span>}
        <button className="copybtn" disabled={busy} onClick={() => save(null)}>clear</button>
      </span>
    )
  }
  return (
    <span className="markbtns">
      <button className="btn ghost small" title={won ? 'Tell the AI why it converted' : 'A good lead: doubles its chance'} onClick={() => setOpen('good')}>
        {won ? 'say why it won' : 'good lead'}
      </button>
      {!won && <button className="btn ghost small" title="A bad lead: quarters its chance" onClick={() => setOpen('bad')}>bad lead</button>}
    </span>
  )
}

/** right or wrong on one of Gemini's findings; wrong asks why. Gemini reads both. */
export function CorrectionControl({ briefId, item, correction, onDone }: {
  briefId: number; item: string; correction: AiCorrection | undefined; onDone: (msg: string) => void
}) {
  const [open, setOpen] = useState(false)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)

  async function save(verdict: 'right' | 'wrong') {
    setBusy(true)
    const { error } = await supabase.rpc('ai_correct', { p_brief: briefId, p_item: item, p_verdict: verdict, p_note: verdict === 'wrong' ? note : null })
    setBusy(false)
    if (error) { onDone(error.message); return }
    setOpen(false)
    setNote('')
    onDone(verdict === 'right' ? 'Noted: right' : 'Noted: Gemini will not repeat it without new evidence')
  }
  async function undo() {
    if (!correction) return
    setBusy(true)
    const { error } = await supabase.rpc('ai_correction_remove', { p_id: correction.id })
    setBusy(false)
    onDone(error ? error.message : 'Taken back')
  }

  if (correction) {
    return (
      <span className="corrshow">
        <span className={`tag ${correction.verdict === 'right' ? 'hot' : 'bad'}`}>you: {correction.verdict}</span>
        {correction.note && <span className="muted small">“{correction.note}”</span>}
        <button className="copybtn" disabled={busy} onClick={undo}>undo</button>
      </span>
    )
  }
  if (open) {
    return (
      <span className="markform">
        <input autoFocus value={note} maxLength={600} onChange={(e) => setNote(e.target.value)} placeholder="what's wrong with it?"
          aria-label="What's wrong with this finding"
          onKeyDown={(e) => { if (e.key === 'Enter') save('wrong'); if (e.key === 'Escape') setOpen(false) }} />
        <button className="btn small primary" disabled={busy} onClick={() => save('wrong')}>Save</button>
        <button className="btn ghost small" onClick={() => setOpen(false)}>Cancel</button>
      </span>
    )
  }
  return (
    <span className="corrbtns">
      <button className="copybtn" disabled={busy} onClick={() => save('right')} title="Right: Gemini keeps it in mind">right</button>
      <button className="copybtn" disabled={busy} onClick={() => setOpen(true)} title="Wrong: tell Gemini why">wrong</button>
    </span>
  )
}

const sameTraits = (a: Record<string, string>, b: Record<string, string>) => {
  const norm = (c: Record<string, string>) => JSON.stringify(Object.keys(c).sort().map((k) => [k, c[k].split(',').sort().join(',')]))
  return norm(a) === norm(b)
}

/** A lesson Gemini proposed: saved as it is in one click, or changed first. */
export function ProposedLesson({ draft, source, taught, onSaved, onEdit }: {
  draft: AiLessonDraft; source: 'chat' | 'brief'; taught: AiLesson[]
  onSaved: (msg: string) => void; onEdit: (seed: LessonSeed) => void
}) {
  const [busy, setBusy] = useState(false)
  const { win, answer } = draftMults(draft)
  const seed: LessonSeed = { conditions: draft.conditions, win, answer, note: draft.why, source }
  const already = taught.find((l) => sameTraits(l.conditions, draft.conditions))

  async function save() {
    if (draft.why.trim().length < 3) { onEdit(seed); return }
    setBusy(true)
    const { error } = await supabase.rpc('ai_lesson_save', {
      p_id: null, p_conditions: draft.conditions, p_win: win, p_answer: answer, p_note: draft.why.trim(), p_source: source,
    })
    setBusy(false)
    onSaved(error ? error.message : 'Lesson saved: the scores follow within a minute')
  }

  return (
    <div className="proposal">
      <div><span className="kpilabel">Proposed lesson</span> <b>{traitsText(draft.conditions)}</b> → {effectText(win, answer)}</div>
      {draft.why && <div className="muted small">{draft.why}</div>}
      <div className="actionrow" style={{ marginTop: 6 }}>
        {already ? (
          <span className="small">
            <span className="tag hot">taught</span> You have a lesson on these traits: {effectText(already.win_mult, already.answer_mult)}.{' '}
            <button className="copybtn" onClick={() => onEdit({ id: already.id, conditions: already.conditions, win, answer, note: already.note, source })}>change it to this</button>
          </span>
        ) : (
          <>
            <button className="btn small primary" disabled={busy} onClick={save}>Save this lesson</button>
            <button className="btn ghost small" onClick={() => onEdit(seed)}>Change it first</button>
          </>
        )}
      </div>
    </div>
  )
}
