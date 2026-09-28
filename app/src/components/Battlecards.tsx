import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { Battlecard } from '../lib/types'

interface Props {
  attemptId: number | null
  agentId: string | undefined
}

/** Objection buttons (D1). A tap logs which objection came up — free analytics. */
export default function Battlecards({ attemptId, agentId }: Props) {
  const [cards, setCards] = useState<Battlecard[]>([])
  const [open, setOpen] = useState<number | null>(null)

  useEffect(() => {
    supabase.from('battlecards').select('*').eq('active', true).order('sort')
      .then(({ data }) => setCards((data ?? []) as Battlecard[]))
  }, [])

  function toggle(card: Battlecard) {
    const next = open === card.id ? null : card.id
    setOpen(next)
    if (next && agentId) {
      supabase.from('card_taps').insert({ attempt_id: attemptId, card_id: card.id, agent_id: agentId }).then(() => {})
    }
  }

  if (!cards.length) return null
  return (
    <div className="card">
      <h4>Objections — tap the one you hear</h4>
      {cards.map((c) => (
        <div className="bcard" key={c.id}>
          <button onClick={() => toggle(c)}>{c.objection}</button>
          {open === c.id && (
            <ul>
              {(c.counters as string[]).map((t, i) => <li key={i}>{t}</li>)}
            </ul>
          )}
        </div>
      ))}
    </div>
  )
}
