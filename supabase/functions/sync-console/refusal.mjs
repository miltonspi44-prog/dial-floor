// The console locks sign-ins after ten failures in fifteen minutes, and its one
// password is the owner's way in as well. console.mjs remembers a refusal, but
// only for as long as one edge instance lives, and cron meets a fresh instance
// every few minutes — so on its own a wrong password would be tried again by
// each of them. Instead the refusal is written into the failed run's detail with
// a fingerprint of the password it refused, and every instance looks for it
// before signing in: the same password is tried again at most once a day, and a
// new one is tried straight away.
//
// The fingerprint is an HMAC keyed with CRON_SECRET, so the run log carries
// nothing that helps anyone guess the password.

export const REFUSAL_RETRY_H = 24

export async function fingerprint(password, key) {
  const enc = new TextEncoder()
  const k = await crypto.subtle.importKey(
    'raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(password)))
  return Array.from(sig.slice(0, 8), (b) => b.toString(16).padStart(2, '0')).join('')
}

export const refusalMark = (fp) => `[refused:${fp}]`

/** Tag a refusal so the failed run's detail (String(e)) carries the mark. */
export function markRefusal(e, fp) {
  if (e?.kind === 'auth' && e instanceof Error && !e.message.includes(refusalMark(fp))) {
    e.message += ` ${refusalMark(fp)}`
  }
  return e
}

/** When this password was last refused, from the recent failed runs, or null. */
export function refusedAt(runs, fp) {
  const mark = refusalMark(fp)
  return (runs ?? []).find((r) => String(r?.detail ?? '').includes(mark))?.started_at ?? null
}
