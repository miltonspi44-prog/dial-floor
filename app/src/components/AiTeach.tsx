import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { effectText, lessonCheck, traitsText, word } from '../lib/ai'
import type { AiLesson, AiListIdea, AiTeachData } from '../lib/types'
import AiChat from './AiChat'
import type { LessonSeed } from './AiLessonEditor'

const FROM: Record<string, string> = { chat: 'the conversation', brief: 'its analysis', review: 'a mistake you reviewed' }
const day = (s: string) => new Date(s).toLocaleDateString([], { month: 'short', day: 'numeric' })

/** 0044: the AI page's "Talk & teach" tab. */
export default function AiTeach({ teach, say, changed, openEditor, buildIdea }: {
  teach: AiTeachData; say: (m: string) => void; changed: (m: string) => void
  openEditor: (seed: LessonSeed) => void; buildIdea: (idea: AiListIdea) => void
}) {
  const [busy, setBusy] = useState(false)

  async function setLesson(l: AiLesson, active: boolean, remove = false) {
    if (remove && !window.confirm(`Remove this lesson?\n\n${traitsText(l.conditions)}: ${effectText(l.win_mult, l.answer_mult)}\n\nThe scores go back to what the calls say within a minute. It stays on record.`)) return
    setBusy(true)
    const { error } = await supabase.rpc('ai_lesson_set', { p_id: l.id, p_active: active, p_remove: remove })
    setBusy(false)
    changed(error ? error.message : remove ? 'Lesson removed: the scores follow within a minute'
      : active ? 'Lesson back on: the scores follow within a minute' : 'Lesson paused: the scores follow within a minute')
  }
  async function clearMark(leadId: number) {
    setBusy(true)
    const { error } = await supabase.rpc('ai_mark_lead', { p_lead: leadId, p_verdict: null, p_note: null })
    setBusy(false)
    changed(error ? error.message : 'Verdict cleared')
  }
  async function dropCorrection(id: number) {
    setBusy(true)
    const { error } = await supabase.rpc('ai_correction_remove', { p_id: id })
    setBusy(false)
    changed(error ? error.message : 'Taken back')
  }

  const r = teach.rescore
  const rescoring = r.wanted && (!r.scored || new Date(r.wanted) > new Date(r.scored))
  return (
    <div className="aiteach">
      {rescoring && <div className="card rescoring" role="status">Re-scoring every lead with your latest teaching… usually within a minute.</div>}

      <AiChat taught={teach.lessons} say={say} onSaved={changed} onEdit={openEditor} buildIdea={buildIdea} />

      <div className="sectionhead">
        <h3>What you've taught it</h3>
        <span className="muted small">lessons move every lead with all their traits, on top of what the calls say</span>
        <button className="btn small primary" style={{ marginLeft: 'auto' }} onClick={() => openEditor({ conditions: {} })}>Teach a lesson</button>
      </div>
      <div className="card">
        {teach.lessons.length ? (
          <ul className="lessonlist">
            {teach.lessons.map((l) => {
              const chk = lessonCheck(l)
              return (
                <li key={l.id} className={l.active ? '' : 'paused'}>
                  <div>
                    <b>{traitsText(l.conditions)}</b> → {effectText(l.win_mult, l.answer_mult)}
                    {!l.active && <span className="tag off" style={{ marginLeft: 6 }}>paused</span>}
                  </div>
                  <div className="small">
                    “{l.note}” <span className="muted">— {l.author ?? 'a manager'}, {day(l.created_at)}{FROM[l.source] ? ` · from ${FROM[l.source]}` : ''}</span>
                  </div>
                  <div className={`small check ${chk.tone}`}>
                    {l.active && l.stats && !l.pending ? `Moves ${l.stats.leads.toLocaleString()} lead${l.stats.leads === 1 ? '' : 's'} still to call · ` : ''}{chk.text}
                  </div>
                  <div className="actionrow" style={{ marginTop: 4 }}>
                    <button className="btn ghost small" disabled={busy}
                      onClick={() => openEditor({ id: l.id, conditions: l.conditions, win: l.win_mult, answer: l.answer_mult, note: l.note })}>change</button>
                    <button className="btn ghost small" disabled={busy} onClick={() => setLesson(l, !l.active)}>{l.active ? 'pause' : 'turn back on'}</button>
                    <button className="btn ghost small" disabled={busy} onClick={() => setLesson(l, false, true)}>remove</button>
                  </div>
                </li>
              )
            })}
          </ul>
        ) : (
          <p className="muted small" style={{ margin: 0 }}>
            No lessons yet. Teach one with the button, save one Gemini proposes in the conversation or its analysis, or teach from a
            mistake on the “Where it went wrong” tab.
          </p>
        )}
      </div>

      <div className="sectionhead">
        <h3>Leads you've judged</h3>
        <span className="muted small">a good lead doubles its chance, a bad one quarters it; Gemini reads why</span>
      </div>
      <div className="card">
        {teach.marks.length ? (
          <div className="tablewrap">
            <table className="data">
              <thead><tr><th>Lead</th><th>Trade</th><th>Your word</th><th>Why</th><th /></tr></thead>
              <tbody>
                {teach.marks.map((m) => (
                  <tr key={m.lead_id}>
                    <td>{m.name}<div className="muted small">{[m.city, m.state].filter(Boolean).join(', ')}</div></td>
                    <td>{word(m.trade)}</td>
                    <td>
                      <span className={`tag ${m.verdict === 'good' ? 'hot' : 'bad'}`}>{m.verdict}</span>
                      {m.won && <span className="tag">won</span>}
                    </td>
                    <td className="small">{m.note ?? <span className="muted">—</span>}<div className="muted small">{m.author ?? 'a manager'}, {day(m.at)}</div></td>
                    <td><button className="btn ghost small" disabled={busy} onClick={() => clearMark(m.lead_id)}>clear</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="muted small" style={{ margin: 0 }}>
            None yet. Mark a lead good or bad from the likeliest-to-convert table on the Analysis tab, or from a mistake on the next tab.
          </p>
        )}
      </div>

      <div className="sectionhead">
        <h3>Your word on its analysis</h3>
        <span className="muted small">Gemini reads these before every analysis and reply, and won't repeat a finding you marked wrong without new evidence</span>
      </div>
      <div className="card">
        {teach.corrections.length ? (
          <ul className="lessonlist">
            {teach.corrections.map((c) => (
              <li key={c.id}>
                <div><span className={`tag ${c.verdict === 'right' ? 'hot' : 'bad'}`}>{c.verdict}</span> {c.item.length > 220 ? `${c.item.slice(0, 220)}…` : c.item}</div>
                {c.note && <div className="small">“{c.note}”</div>}
                <div className="muted small">
                  {c.author ?? 'a manager'}, {day(c.at)}{' '}
                  <button className="copybtn" disabled={busy} onClick={() => dropCorrection(c.id)}>take back</button>
                </div>
              </li>
            ))}
          </ul>
        ) : (
          <p className="muted small" style={{ margin: 0 }}>None yet. Mark its findings right or wrong on the Analysis tab.</p>
        )}
      </div>
    </div>
  )
}
