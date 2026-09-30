import { createClient } from '@supabase/supabase-js'
import type { Targets } from './types'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL as string,
  import.meta.env.VITE_SUPABASE_KEY as string,
)

export function normPhone(p: string | null | undefined): string {
  const d = (p ?? '').replace(/\D/g, '')
  return d.length === 11 && d.startsWith('1') ? d.slice(1) : d
}

export function fmtPhone(p: string | null | undefined): string {
  const d = normPhone(p)
  if (d.length !== 10) return p ?? ''
  return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`
}

/** Mark the agent offline as the page goes away. keepalive lets the request
 *  outlive the page, which a normal supabase.rpc() call does not. */
export function heartbeatOffline(accessToken: string) {
  fetch(`${import.meta.env.VITE_SUPABASE_URL}/rest/v1/rpc/heartbeat`, {
    method: 'POST',
    keepalive: true,
    headers: {
      apikey: import.meta.env.VITE_SUPABASE_KEY as string,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_status: 'offline' }),
  }).catch(() => {})
}

/** Each agent's daily targets (kpi_targets, F4); a metric that isn't set comes back null. */
export async function loadTargets(): Promise<Targets> {
  const { data } = await supabase.from('kpi_targets').select('metric, target').eq('scope', 'agent_day')
  const t = new Map((data ?? []).map((r) => [r.metric as string, Number(r.target)]))
  return {
    dials: t.get('dials_per_day') ?? null,
    connects: t.get('connects_per_day') ?? null,
    handoffs: t.get('handoffs_per_day') ?? null,
  }
}

/** Launch the Zoom desktop client dialing this number (Fork 2-A). */
export function zoomDial(phoneNorm: string) {
  window.location.href = `zoomphonecall://+1${phoneNorm}`
}

/** The admin-users edge function (managers only): the function's own message on failure. */
export async function callAdmin<T>(action: string, payload: Record<string, unknown> = {}): Promise<{ data?: T; error?: string }> {
  const { data, error } = await supabase.functions.invoke('admin-users', { body: { action, ...payload } })
  if (!error) return { data: data as T }
  try {
    const res = (error as { context?: Response }).context
    const body = res ? await res.json() : null
    return { error: body?.error ?? error.message }
  } catch {
    return { error: error.message }
  }
}
