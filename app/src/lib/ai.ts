// The AI floor's words and numbers, shared by its tabs (0043, 0044, 0047).
import { dispositionLabel } from './types'
import type { AiLesson, AiLessonDraft, AiReason } from './types'

/** "1.4×" — a smoothed rate against the floor's own. */
export function lift(x: number | null | undefined): string {
  return x == null ? '—' : `${x >= 10 ? Math.round(x) : x.toFixed(x >= 2 ? 1 : 2)}×`
}
export function tone(x: number | null | undefined): string {
  return x == null ? '' : x >= 1.15 ? 'up' : x <= 0.87 ? 'down' : ''
}
export function pct(x: number | null | undefined, digits = 1): string {
  return x == null ? '—' : `${(x * 100).toFixed(digits)}%`
}
export function word(s: string): string { return s.replace(/_/g, ' ') }

export const KIND_LABEL: Record<string, string> = {
  trade: 'Trade', state: 'State', area: 'Area code', phone: 'Phone type', website: 'Website', source: 'Source',
  tier: 'Tier', reviews: 'Reviews', score: 'Scraper score',
  // 0047: what else a lesson can name
  city: 'City', rating: 'Google rating', name_has: 'Name has', intent: 'Signal',
  dials: 'Times called', pickups: 'Times picked up', last_outcome: 'Last call ended', days_since: 'Days since last call',
}
/** The traits the model learns from (the AI page's segments). */
export const KINDS = ['trade', 'state', 'area', 'phone', 'website', 'source', 'tier', 'reviews', 'score']
/** 0047: the traits a lesson can name, as the lesson editor groups them. */
export const LESSON_GROUPS: { label: string; kinds: string[] }[] = [
  { label: 'The business', kinds: ['trade', 'state', 'city', 'area', 'source', 'website', 'phone', 'tier', 'reviews', 'rating', 'score', 'name_has', 'intent'] },
  { label: 'Its calls so far', kinds: ['dials', 'pickups', 'last_outcome', 'days_since'] },
]
/** Traits that take number ranges: 3 · 2-4 · 3+ · <3 · >3, several joined by commas. */
export const RANGE_KINDS = ['dials', 'pickups', 'days_since', 'reviews', 'rating', 'score']

/** "3 or more", "2–4", "under 3", "0 or 5 or more" */
export function rangeText(spec: string): string {
  return spec.split(',').map((r) => r.endsWith('+') ? `${r.slice(0, -1)} or more`
    : r.startsWith('<') ? `under ${r.slice(1)}` : r.startsWith('>') ? `over ${r.slice(1)}`
      : r.includes('-') ? r.replace('-', '–') : r).join(' or ')
}
const titled = (x: string) => x.replace(/(^|[\s-])\w/g, (m) => m.toUpperCase())
const times = (spec: string) => (spec === '1' ? 'once' : `${rangeText(spec)} times`)

/** A lesson's effect on the chance of a win; the keys are the ones Gemini proposes with. */
export const EFFECTS: { key: string; label: string; win: number }[] = [
  { key: 'much_more', label: 'much likelier to convert', win: 2 },
  { key: 'more', label: 'likelier to convert', win: 1.5 },
  { key: 'same', label: 'no change to converting', win: 1 },
  { key: 'less', label: 'less likely to convert', win: 0.67 },
  { key: 'much_less', label: 'much less likely to convert', win: 0.4 },
  { key: 'never', label: 'won’t convert', win: 0.1 },
]
export const PICKUPS: { key: string; label: string; answer: number }[] = [
  { key: 'same', label: 'no change to picking up', answer: 1 },
  { key: 'more', label: 'likelier to pick up', answer: 1.3 },
  { key: 'less', label: 'less likely to pick up', answer: 0.75 },
]
/** The effect nearest a saved multiplier. */
export function effectKey(win: number): string {
  return EFFECTS.reduce((a, b) => (Math.abs(Math.log(b.win / win)) < Math.abs(Math.log(a.win / win)) ? b : a)).key
}
export function pickupKey(answer: number): string {
  return PICKUPS.reduce((a, b) => (Math.abs(Math.log(b.answer / answer)) < Math.abs(Math.log(a.answer / answer)) ? b : a)).key
}

const or = (v: string, f: (x: string) => string = (x) => x) => v.split(',').map(f).join(' or ')

