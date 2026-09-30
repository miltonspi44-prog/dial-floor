export type Role = 'agent' | 'manager'

export interface Profile {
  id: string
  name: string
  role: Role
  active: boolean
}

export interface Workspace {
  reason: 'callback_due' | 'list' | 'pool' | 'resume'
  lead: LeadRow
  state: Record<string, unknown>
  intents: { key: string; label: string; confidence: number }[]
  history: {
    at: string; agent: string; disposition: string | null; duration: number | null; note: string | null
    /** Zoom's AI call summary, once Zoom has sent it (a few minutes after the call). */
    ai_summary: string | null; next_steps: string | null
    /** A6 call log: the objections tapped on that call and the counters used. */
    taps: CallTap[]
  }[]
  /** D6: the opener this lead gets from the running A/B test (lab switched on). */
  ab?: AbOpener
  /** C4: on the never-answers list — the unanswered tries in their business hours, latest first. */
  missed?: { count: number; times: string[] }
}

export interface CallTap { objection: string; counters: string[] }

export interface AbOpener { test_id: number; test: string; variant: string; text: string }

/** A row of the Floor page's recent-calls table. */
export interface RecentCall {
  id: number
  clicked_at: string
  duration_seconds: number | null
  call_result: string | null
  disposition: string | null
  note: string | null
  matched: boolean
  ai_summary: { summary?: string | null; next_steps?: string | null } | null
  leads: { name: string } | null
  profiles: { name: string } | null
  card_taps: { counter: string | null; battlecards: { objection: string } | null }[]
}

export interface LeadRow {
  id: number
  name: string
  phone_norm: string
  phone_display: string | null
  phone_type: string | null
  category: string | null
  categories: string[] | null
  tier: string | null
  score: number | null
  rating: number | null
  review_count: number | null
  website: string | null
  website_type: string | null
  platform: string | null
  platform_detail: string | null
  email: string | null
  address: string | null
  addr_city: string | null
  addr_state: string | null
  zip: string | null
  tz: string | null
  maps_url: string | null
  extras: Record<string, unknown> | null
}

export interface NextLeadResult {
  empty?: boolean
  hint?: string
  error?: string
  reason?: Workspace['reason']
  lead?: LeadRow
  state?: Record<string, unknown>
  intents?: Workspace['intents']
  history?: Workspace['history']
  ab?: AbOpener
  missed?: Workspace['missed']
  /** Set with reason 'resume': the call this agent started and never logged. */
  attempt_id?: number
  clicked_at?: string
}

export interface FloorRow {
  agent_id: string
  name: string
  role: Role
  status: string
  lead_name: string | null
  phone_display: string | null
  since: string | null
  dials_today: number
  connects_today: number
  handoffs_today: number
  emails_today: number
  /** Last heartbeat/ping; after 5 quiet minutes the view reports the agent offline. */
  last_seen: string | null
}

/** One slice of the funnel: every dial, the ones Zoom says were picked up,
 *  the live conversations the agent logged, and the W/S handoffs. */
export interface FunnelCounts {
  dials: number
  answered: number
  conversations: number
  handoffs: number
}

/** funnel(p_days) — the manager's Funnel page (F1). */
export interface FunnelData {
  from: string
  days: number
  totals: FunnelCounts & { callbacks: number; emails: number; talk_seconds: number }
  by_agent: (FunnelCounts & { agent_id: string; name: string; days: number; talk_seconds: number })[]
  by_source: (FunnelCounts & { source: 'callback' | 'list' | 'pool' | 'untracked'; list: string | null })[]
  by_intent: (FunnelCounts & { intent: string; label: string })[]
  by_hour: (FunnelCounts & { hour: number })[]
}

/** team(): a member as the manager's Team page sees them. */
export interface TeamMember {
  id: string
  name: string
  role: Role
  active: boolean
  email: string | null
  created_at: string
  last_sign_in_at: string | null
  /** scheduled callbacks and active lists still assigned to them */
  callbacks: number
  lists: number
}

