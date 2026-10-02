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
  /** G6: a warm referral — who sent us and what the agent noted. */
  referral?: Referral
}

export interface Referral { from: string | null; agent: string | null; at: string; note: string | null }

export interface CallTap { objection: string; counters: string[] }

export interface AbOpener { test_id: number; test: string; variant: string; text: string }

/** A row of the Floor page's recent-calls table. */
export interface RecentCall {
  id: number
  agent_id: string
  connected: boolean | null
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
  category_key: string | null
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
  referral?: Referral
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
  conversations_today: number
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
  totals: FunnelCounts & { connects: number; callbacks: number; emails: number; talk_seconds: number }
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
  /** their login is blocked (removed from the Users tab); history kept */
  removed: boolean
  /** calls or records on file: removing keeps them, so only a login with none is deleted */
  has_history: boolean
}

/** digest(agent, days): D2 coaching. */
export interface DigestAgg {
  dials: number; picked_up: number; conversations: number; kept: number; won: number; noted: number; tapped: number
  cb_done: number; cb_missed: number
  days_active?: number; talk_seconds?: number; agent_days?: number
}
export interface Digest {
  agent: { id: string; name: string } | null
  from: string
  days: number
  me: DigestAgg
  floor: DigestAgg
  targets: { dials: number | null; conversations: number | null; handoffs: number | null }
  metrics: { key: string; value: number | null; reference: number | null; ratio: number | null; ok: boolean }[]
  strengths: string[]
  fix: string | null
  best_hour: { hour: number; dials: number; rate: number } | null
  objections: { objection: string; heard: number; kept: number; floor_rate: number | null; try: { text: string; uses: number; kept: number } | null }[]
}

/** insights(days): F2 outcome mining (managers). */
export interface Insights {
  from: string
  days: number
  conversations: number
  kept: number
  objections: { objection: string; heard: number; kept: number; won: number; best_counter: { text: string; uses: number; kept: number } | null }[]
  no_objection: { calls: number; kept: number }
  talk: { bucket: string; calls: number; kept: number; won: number }[]
  outcomes: { disposition: string; calls: number }[]
  words: { kept: { word: string; notes: number }[]; lost: { word: string; notes: number }[] }
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
  conversations: number | null
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

// ------------------------------------------------------------------ Phase 2 --

export type BreakReason = 'break' | 'lunch' | 'meeting' | 'training' | 'tech' | 'other'
export const BREAK_REASONS: { key: BreakReason; label: string }[] = [
  { key: 'break', label: 'Break' },
  { key: 'lunch', label: 'Lunch' },
  { key: 'meeting', label: 'Meeting' },
  { key: 'training', label: 'Training' },
  { key: 'tech', label: 'Tech trouble' },
  { key: 'other', label: 'Other' },
]
export function breakLabel(r: string | null | undefined): string {
  return BREAK_REASONS.find((b) => b.key === r)?.label ?? 'Paused'
}

/** my_pace(): the Dial page's strip (A4). Rates are per active hour, null in the first quarter hour. */
export interface Pace {
  dials: number
  connects: number
  conversations: number
  handoffs: number
  talk_seconds: number
  active_minutes: number
  paused_minutes: number
  dials_per_hour: number | null
  talk_minutes_per_hour: number | null
  target: number | null
  shift_hours: number
  target_per_hour: number | null
  wrapup_seconds: number
  break: { reason: BreakReason; note: string | null; since: string } | null
}

/** floor_pace(): today for each active member (A4, the floor board). */
export interface PaceRow {
  agent_id: string
  dials: number
  dials_per_hour: number | null
  talk_minutes_per_hour: number | null
  on_break: boolean
  break_reason: BreakReason | null
  break_note: string | null
  break_since: string | null
}

/** floor_alerts() (E4). Keys are stable, so a notification fires once per event. */
export interface FloorAlert {
  key: string
  kind: 'win' | 'idle' | 'long_call' | 'pace' | 'callback' | 'spam'
  level: 'good' | 'warn'
  agent: string | null
  title: string
  detail: string
  at: string
  number?: string
}
export interface AlertSettings {
  idle_minutes: number
  long_call_minutes: number
  pace_pct: number
  callback_overdue_minutes: number
  celebrate: boolean
  spam: boolean
}

/** recycle_pools() / recycle_preview() (B7). */
export type RecyclePoolKey = 'provider' | 'resting' | 'season'
export interface RecyclePool {
  pool: RecyclePoolKey
  total: number
  /** parked at least this many days ago */
  ages: Record<'30' | '90' | '180' | '365', number>
  outcomes: Record<string, number>
}
export interface RecyclePools { auto_provider_days: number; pools: RecyclePool[] }
export interface RecyclePreview {
  count: number
  sample: { lead_id: number; name: string; trade: string | null; city: string | null; state: string | null; outcome: string | null; parked_at: string }[]
}

/** best_times() (C6): pickup rate by trade and the lead's local hour. */
export interface BestTimeCell { hour: number; dials: number; rate: number; lift: number; reliable?: boolean }
export interface BestTimes {
  state: { at: string; total: number; rate: number; min_total: number; min_dials: number; days: number } | null
  ready: boolean
  use_in_queue: boolean
  hours: BestTimeCell[]
  trades: { trade: string; label: string | null; dials: number; rate: number; cells: BestTimeCell[] }[]
}

/** leaderboard() and sprint_board() (E5): activity only. */
export interface LeaderRow { agent_id: string; name: string; dials: number; conversations: number; streak: number }
export interface CallOfTheDay {
  attempt_id: number
  votes: number
  agent: string
  lead: string
  disposition: string
  duration: number | null
  note: string | null
}
export interface Leaderboard {
  period: 'today' | 'week'
  from: string
  rows: LeaderRow[]
  votes: Record<string, number>
  my_vote: number | null
  call_of_the_day: CallOfTheDay | null
}
export interface SprintRow { agent_id: string; name: string; count: number; reached_at: string | null }
export interface Sprint {
  id: number
  name: string
  metric: 'dials' | 'conversations'
  goal: number | null
  starts_at: string
  ends_at: string
  running: boolean
  rows: SprintRow[]
  winner: SprintRow | null
  /** present only on a dead heat: the tied rows (winner is null then) */
  winners?: SprintRow[]
}
/** floor_pulse(): what the Dial page checks once a minute. */
export interface Pulse { sprint: Sprint | null; wins: FloorAlert[] }

/** scorecard() (E6). */
export interface WeekCounts {
  dials: number
  days: number
  picked_up: number
  conversations: number
  kept: number
  won: number
  talk_seconds: number
  callbacks_set: number
  cb_done: number
  cb_missed: number
}
export interface Scorecard {
  agent: { id: string; name: string } | null
  this_week: string
  weeks: { week: string; me: WeekCounts; floor: WeekCounts & { agents: number } }[]
  handoffs: { at: string; lead: string; kind: string; summary: string | null; rating: number | null; outcome: string | null }[]
  review: { attempt_id: number; at: string; lead: string; disposition: string; duration: number; note: string | null; objections: string[] }[]
  saved: { id: number; title: string; scenario: string; at: string }[]
}

/** "8am" */
export function hourLabel(h: number): string {
  return `${h % 12 || 12}${h < 12 ? 'am' : 'pm'}`
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
