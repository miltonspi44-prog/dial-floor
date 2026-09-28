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

/** Launch the Zoom desktop client dialing this number (Fork 2-A). */
export function zoomDial(phoneNorm: string) {
  window.location.href = `zoomphonecall://+1${phoneNorm}`
}
