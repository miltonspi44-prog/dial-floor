import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { rulesText } from '../lib/ai'
import type { AiChatThread, AiLesson, AiListIdea } from '../lib/types'
import { ProposedLesson } from './AiControls'
import type { LessonSeed } from './AiLessonEditor'

const STARTERS = [
  'Why do you rank Washington remodelers so high?',
  'Concrete contractors in Texas almost never buy from us: most have a nephew who builds websites.',
  'Which of my lessons does the data disagree with?',
  'What do the wins you rated low have in common?',
]

/** 0044: a conversation with Gemini about the floor. Each message goes through
 *  ai_chat_send (the database carries it to floor-ai); the reply lands in the
 *  thread, looked for every 3 seconds while it is due. */
export default function AiChat({ taught, say, onSaved, onEdit, buildIdea }: {
  taught: AiLesson[]; say: (m: string) => void; onSaved: (m: string) => void
  onEdit: (seed: LessonSeed) => void; buildIdea: (idea: AiListIdea) => void
}) {
  const [t, setT] = useState<AiChatThread | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [text, setText] = useState('')
  const [fresh, setFresh] = useState(false)
  const [sending, setSending] = useState(false)
  const [late, setLate] = useState(false)
  const logRef = useRef<HTMLDivElement>(null)

  const load = useCallback(async (thread?: number) => {
    const { data, error } = await supabase.rpc('ai_chat_thread', { p_thread: thread ?? null })
    if (error) { setErr(error.message); return null }
    setErr(null)
    setT(data as AiChatThread)
    return data as AiChatThread
  }, [])
  useEffect(() => { load() }, [load])

  // while a reply is due, look for it every 3 seconds, for up to 3 minutes
  const waiting = t?.waiting ?? false
  const thread = t?.thread
  useEffect(() => {
    if (!waiting || thread == null) return
    let n = 0
    const id = window.setInterval(async () => {
      n++
      const f = await load(thread)
      if (!f?.waiting || n >= 60) {
        window.clearInterval(id)
        if (f?.waiting) setLate(true)
      }
    }, 3000)
    return () => window.clearInterval(id)
  }, [waiting, thread, load])

  const count = t?.messages.length ?? 0
  useEffect(() => {
    const el = logRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [count, waiting])

  async function send() {
    const msg = text.trim()
    if (!msg || sending) return
    setSending(true)
    const { data, error } = await supabase.rpc('ai_chat_send', { p_text: msg, p_new: fresh })
    setSending(false)
    if (error) { say(error.message); return }
    const r = data as { ok: boolean; why?: string; thread: number }
    if (!r.ok && r.why?.includes('still answering')) { say(r.why); return }
    setText('')
    setFresh(false)
    setLate(false)
    await load(r.thread)
    if (!r.ok) say(r.why ?? 'The message could not be sent.')
  }

  function newConversation() {
    if (!t) return
    setFresh(true)
    setLate(false)
    setT({ thread: t.threads + 1, threads: t.threads, messages: [], waiting: false })
  }

  if (err) return <div className="card aichat"><div className="warnline" role="alert">The conversation could not load: {err}</div></div>
  if (!t) return <div className="card aichat muted small">Loading the conversation…</div>

  const shown = fresh ? t.threads + 1 : t.thread
  const total = Math.max(t.threads, shown)
  return (
    <div className="card aichat">
      <div className="sectionhead" style={{ margin: '0 0 6px' }}>
        <h3>Talk to the AI</h3>
        <span className="chatnav">
          {total > 1 && (
            <>
              <button className="btn ghost small" disabled={fresh || shown <= 1} aria-label="Earlier conversation" onClick={() => load(shown - 1)}>‹</button>
              <span className="muted small">conversation {shown} of {total}</span>
              <button className="btn ghost small" disabled={fresh || shown >= t.threads} aria-label="Later conversation" onClick={() => load(shown + 1)}>›</button>
            </>
          )}
          <button className="btn small" disabled={fresh || !t.messages.length || waiting} onClick={newConversation}>New conversation</button>
        </span>
      </div>
      <p className="muted small" style={{ marginTop: 0 }}>
        Ask why it ranks what it ranks, or tell it what you know. It checks you against the calls, says whether the record agrees,
        and turns what you say into a lesson you can save in one click.
      </p>

      <div className="chatlog" ref={logRef} aria-live="polite">
        {t.messages.length === 0 && !waiting && (
          <div className="starters">
            <span className="muted small">Try:</span>
            {STARTERS.map((s) => <button key={s} className="starter" onClick={() => setText(s)}>{s}</button>)}
          </div>
        )}
        {t.messages.map((m) => m.role === 'manager' ? (
          <div key={m.id} className="bubble me">
            <div className="who">{m.author ?? 'You'} · {new Date(m.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</div>
            {m.text}
          </div>
        ) : (
          <div key={m.id} className="bubble ai">
            <div className="who">Gemini{m.model ? ` · ${m.model}` : ''}</div>
            {m.error ? <div className="warnline">It couldn't answer: {m.error}</div> : m.text}
            {(m.proposals.lessons ?? []).map((d, i) => (
              <ProposedLesson key={`l${i}`} draft={d} source="chat" taught={taught} onSaved={onSaved} onEdit={onEdit} />
            ))}
            {(m.proposals.lists ?? []).map((l, i) => (
              <div key={`s${i}`} className="proposal">
                <span className="kpilabel">List idea</span> <b>{l.name}</b> <span className="muted small">{rulesText(l.rules)}</span>
                <button className="btn ghost small" style={{ marginLeft: 6 }} onClick={() => buildIdea(l)}>build it</button>
                {l.why && <div className="muted small">{l.why}</div>}
              </div>
            ))}
          </div>
        ))}
        {waiting && <div className="bubble ai thinking">Gemini is reading the floor and what you've taught it… usually under a minute</div>}
        {late && <div className="warnline">No reply came back within three minutes. Send the message again, or check that floor-ai is deployed.</div>}
      </div>

      <div className="chatinput">
        <textarea rows={2} value={text} maxLength={2000} disabled={waiting} aria-label="Message to the AI"
          placeholder="Ask, or teach it: “Concrete guys in Texas never buy — most have a nephew who builds sites.”"
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); send() } }} />
        <button className="btn primary" disabled={sending || waiting || !text.trim()} onClick={send}>{sending ? 'Sending…' : 'Send'}</button>
      </div>
      <div className="muted small">
        Ctrl+Enter sends. Gemini sees the floor's numbers and everything you've taught it, never a lead's name, number or call notes.
      </div>
    </div>
  )
}
