import { createClient } from '@supabase/supabase-js'

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

/** Launch the Zoom desktop client dialing this number (Fork 2-A). */
export function zoomDial(phoneNorm: string) {
  window.location.href = `zoomphonecall://+1${phoneNorm}`
}
