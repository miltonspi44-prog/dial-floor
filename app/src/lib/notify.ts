// E4: floor alerts as system notifications on this device, while the Floor tab
// is open (desktop browsers, and phones through a small service worker). A
// notification tag is the alert's key, so each event notifies once.

const WANT = 'df-notify'
const BELL = 'df-bell'

function flag(key: string): boolean {
  try { return localStorage.getItem(key) === '1' } catch { return false }
}
function setFlag(key: string, on: boolean) {
  try { if (on) localStorage.setItem(key, '1'); else localStorage.removeItem(key) } catch { /* private mode */ }
}

export function canNotify(): boolean {
  return typeof window !== 'undefined' && 'Notification' in window
}
export function notifyOn(): boolean {
  return canNotify() && Notification.permission === 'granted' && flag(WANT)
}

/** Ask the browser, then remember the choice on this device. Returns why not, or null. */
export async function enableNotify(): Promise<string | null> {
  if (!canNotify()) return 'This browser can’t show notifications'
  const p = await Notification.requestPermission()
  if (p !== 'granted') return 'Notifications are blocked for this site: allow them in the browser’s site settings'
  setFlag(WANT, true)
  // phones show notifications only through a service worker
  try { await navigator.serviceWorker?.register('/sw.js') } catch { /* desktop works without it */ }
  return null
}
export function disableNotify() { setFlag(WANT, false) }

export async function notify(title: string, body: string, tag: string) {
  if (!notifyOn()) return
  try {
    const reg = await navigator.serviceWorker?.getRegistration()
    if (reg) { await reg.showNotification(title, { body, tag }); return }
  } catch { /* fall back to a page notification */ }
  try { new Notification(title, { body, tag }) } catch { /* a phone without the worker */ }
}

export function bellOn(): boolean { return flag(BELL) }
export function setBell(on: boolean) { setFlag(BELL, on) }

/** A two-note chime for a win: no sound file to ship. */
export function chime() {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!Ctx) return
    const ctx = new Ctx()
    ;[880, 1320].forEach((freq, i) => {
      const o = ctx.createOscillator()
      const g = ctx.createGain()
      o.type = 'sine'
      o.frequency.value = freq
      const t = ctx.currentTime + i * 0.18
      g.gain.setValueAtTime(0.0001, t)
      g.gain.exponentialRampToValueAtTime(0.2, t + 0.02)
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.6)
      o.connect(g).connect(ctx.destination)
      o.start(t)
      o.stop(t + 0.65)
    })
    window.setTimeout(() => { ctx.close().catch(() => {}) }, 1500)
  } catch { /* no audio */ }
}