/** "Roofing or siding leads in FL with no website" */
export function traitsText(c: Record<string, string>): string {
  const parts: string[] = []
  parts.push(c.trade ? `${or(c.trade, word)} leads` : 'Leads')
  if (c.city) parts.push(`in ${or(c.city, titled)}`)
  if (c.state) parts.push(`in ${or(c.state)}`)
  if (c.area) parts.push(`in area code ${or(c.area)}`)
  if (c.source) parts.push(`from ${or(c.source)}`)
  if (c.tier) parts.push(`in tier ${or(c.tier)}`)
  if (c.name_has) parts.push(`with ${or(c.name_has, (x) => `“${x}”`)} in the name`)
  if (c.website) parts.push(or(c.website, (x) => x === 'none' ? 'with no website' : x === 'social' ? 'with only a social page'
    : x === 'site' ? 'with a website' : `with a ${x} website`))
  if (c.phone) parts.push(`on a ${or(c.phone)} phone`)
  if (c.reviews) parts.push(`with ${rangeText(c.reviews)} reviews`)
  if (c.rating) parts.push(`rated ${rangeText(c.rating)} stars`)
  if (c.score) parts.push(`with a scraper score of ${rangeText(c.score)}`)
  if (c.intent) parts.push(`showing ${or(c.intent, word)}`)
  // the calls so far, set off by commas: "Leads in TX, called 3 or more times, that never picked up"
  const calls: string[] = []
  if (c.dials) calls.push(c.dials === '0' ? 'never called' : `called ${times(c.dials)}`)
  if (c.pickups) calls.push(c.pickups === '0' ? 'that never picked up' : `that picked up ${times(c.pickups)}`)
  if (c.last_outcome) {
    calls.push(`whose last call was ${or(c.last_outcome, (x) => (x === 'none' ? 'none yet' : dispositionLabel(x).toLowerCase()))}`)
  }
  if (c.days_since) calls.push(`last called ${rangeText(c.days_since)} days ago`)
  const out = parts.join(' ') + (calls.length ? `${parts.length > 1 ? ', ' : ' '}${calls.join(', ')}` : '')
  return out.charAt(0).toUpperCase() + out.slice(1)
}

/** "likelier to convert (1.5×), less likely to pick up (0.75×)" */
export function effectText(win: number, answer: number): string {
  const bits: string[] = []
  if (win !== 1) bits.push(`${EFFECTS.find((e) => e.key === effectKey(win))!.label} (${lift(win)})`)
  if (answer !== 1) bits.push(`${PICKUPS.find((p) => p.key === pickupKey(answer))!.label} (${lift(answer)})`)
  return bits.join(', ') || 'no change'
}

export function draftMults(d: AiLessonDraft): { win: number; answer: number } {
  return {
    win: EFFECTS.find((e) => e.key === d.effect)?.win ?? 1,
    answer: PICKUPS.find((p) => p.key === d.pickup)?.answer ?? 1,
  }
}

/** Whether the floor's own record bears a lesson out, from its stats. */
export function lessonCheck(l: AiLesson): { text: string; tone: '' | 'up' | 'down' } {
  const s = l.stats
  if (!s || l.pending) return { text: 'checking it against the last 90 days of calls…', tone: '' }
  const record = `the leads it describes: ${s.dials.toLocaleString()} dials, ${s.wins} win${s.wins === 1 ? '' : 's'} (${lift(s.win_lift)} the floor's rate)`
    + (l.answer_mult !== 1 ? `, ${lift(s.answer_lift)} the floor's pickups` : '')
  if (s.dials < 50) return { text: `${record}: too few calls to tell yet`, tone: '' }
  const [mult, got] = l.win_mult !== 1 ? [l.win_mult, s.win_lift] : [l.answer_mult, s.answer_lift]
  if ((mult > 1 && got >= 1.1) || (mult < 1 && got <= 0.9)) return { text: `${record}: the data agrees`, tone: 'up' }
  if ((mult > 1 && got < 0.9) || (mult < 1 && got > 1.1)) return { text: `${record}: the data disagrees`, tone: 'down' }
  return { text: `${record}: the data is about even`, tone: '' }
}

export function reasonText(r: AiReason): string {
  if (r.kind === 'lesson') {
    return `your lesson “${r.value}”: ${lift(r.win)} wins${r.answer != null && r.answer !== 1 ? `, ${lift(r.answer)} pickups` : ''}`
  }
  if (r.kind === 'mark') return `you marked it a ${r.value} lead${r.note ? ` (“${r.note}”)` : ''}: ${lift(r.win)}`
  const what = r.kind === 'trade' ? word(r.value) : r.kind === 'area' ? `area ${r.value}`
    : r.kind === 'website' ? (r.value === 'none' ? 'no website' : `${r.value} website`)
      : r.kind === 'phone' ? `${r.value} phone` : r.kind === 'reviews' ? `${r.value} reviews`
        : r.kind === 'score' ? `score ${r.value}` : r.kind === 'tier' ? `tier ${r.value}` : r.value
  return `${what}: ${lift(r.win)} wins, ${lift(r.answer)} pickups`
}

/** The traits of a lead worth teaching from: what a lesson usually turns on. */
export function teachableTraits(t: Record<string, string> | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  for (const k of ['trade', 'state', 'source', 'website', 'phone']) {
    const v = t?.[k]
    if (v && v !== '(none)' && v !== 'unknown') out[k] = v
  }
  return out
}

/** A list's rules, in words. */
export function rulesText(rules: Record<string, string | number>): string {
  return Object.entries(rules).map(([k, v]) => `${word(k)} ${k === 'category' ? word(String(v)) : v}`).join(' · ')
}
