/** G5 email templates: filled in here, sent from the manager's own mail client. */

export interface EmailTemplate {
  id: number
  name: string
  subject: string
  body: string
  active: boolean
  sort: number
}

/** What each placeholder is filled with. */
export const PLACEHOLDERS: { key: string; means: string }[] = [
  { key: 'business', means: "the lead's business name" },
  { key: 'city', means: 'its city' },
  { key: 'state', means: 'its state' },
  { key: 'category', means: 'its Google category' },
  { key: 'website', means: 'its website, if it has one' },
  { key: 'agent', means: 'the agent who took the call' },
  { key: 'my_name', means: 'you' },
]

/** {business} → the value; a placeholder we don't know stays as typed, so a typo shows. */
export function fillTemplate(text: string, vars: Record<string, string>): string {
  return text.replace(/\{([a-z_]+)\}/gi, (m, k: string) => vars[k.toLowerCase()] ?? m)
}

/** Opens the default mail app with the email ready to send. */
export function mailtoHref(to: string, subject: string, body: string): string {
  const addr = to.trim().replace(/[^A-Za-z0-9.@_+-]/g, (c) => encodeURIComponent(c))
  const enc = (s: string) => encodeURIComponent(s.replace(/\r?\n/g, '\r\n'))
  return `mailto:${addr}?subject=${enc(subject)}&body=${enc(body)}`
}
