/** D5: the manager's library of talk tracks and saved calls. */
import { supabase } from './supabase'
import { dispositionLabel, talkTime, type CallTap } from './types'

export const SCENARIO_SUGGESTIONS = [
  'Opener', 'Website pitch', 'Google visibility pitch', 'AI receptionist pitch',
  'Price objection', 'Callback won', 'Email request', 'Other',
]

export function scenarioFor(disposition: string | null): string {
  switch (disposition) {
    case 'chance_website': return 'Website pitch'
    case 'sale_closed': return 'Google visibility pitch'
    case 'callback': return 'Callback won'
    case 'email_requested': return 'Email request'
    default: return 'Other'
  }
}

/** A call written out the way the A6 call log reads (Fork 1-A: no transcript). */
export function callBody(c: {
  disposition: string | null; duration: number | null; note: string | null; taps: CallTap[]; summary?: string | null
}): string {
  const lines = [`Outcome: ${dispositionLabel(c.disposition)}${c.duration ? ` · talk ${talkTime(c.duration)}` : ''}`]
  for (const t of c.taps) lines.push(`Heard: ${t.objection}${t.counters.length ? ` → said: ${t.counters.join(' / ')}` : ''}`)
  if (c.summary) lines.push(`What was said: ${c.summary}`)
  if (c.note) lines.push(`Note: ${c.note}`)
  return lines.join('\n')
}

export async function saveToLibrary(item: {
  title: string; scenario: string; body: string
  attempt_id?: number | null; lead_name?: string | null; agent_name?: string | null
}) {
  const { data } = await supabase.auth.getSession()
  return supabase.from('library_items').insert({ ...item, created_by: data.session?.user.id ?? null })
}
