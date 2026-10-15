/** The computer's clock against the auth server's.
 *
 *  The browser decides whether a token has expired by comparing the token's
 *  expiry with this computer's clock. A clock more than an hour ahead makes every
 *  freshly issued token look expired the moment it arrives: the client refreshes
 *  at once, the new token looks expired too, and the loop runs until the auth
 *  server rate-limits it and the session collapses. From the user's chair that
 *  is "it logs me in and straight back out", with nothing on screen to say why.
 *
 *  The access token carries the second the server issued it (iat). Reading it
 *  right after sign-in says how far this clock is from the server's. */

/** Seconds this computer's clock is ahead of the server's (negative = behind);
 *  null when the token cannot be read. */
export function clockSkewSeconds(accessToken: string, nowMs: number = Date.now()): number | null {
  const iat = issuedAt(accessToken)
  if (iat == null) return null
  return Math.round(nowMs / 1000 - iat)
}

/** The iat claim of a JWT, or null. No signature check: the token came from the
 *  server over TLS a moment ago, and only its clock is of interest. */
export function issuedAt(accessToken: string): number | null {
  try {
    const part = accessToken.split('.')[1]
    if (!part) return null
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '='))
    const iat = (JSON.parse(json) as { iat?: unknown }).iat
    return typeof iat === 'number' && Number.isFinite(iat) ? iat : null
  } catch {
    return null
  }
}

/** Past this, the session cannot be kept: say so instead of letting it collapse.
 *  Five minutes is far inside the hour that actually breaks things, and far
 *  outside any honest clock's drift. */
export const SKEW_LIMIT_SECONDS = 5 * 60

/** What to tell the person, or null when the clock is fine. */
export function clockProblem(accessToken: string, nowMs: number = Date.now()): string | null {
  const skew = clockSkewSeconds(accessToken, nowMs)
  if (skew == null || Math.abs(skew) <= SKEW_LIMIT_SECONDS) return null
  const mins = Math.round(Math.abs(skew) / 60)
  const amount = mins >= 120 ? `${Math.round(mins / 60)} hours` : `${mins} minutes`
  return `This computer's clock is ${amount} ${skew > 0 ? 'ahead of' : 'behind'} the real time, so the dialer cannot stay signed in on it. `
    + 'Fix the clock (Windows: Settings → Time & Language → Date & time → turn on "Set time automatically" and press "Sync now"; '
    + 'Mac: System Settings → General → Date & Time), then reload this page and sign in again.'
}
