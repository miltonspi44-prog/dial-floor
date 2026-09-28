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
  history: { at: string; agent: string; disposition: string | null; duration: number | null; note: string | null }[]
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
}

export interface Battlecard {
  id: number
  objection: string
  counters: string[]
  sort: number
  active: boolean
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
