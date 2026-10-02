import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { Battlecard, CardStats } from '../lib/types'

interface Props {
  attemptId: number | null
  agentId: string | undefined
}

// below this many uses a counter's record is too thin to rank on
const MIN_USES = 5

/** Objection buttons (D1). Tap the objection you hear, then the counter you used:
 *  counters with a track record come first, ranked by the calls they kept alive. */
export default function Battlecards({ attemptId, agentId }: Props) {
  const [cards, setCards] = useState<Battlecard[]>([])
  const [stats, setStats] = useState<Map<number, CardStats>>(new Map())
  const [open, setOpen] = useState<number | null>(null)
  const [used, setUsed] = useState<Set<string>>(new Set()) // `${card}:${counter}` said on this call
  const [usedFor, setUsedFor] = useState<number | null>(attemptId)

  // a new call starts with nothing tapped
  if (usedFor !== attemptId) {
    setUsedFor(attemptId)
    setUsed(new Set())
    setOpen(null)
  }

  useEffect(() => {
    supabase.from('battlecards').select('*').eq('active', true).order('sort')
      .then(({ data }) => setCards((data ?? []) as Battlecard[]))
    supabase.rpc('battlecard_stats', { p_days: 90 })
      .then(({ data }) => setStats(new Map(((data ?? []) as CardStats[]).map((s) => [s.card_id, s]))))
  }, [])

  function tapObjection(card: Battlecard) {
    const next = open === card.id ? null : card.id
    setOpen(next)
    // reading a card between calls is studying, not an objection heard on a call
    if (next && agentId && attemptId) {
      supabase.from('card_taps').insert({ attempt_id: attemptId, card_id: card.id, agent_id: agentId }).then(() => {})
    }
  }

  function tapCounter(card: Battlecard, text: string) {
    const k = `${card.id}:${text}`
    if (!attemptId || !agentId || used.has(k)) return
    setUsed(new Set(used).add(k))
    supabase.from('card_taps')
      .insert({ attempt_id: attemptId, card_id: card.id, agent_id: agentId, counter: text }).then(() => {})
  }

  function ranked(card: Battlecard) {
    const rec = new Map((stats.get(card.id)?.counters ?? []).map((c) => [c.text, c]))
    return (card.counters as string[])
      .map((text, i) => ({ text, i, uses: rec.get(text)?.uses ?? 0, kept: rec.get(text)?.kept ?? 0 }))
      .sort((a, b) => {
        const ra = a.uses >= MIN_USES ? a.kept / a.uses : -1
        const rb = b.uses >= MIN_USES ? b.kept / b.uses : -1
        return rb - ra || a.i - b.i
      })
  }

  if (!cards.length) return null
  return (
    <div className="card">
      <h4>Objections: tap what you hear</h4>
      {cards.map((c) => (
        <div className="bcard" key={c.id}>
          <button onClick={() => tapObjection(c)} aria-expanded={open === c.id}>{c.objection}</button>
          {open === c.id && (
            <ul className="counters">
              {ranked(c).map((k) => {
                const said = used.has(`${c.id}:${k.text}`)
                return (
                  <li key={k.text}>
                    <button className={`counterbtn ${said ? 'said' : ''}`} disabled={!attemptId}
                      title={attemptId ? 'Tap the one you used: it teaches the ranking' : 'Dial first to record it'}
                      onClick={() => tapCounter(c, k.text)}>
                      {said && <span className="saidmark" aria-label="used">✓ </span>}{k.text}
                    </button>
                    {k.uses >= MIN_USES && <span className="muted small"> kept {k.kept} of {k.uses} calls alive</span>}
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      ))}
      {!attemptId && <div className="muted small">Dial first: counters you tap are recorded on the call.</div>}
    </div>
  )
}