/** radar(): the manager's Radar tab (C3 + C4). */
export interface RadarData {
  date: string
  last_run: { date: string; at: string; seasonal: number; lists: number } | null
  per_agent: number
  threshold: number
  callbacks: { due_today: number; overdue: number; by_agent: { name: string; due: number }[] }
  fresh_no_site: { category_key: string; label: string; city: string; state: string; count: number }[]
  never_answers: { total: number; dialable: number; new_this_week: number }
  seasons: { label: string; keys: string[]; open: boolean; opens_next_month: boolean; dialable: number; resting: number }[]
  converting: { kind: 'intent' | 'trade'; label: string; dials: number; rate: number; floor: number; ratio: number }[]
  lists: { list_id: number; agent: string | null; name: string; status: string; total: number; served: number }[]
}

/** Daily per-agent targets from kpi_targets (F4). */
export interface Targets {
  dials: number | null
  connects: number | null
  handoffs: number | null
}

export interface Battlecard {
  id: number
  objection: string
  counters: string[]
  sort: number
  active: boolean
}

/** battlecard_stats(days): how often each objection came up and which counters kept calls alive. */
export interface CardStats {
  card_id: number
  objection: string
  active: boolean
  calls: number
  kept: number
  won: number
  counters: { text: string; uses: number; kept: number; won: number }[]
}

export interface AbVariant { key: string; text: string }

export interface AbTest {
  id: number
  name: string
  variants: AbVariant[]
  status: 'draft' | 'running' | 'stopped'
  started_at: string | null
  stopped_at: string | null
  created_at: string
}

export interface AbResult {
  variant: string
  dials: number
  picked_up: number
  conversations: number
  survived_30s: number
  kept: number
  won: number
}

export interface LibraryItem {
  id: number
  title: string
  scenario: string
  body: string
  attempt_id: number | null
  lead_name: string | null
  agent_name: string | null
  pinned: boolean
  created_at: string
  updated_at: string
}

/** Groups a call's taps into "objection → counters used" (A6 call log). */
export function tapsByObjection(taps: RecentCall['card_taps']): CallTap[] {
  const m = new Map<string, Set<string>>()
  for (const t of taps) {
    const o = t.battlecards?.objection
    if (!o) continue
    if (!m.has(o)) m.set(o, new Set())
    if (t.counter) m.get(o)!.add(t.counter)
  }
  return [...m].map(([objection, cs]) => ({ objection, counters: [...cs] }))
}

/** "2m 05s" / "45s" talk time. */
export function talkTime(sec: number | null | undefined): string {
  if (!sec) return ''
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return m ? `${m}m ${String(s).padStart(2, '0')}s` : `${s}s`
}

/** Popup dispositions: only shown when a human answered. */
export const CONNECTED_DISPOSITIONS: { key: string; code: string; label: string; hint?: string; needs?: 'callback' | 'email' | 'handoff' }[] = [
  { key: '1', code: 'wrong_number',        label: 'Wrong number',            hint: 'kills + re-enriches' },
  { key: '2', code: 'gatekeeper_end',      label: 'Gatekeeper — ended' },
  { key: '3', code: 'not_interested_soft', label: 'Not interested — soft',   hint: '10-day rest' },
  { key: '4', code: 'not_interested_hard', label: 'Not interested — hard',   hint: '20-day rest' },
  { key: '5', code: 'has_provider',        label: 'Already has provider',    hint: 'provider list' },
  { key: '6', code: 'dm_not_in',           label: 'Decision maker not in' },
  { key: '7', code: 'callback',            label: 'Callback scheduled',      needs: 'callback' },
  { key: '8', code: 'email_requested',     label: 'Email requested',         needs: 'email' },
  { key: '9', code: 'language_barrier',    label: 'Language barrier' },
  { key: '0', code: 'dnc',                 label: 'DO NOT CALL',             hint: 'permanent' },
  { key: 'W', code: 'chance_website',      label: 'CHANCE GIVEN — website',  hint: 'exits to your system', needs: 'handoff' },
  { key: 'S', code: 'sale_closed',         label: 'SALE — SEO / receptionist', hint: 'exits to your system', needs: 'handoff' },
]

const OUTCOME_LABELS: Record<string, string> = {
  no_answer: 'No answer', voicemail: 'Voicemail', busy_failed: 'Busy / failed', disconnected: 'Disconnected',
  skipped: 'Skipped',
  ...Object.fromEntries(CONNECTED_DISPOSITIONS.map((d) => [d.code, d.label])),
}
export function dispositionLabel(code: string | null): string {
  return code ? (OUTCOME_LABELS[code] ?? code) : 'not logged'
}
