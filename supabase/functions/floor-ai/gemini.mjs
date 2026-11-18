// Dial Floor · floor-ai's Gemini client: the prompt, the model, the call, and
// reading the answer back into a shape the AI page can trust. Plain JS with
// no imports, so Node's test runner checks it (sync/test/gemini.test.mjs)
// and the edge function (Deno) ships it as it is.
//
// What goes to Gemini up front is ai_floor_snapshot(): rates, counts and lifts
// by trade, state, area code and so on, each agent's record, and the pool's
// makeup; with it what the manager has taught (ai_memory, 0044): their lessons,
// their verdicts on leads, their corrections, and the wins and hard noes the
// scores got wrong. And it can read everything else on the floor (0046): the
// run_sql tool lets it look up any lead, call, note, callback or list while it
// writes, read-only, through ai_sql() in the database.

export const API = 'https://generativelanguage.googleapis.com/v1beta'

export class GeminiError extends Error {
  constructor(message, status) { super(message); this.name = 'GeminiError'; this.status = status ?? null }
}

export const SYSTEM = [
  'You are the analyst for an outbound cold-calling floor. Agents phone small US home-service contractors',
  '(roofers, remodelers, concrete, flooring, painters and the like) found on Google Maps, Angi, Thumbtack,',
  'Yelp, Facebook and state business registries, and offer them a website (and local SEO or an AI receptionist).',
  'Outcomes: a conversation is a live person past any gatekeeper; a win is "chance_website" (the owner agreed',
  'to a website, paid upfront) or "sale_closed"; "kept alive" is a callback, an email or a win.',
  '',
  'The data is the last 90 days, aggregated. A lift is a smoothed rate against the floor average: 1.0 is',
  'average, 1.5 is half again as likely. Lifts are already pulled toward 1.0 when the evidence is thin, but',
  'always weigh them by their dials, conversations or wins: a lift on 20 dials is a hint, on 400 it is a fact.',
  'Hours are on the lead\'s own clock. The radar proposes each agent a daily list, matched by who is likeliest',
  'to convert each lead; a manager approves it.',
  '',
  'The manager teaches you. "taught" in the data holds their lessons (rules already applied to the lead scores:',
  'a lesson multiplies the chance of a win by win_x, and of a pickup by pickup_x, for every lead with all its',
  'traits; record_90d is how such leads actually did), their verdicts on single leads, their corrections of earlier',
  'analyses, and misses_30d: wins the scores rated at or below average, and hard noes on leads rated twice the',
  'average or more. Build on all of it. Never repeat a finding they marked wrong unless new data overturns it, and',
  'then say so. Where a lesson\'s own record disagrees with it on enough dials, say so plainly, with the numbers.',
  'Look for what the misses share: that is where the scores are blind.',
  '',
  'Write for the floor manager. Be concrete and numeric, cite the evidence for every claim, never invent a',
  'number that is not in the data, and say plainly when the evidence is too thin to act on. Prefer a few',
  'strong recommendations to many weak ones. Answer with JSON only, no prose around it.',
].join('\n')

// The traits a lesson can name (0044, and 0047's calls so far, ranges and more
// of the business), as Gemini is shown them
export const LESSON_TRAITS = '{"trade": "trade keys, comma separated", "state": "two-letter codes, comma separated", '
  + '"city": "city names, comma separated", "area": "305 or 305,786", '
  + '"source": "gmaps|angi|registry|thumbtack|facebook|yelp, comma separated", "website": "none|social|site", '
  + '"phone": "mobile|landline|voip", "tier": "A|B|C", "reviews": "a number range", "rating": "Google stars, a number range", '
  + '"score": "scraper score, a number range", "name_has": "words in the business name, comma separated", '
  + '"intent": "lead signal keys (intents_catalog), comma separated", "dials": "times called so far, a number range", '
  + '"pickups": "times picked up so far, a number range", '
  + '"last_outcome": "how the last call ended: none (never called) or disposition keys, comma separated", '
  + '"days_since": "days since the last call, a number range"}'

export const TRAIT_NOTE = [
  'A lesson names 1 to 8 traits; a lead must have all of them, each matching any of its values. A number trait takes a',
  'range: 3 (exactly), 2-4, 3+ (at least), <3 (under), >3 (over), or several joined by commas. The call traits are the',
  'lead\'s calls so far: "called 3 or more times and never picked up" is {"dials": "3+", "pickups": "0"}; "a soft no in',
  'the last week" is {"last_outcome": "not_interested_soft", "days_since": "<7"}; "never called" is {"dials": "0"}.',
].join('\n')

export const SHAPE = `{
  "headline": "one sentence: the single most useful thing to know today",
  "summary": "3 to 5 sentences on how the floor is doing and why",
  "findings": [{"title": "short", "detail": "what the data shows", "evidence": "the numbers behind it"}],
  "where_to_call": [{"segment": "e.g. remodelers in WA with no website", "when": "best hours on their clock, or 'any time'", "why": "evidence"}],
  "agent_matching": [{"agent": "an agent's name from the data", "focus": "what they should be given", "why": "evidence"}],
  "lists": [{"name": "a list name", "rules": {"tier": "A|B|C", "state": "two-letter codes, comma separated", "category": "trade keys, comma separated", "area_code": "305 or 305,786", "source": "gmaps|angi|registry|thumbtack|facebook|yelp, comma separated", "website_type": "none|social|site", "phone_type": "mobile|landline|voip", "tries": "0|1|2|3+: dials so far with no pickup, comma separated", "min_score": 0}, "why": "evidence"}],
  "lessons": [{"traits": ${LESSON_TRAITS}, "effect": "much_more|more|less|much_less|never", "pickup": "more|less|same", "why": "the reason, and what the data says"}],
  "cautions": ["anything the manager should not over-read"]
}`

export function buildPrompt(snapshot) {
  return [
    'Analyse this dialing floor and answer in exactly this JSON shape (omit a rule key you do not need;',
    '3 to 6 findings, 3 to 6 places to call, one agent_matching entry per agent in the data, 2 to 4 lists',
    'built only from the rule keys shown, each list worth at least 50 dialable leads judging by the pool, and 0 to 3',
    'lessons the scores should be taught, only where the data or the misses strongly support one not already taught):',
    SHAPE,
    TRAIT_NOTE,
    '',
    'Floor data:',
    JSON.stringify(snapshot),
  ].join('\n')
}

const ranked = (models, re) => (models ?? [])
  .filter((m) => (m?.supportedGenerationMethods ?? []).includes('generateContent'))
  .map((m) => ({ name: String(m.name), v: re.exec(String(m.name)) }))
  .filter((x) => x.v)
  .sort((a, b) => Number(b.v[1]) - Number(a.v[1]))
  .map((x) => x.name)

/** Every stable "gemini-N-flash" model in a models listing, newest first. */
export const flashModels = (models) => ranked(models, /^models\/gemini-(\d+(?:\.\d+)?)-flash$/)

/** The lighter "gemini-N-flash-lite" models, newest first: the last resort when
 *  every Flash model is too busy, and plenty for reading a table of rates. */
export const liteModels = (models) => ranked(models, /^models\/gemini-(\d+(?:\.\d+)?)-flash-lite$/)

/** The newest stable "gemini-N-flash" model this key can call, else any Flash
 *  model that is not a preview, else null. Names change every few months, so the
 *  default is found rather than written down. */
export function pickModel(models) {
  const stable = flashModels(models)
  if (stable.length) return stable[0]
  const usable = (models ?? []).filter((m) => (m?.supportedGenerationMethods ?? []).includes('generateContent'))
  const any = usable.find((m) => /gemini.*flash/.test(m.name) && !/(preview|exp|tts|image|lite|live|embed|audio)/.test(m.name))
  return any ? String(any.name) : null
}

const TEXT = 2000
const str = (v, max = TEXT) => (typeof v === 'string' ? v.trim().slice(0, max) : '')
const RULES = {
  tier: (v) => /^[ABCS]$/i.test(String(v)) ? String(v).toUpperCase() : null,
  // 0051: one state, or several (CA,WA)
  state: (v) => { const s = String(v).toUpperCase().replace(/\s/g, ''); return /^[A-Z]{2}(,[A-Z]{2})*$/.test(s) ? s : null },
  category: (v) => { const s = String(v).toLowerCase().replace(/\s/g, ''); return /^[a-z_]+(,[a-z_]+)*$/.test(s) ? s : null },
  area_code: (v) => { const s = String(v).replace(/\s/g, ''); return /^[2-9]\d{2}(,[2-9]\d{2})*$/.test(s) ? s : null },
  source: (v) => { const s = String(v).toLowerCase().replace(/\s/g, ''); return /^[a-z]+(,[a-z]+)*$/.test(s) ? s : null },
  website_type: (v) => ['none', 'social', 'site', 'unreachable'].includes(String(v)) ? String(v) : null,
  phone_type: (v) => ['mobile', 'landline', 'voip', 'unknown'].includes(String(v)) ? String(v) : null,
  min_score: (v) => { const n = Number(v); return Number.isInteger(n) && n > 0 && n <= 100 ? n : null },
  intent: (v) => /^[a-z_]+$/.test(String(v)) ? String(v) : null,
  tries: (v) => { const s = String(v).replace(/\s/g, ''); return /^(0|1|2|3\+)(,(0|1|2|3\+))*$/.test(s) ? s : null },
}

/** Only the rules build_list understands, each in the form it accepts. */
export function cleanRules(rules) {
  const out = {}
  if (!rules || typeof rules !== 'object') return out
  for (const [k, check] of Object.entries(RULES)) {
    if (rules[k] == null || rules[k] === '') continue
    const v = check(rules[k])
    if (v != null) out[k] = v
  }
  return out
}

// A lesson's effect on the chance of a win, and on a pickup (0044's ai_lessons)
export const EFFECTS = { much_more: 2, more: 1.5, less: 0.67, much_less: 0.4, never: 0.1 }
export const PICKUPS = { more: 1.3, less: 0.75 }

const listOf = (norm, ok) => (v) => {
  const xs = (Array.isArray(v) ? v : String(v ?? '').split(',')).map((x) => norm(String(x).trim())).filter(Boolean)
  return xs.length && xs.length <= 12 && xs.every(ok) ? [...new Set(xs)].join(',') : null
}
const lower = (x) => x.toLowerCase().replace(/\s/g, '')
const upper = (x) => x.toUpperCase().replace(/\s/g, '')
const words = (x) => x.toLowerCase().replace(/\s+/g, ' ').trim()
const oneOf = (...xs) => (x) => xs.includes(x)
// a number range, as the database keeps it: 3 · 2-4 · 3+ · <3 · >3 (">= 3" is 3+, "<= 2" is 0-2, "3 to 5" is 3-5)
const rangeOf = (n) => {
  const re = new RegExp(`^(?:${n}|${n}\\+|<${n}|>${n}|${n}-${n})$`)
  return listOf(
    (x) => x.toLowerCase().replace(/\s/g, '').replace(/^(?:>=|=>)(.+)$/, '$1+').replace(/^(?:<=|=<)(.+)$/, '0-$1')
      .replace(/^(.+?)(?:to|–|—)(.+)$/, '$1-$2').replace(/^(.+?)(?:ormore|orabove|andup|andabove|plus)$/, '$1+'),
    (x) => re.test(x) && !(/^[\d.]+-[\d.]+$/.test(x) && Number(x.split('-')[0]) > Number(x.split('-')[1])))
}
const WHOLE = '\\d+'
export const OUTCOMES = ['none', 'no_answer', 'voicemail', 'busy_failed', 'disconnected', 'wrong_number', 'gatekeeper_end',
  'not_interested_soft', 'not_interested_hard', 'has_provider', 'dm_not_in', 'callback', 'email_requested', 'dnc',
  'chance_website', 'sale_closed', 'language_barrier']
const TRAITS = {
  trade: listOf(lower, (x) => /^[a-z0-9_]+$/.test(x)),
  state: listOf(upper, (x) => /^[A-Z]{2}$/.test(x)),
  city: listOf(words, (x) => /^[a-z][a-z .'-]{0,39}$/.test(x)),
  area: listOf((x) => x, (x) => /^[2-9]\d{2}$/.test(x)),
  phone: listOf(lower, oneOf('mobile', 'landline', 'voip', 'unknown')),
  website: listOf(lower, oneOf('none', 'social', 'site', 'unreachable', 'unknown')),
  source: listOf(lower, (x) => /^[a-z0-9_]+$/.test(x)),
  tier: listOf(upper, (x) => /^[A-Z]$/.test(x)),
  reviews: rangeOf(WHOLE),
  rating: rangeOf('\\d+(?:\\.\\d+)?'),
  score: rangeOf(WHOLE),
  name_has: listOf(words, (x) => /^[a-z0-9&' .-]{2,40}$/.test(x)),
  intent: listOf(lower, (x) => /^[a-z_]+$/.test(x)),
  dials: rangeOf(WHOLE),
  pickups: rangeOf(WHOLE),
  last_outcome: listOf(lower, oneOf(...OUTCOMES)),
  days_since: rangeOf(WHOLE),
}
// what a model may call a trait instead
const ALIAS = { attempts: 'dials', calls: 'dials', connects: 'pickups', last_disposition: 'last_outcome' }

/** A lesson's traits, in the form the database checks them (ai_clean_conditions). */
export function cleanConditions(c) {
  const out = {}
  if (!c || typeof c !== 'object' || Array.isArray(c)) return out
  const given = {}
  for (const [key, v] of Object.entries(c)) {
    const k = ALIAS[key.trim().toLowerCase()] ?? key.trim().toLowerCase()
    if (!(k in given)) given[k] = v
  }
  for (const [k, check] of Object.entries(TRAITS)) {
    if (given[k] == null || given[k] === '') continue
    const v = check(given[k])
    if (v != null) out[k] = v
  }
  return out
}

/** A lesson Gemini proposes, or null when it names no trait or no effect. */
export function cleanLesson(x) {
  const conditions = cleanConditions(x?.traits ?? x?.conditions)
  if (!Object.keys(conditions).length || Object.keys(conditions).length > 8) return null
  const effect = Object.hasOwn(EFFECTS, x?.effect) ? x.effect : null
  const pickup = Object.hasOwn(PICKUPS, x?.pickup) ? x.pickup : null
  if (!effect && !pickup) return null
  return { conditions, effect, pickup, why: str(x?.why, 400) }
}

/** The first whole {...} in the text, strings and escapes respected: a model
 *  may wrap its JSON in a sentence or a code fence, or write it twice. */
export function firstObject(text) {
  const s = String(text ?? '')
  const a = s.indexOf('{')
  if (a < 0) return null
  let depth = 0, inStr = false, esc = false
  for (let i = a; i < s.length; i++) {
    const c = s[i]
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue }
    if (c === '"') inStr = true
    else if (c === '{') depth++
    else if (c === '}' && --depth === 0) return s.slice(a, i + 1)
  }
  return null
}

/** Gemini's answer, read defensively: the page renders whatever comes out of
 *  here, so everything is a string of bounded length or a list of such objects. */
function readJson(text) {
  const raw = String(text ?? '').trim()
  let j
  try { j = JSON.parse(raw) } catch {
    try { j = JSON.parse(firstObject(raw) ?? '') } catch { throw new GeminiError('Gemini answered, but not with readable JSON.') }
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) throw new GeminiError('Gemini answered with something other than an analysis.')
  return j
}
const list = (v, n) => (Array.isArray(v) ? v.slice(0, n) : [])
const lists = (v, n) => list(v, n).map((l) => ({ name: str(l?.name, 80), rules: cleanRules(l?.rules), why: str(l?.why, 600) }))
  .filter((l) => l.name && Object.keys(l.rules).length)

export function parseBrief(text) {
  const j = readJson(text)
  const brief = {
    headline: str(j.headline, 300),
    summary: str(j.summary),
    findings: list(j.findings, 8).map((f) => ({ title: str(f?.title, 200), detail: str(f?.detail), evidence: str(f?.evidence, 600) })).filter((f) => f.title || f.detail),
    where_to_call: list(j.where_to_call, 8).map((w) => ({ segment: str(w?.segment, 300), when: str(w?.when, 200), why: str(w?.why, 600) })).filter((w) => w.segment),
    agent_matching: list(j.agent_matching, 20).map((a) => ({ agent: str(a?.agent, 100), focus: str(a?.focus, 400), why: str(a?.why, 600) })).filter((a) => a.agent),
    lists: lists(j.lists, 6),
    lessons: list(j.lessons, 3).map(cleanLesson).filter(Boolean),
    cautions: list(j.cautions, 6).map((c) => str(c, 400)).filter(Boolean),
  }
  if (!brief.headline && !brief.summary && !brief.findings.length) throw new GeminiError('Gemini answered with an empty analysis.')
  return brief
}

// ---------------------------------------------------------------- the chat --
export const CHAT_RULES = [
  'You are talking with the floor manager on the AI page. They ask you about the floor and teach you what they',
  'know. Answer from the floor data below; when it cannot answer, say so rather than guess.',
  '',
  'When the manager says which leads convert or pick up (or do not), or corrects you, turn it into a lesson in',
  '"lessons" so they can save it with one click: traits only from the keys shown, values exactly as the data has',
  'them (trade keys are lowercase with underscores, states two letters). In "reply", check it against the data:',
  'say whether the floor\'s record agrees, is too thin to tell, or disagrees, with the numbers. Do not propose a',
  'lesson already in taught.lessons; say it is already taught, and whether its record supports it. Propose a lesson',
  'of your own only when the data strongly supports it. On the chance of a win: much_more ×2, more ×1.5,',
  'less ×0.67, much_less ×0.4, never ×0.1; on a pickup: more ×1.3, less ×0.75, same ×1.',
  TRAIT_NOTE,
  'A list in "lists" uses only the list rule keys shown, and is built with one click.',
  'Keep the reply short and plain: a few sentences, numbers where they help, no headings or markdown.',
].join('\n')

export const CHAT_SHAPE = `{
  "reply": "your answer to the manager",
  "lessons": [{"traits": ${LESSON_TRAITS}, "effect": "much_more|more|less|much_less|never", "pickup": "more|less|same", "why": "the reason, and what the data says"}],
  "lists": [{"name": "a list name", "rules": {"tier": "A|B|C", "state": "two-letter codes, comma separated", "category": "trade keys, comma separated", "area_code": "305 or 305,786", "source": "gmaps|angi|registry, comma separated", "website_type": "none|social|site", "phone_type": "mobile|landline|voip", "tries": "0|1|2|3+: dials so far with no pickup, comma separated", "min_score": 0}, "why": "evidence"}]
}`

/** The conversation as Gemini takes it: the floor in the instructions, then the
 *  turns, the manager's as written and the AI's as the JSON it answered with.
 *  Turns with nothing in them are left out, and two in a row from one side are
 *  joined, so the turns alternate and end with the manager. */
export function buildChat({ snapshot, history, guide = null }) {
  const system = [SYSTEM, '', CHAT_RULES, ...(guide ? ['', guide] : []),
    '', 'Answer in exactly this JSON shape (lessons and lists may be empty):', CHAT_SHAPE,
    '', 'Floor data:', JSON.stringify(snapshot)].join('\n')
  const contents = []
  for (const m of history ?? []) {
    const role = m?.role === 'manager' ? 'user' : 'model'
    const text = role === 'user' ? str(m?.text, 2000)
      : m?.error || !str(m?.text) ? '' : JSON.stringify({ reply: m.text, lessons: m.proposals?.lessons ?? [], lists: m.proposals?.lists ?? [] })
    if (!text) continue
    const last = contents[contents.length - 1]
    if (last?.role === role) last.parts[0].text += `\n\n${text}`
    else contents.push({ role, parts: [{ text }] })
  }
  while (contents.length && contents[0].role !== 'user') contents.shift()
  while (contents.length && contents[contents.length - 1].role !== 'user') contents.pop()
  return { system, contents }
}

export function parseChat(text) {
  const j = readJson(text)
  const reply = str(j.reply, 4000)
  if (!reply) throw new GeminiError('Gemini answered with an empty reply.')
  return { reply, lessons: list(j.lessons, 4).map(cleanLesson).filter(Boolean), lists: lists(j.lists, 4) }
}

/** A reply that came back as plain text rather than the JSON asked for: still a reply. */
export function looseChat(text) {
  const reply = str(text, 4000)
  if (!reply) throw new GeminiError('Gemini answered with an empty reply.')
  return { reply, lessons: [], lists: [] }
}

// ----------------------------------------------------------- reading the floor --
export const READ_TOOL = { functionDeclarations: [{
  name: 'run_sql',
  description: 'Run one read-only PostgreSQL query (a SELECT or WITH) on the dial floor\'s database and get up to 200 rows back as JSON. '
    + 'Use it to look up anything the floor data does not already show: a lead by name or number, its calls and the agents\' notes, '
    + 'callbacks, lists, an agent\'s day, the settings.',
  parameters: {
    type: 'object',
    properties: { sql: { type: 'string', description: 'One SELECT or WITH query, with its own ORDER BY and LIMIT.' } },
    required: ['sql'],
  },
}] }

/** What Gemini needs to know to read the floor well: the tool, the meaning of
 *  the main tables, and the map of every table and column it can read. */
export function dataGuide(schema) {
  return [
    'You can read the whole dial floor database with the run_sql tool: read-only, one query at a time, up to 200 rows each.',
    'Look things up rather than guess: a lead by name or number, its calls and notes, an agent\'s day, callbacks due, lists,',
    'why a lead scored as it did. Say what you looked up. When you have what you need, answer in the JSON shape asked for, and only that.',
    'leads: one business each (name, phone_display; phone_norm is ten digits; addr_city, addr_state; category_key holds its trades,',
    'comma separated; tier, score, review_count, website_type, source). lead_state, one row per lead: state is queued, resting,',
    'callback_locked, in_progress, handoff (won), suppressed or provider_list; attempts_total dials, connects_total pickups.',
    'attempts: one dial each (lead_id, agent_id = profiles.id, and profiles.name is the agent; clicked_at, connected, disposition,',
    'duration_seconds, note = the agent\'s note, ai_summary = Zoom\'s summary, ai_p_win = the AI\'s chance of a win when dialed).',
    'A win is disposition chance_website or sale_closed; a conversation is connected and not gatekeeper_end; not_placed was never dialed.',
    'handoff_ledger holds every win (kind, summary, agent_id, handed_at, and how it turned out). callbacks (lead_id, agent_id, due_at,',
    'status), lists and list_items, lead_scores (p_win, p_answer, reasons), lead_intents (a lead\'s signals; intents_catalog labels',
    'each key), ai_lessons (what the manager taught: conditions, win_mult, answer_mult, note), suppression (do not call), app_settings',
    '(business_tz is the floor\'s clock; times are stored in UTC).',
    'Every table and column you can read:',
    String(schema ?? ''),
  ].join('\n')
}

/** How hard the model thinks before it answers. Gemini 3 and later think at
 *  medium or high unless told otherwise, which can run past the function's
 *  time limit on a prompt this size; low is plenty for reading a table of rates. */
export function thinkingFor(name) {
  const v = /gemini-(\d+)(?:\.(\d+))?/.exec(String(name))
  if (!v) return null
  const major = Number(v[1]), minor = Number(v[2] ?? 0)
  if (major >= 3) return { thinkingLevel: 'LOW' }
  if (major === 2 && minor >= 5) return { thinkingBudget: 2048 }
  return null
}

async function call(fetchFn, url, apiKey, init, timeoutMs, signal) {
  const ctl = signal ? null : new AbortController()
  const timer = ctl && setTimeout(() => ctl.abort(), timeoutMs)
  try {
    return await fetchFn(url, { ...init, headers: { ...(init?.headers ?? {}), 'x-goog-api-key': apiKey }, signal: signal ?? ctl.signal })
  } catch (e) {
    const who = /models\/([^:?]+):/.exec(url)?.[1] ?? 'Gemini'
    if (e?.name === 'AbortError') throw new GeminiError(`${who} did not answer within ${Math.round(timeoutMs / 1000)} seconds.`)
    throw new GeminiError(`Could not reach Gemini: ${e?.message ?? e}`)
  } finally { if (timer) clearTimeout(timer) }
}

/** True once the text so far is a whole analysis: the outer object only closes
 *  at the very end, so no shorter prefix of the answer parses. */
function answered(text, parse) {
  if (!/[}`]\s*$/.test(text)) return false
  try { parse(text); return true } catch { return false }
}

/** Reads the streamed answer (server-sent events), and stops as soon as it is
 *  a whole analysis: in JSON mode a model can finish its answer and then trail
 *  off into blank space until the output cap, which would otherwise be waited out. */
async function readAnswer(res, who, timeoutMs, parse) {
  const reader = res.body.getReader()
  const dec = new TextDecoder()
  let buf = '', text = '', finish = null, blocked = null
  const take = (line) => {
    line = line.trim()
    if (!line.startsWith('data:')) return
    let j
    try { j = JSON.parse(line.slice(5)) } catch { return }
    const cand = j?.candidates?.[0]
    text += (cand?.content?.parts ?? []).filter((p) => !p?.thought).map((p) => p?.text ?? '').join('')
    finish = cand?.finishReason ?? finish
    blocked = j?.promptFeedback?.blockReason ?? blocked
  }
  try {
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      buf += dec.decode(value, { stream: true })
      for (let i; (i = buf.indexOf('\n')) >= 0;) { take(buf.slice(0, i)); buf = buf.slice(i + 1) }
      if (answered(text, parse)) { reader.cancel().catch(() => {}); return { text, finish, blocked } }
      if (text.length - text.trimEnd().length > 2000) {
        reader.cancel().catch(() => {})
        throw new GeminiError(`${who} trailed off into blank space before finishing the analysis. Ask again.`)
      }
    }
    take(buf)
  } catch (e) {
    if (e instanceof GeminiError) throw e
    const secs = Math.round(timeoutMs / 1000)
    if (e?.name === 'AbortError') {
      throw new GeminiError(text.trim()
        ? `${who} was still writing after ${secs} seconds (${text.trim().length} characters so far).`
        : `${who} sent nothing in ${secs} seconds.`)
    }
    throw new GeminiError(`The answer from ${who} broke off: ${e?.message ?? e}`)
  }
  return { text, finish, blocked }
}

async function errorMessage(res) {
  try { const j = await res.json(); return j?.error?.message ?? '' } catch { return '' }
}

function explainStatus(status, msg) {
  if (status === 400 && /api key/i.test(msg)) return new GeminiError('Gemini refused the API key. Check GEMINI_API_KEY in Supabase → Edge Functions → Secrets.', 400)
  if (status === 401 || status === 403) return new GeminiError(`Gemini refused the request (${status}): ${msg || 'the key may lack access to this model'}`, status)
  if (status === 429) return new GeminiError(`Gemini's quota for this key is used up for now (429): ${msg}`, 429)
  return new GeminiError(`Gemini answered ${status}${msg ? `: ${msg}` : ''}`, status)
}

async function explain(res) {
  return explainStatus(res.status, await errorMessage(res))
}

async function listModels(apiKey, fetchFn, timeoutMs = 20_000) {
  const res = await call(fetchFn, `${API}/models?pageSize=200`, apiKey, { method: 'GET' }, timeoutMs)
  if (!res.ok) throw await explain(res)
  return (await res.json())?.models ?? []
}

/** For a model that will not answer: which Flash models this key can see, and
 *  how long a few of them take to say one word, with and without the thinking
 *  setting. Names, statuses and timings only. */
export async function probe({ apiKey, snapshot = null, fetchFn = fetch, timeoutMs = 25_000 }) {
  const out = { tries: [] }
  let t = Date.now()
  const res = await call(fetchFn, `${API}/models?pageSize=200`, apiKey, { method: 'GET' }, timeoutMs)
  out.list_ms = Date.now() - t
  if (!res.ok) { out.list_error = (await explain(res)).message; return out }
  const models = ((await res.json())?.models ?? []).filter((m) => (m?.supportedGenerationMethods ?? []).includes('generateContent'))
  out.flash = models.map((m) => String(m.name).replace('models/', '')).filter((n) => /flash/.test(n))
  const picked = pickModel(models)
  out.picked = picked && picked.replace('models/', '')
  const others = models.map((m) => String(m.name))
    .filter((n) => n !== picked && /^models\/gemini-\d+(\.\d+)?-flash$/.test(n)).slice(0, 2)
  const plan = [...(picked ? [[picked, true], [picked, false]] : []), ...others.map((n) => [n, true])]
  out.tries = await Promise.all(plan.map(async ([n, think]) => {
    const t0 = Date.now()
    const row = { model: n.replace('models/', ''), thinking: think && thinkingFor(n) ? thinkingFor(n) : null }
    try {
      const r = await call(fetchFn, `${API}/${n}:generateContent`, apiKey, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: 'Reply with the single word ok.' }] }],
                               generationConfig: { maxOutputTokens: 1024, ...(row.thinking ? { thinkingConfig: row.thinking } : {}) } }) }, timeoutMs)
      row.status = r.status
      if (r.ok) {
        const j = await r.json()
        row.finish = j?.candidates?.[0]?.finishReason ?? null
        row.text = (j?.candidates?.[0]?.content?.parts ?? []).map((p) => p?.text ?? '').join('').slice(0, 40)
      } else row.error = (await errorMessage(r)).slice(0, 200)
    } catch (e) { row.error = e?.message ?? String(e) }
    row.ms = Date.now() - t0
    return row
  }))
  // with the floor's snapshot: the real prompt to the first model that answered,
  // whole and streamed, beside a streamed one-word prompt, to tell a refusal of
  // the request's size from a refusal of streaming
  const target = out.tries.find((r) => r.status === 200)?.model
  if (snapshot && target) {
    const n = `models/${target}`
    const real = { systemInstruction: { parts: [{ text: SYSTEM }] }, contents: [{ role: 'user', parts: [{ text: buildPrompt(snapshot) }] }],
                   generationConfig: { responseMimeType: 'application/json', maxOutputTokens: 32768, ...(thinkingFor(n) ? { thinkingConfig: thinkingFor(n) } : {}) } }
    const tiny = { contents: [{ role: 'user', parts: [{ text: 'Reply with the single word ok.' }] }],
                   generationConfig: { maxOutputTokens: 1024, ...(thinkingFor(n) ? { thinkingConfig: thinkingFor(n) } : {}) } }
    const variant = async (label, stream, req) => {
      const t0 = Date.now()
      const row = { model: target, label, prompt_chars: JSON.stringify(req).length }
      const ctl = new AbortController()
      const timer = setTimeout(() => ctl.abort(), 60_000)
      try {
        const r = await fetchFn(`${API}/${n}:${stream ? 'streamGenerateContent?alt=sse' : 'generateContent'}`, { method: 'POST', signal: ctl.signal,
          headers: { 'content-type': 'application/json', 'x-goog-api-key': apiKey }, body: JSON.stringify(req) })
        row.status = r.status
        row.headers_ms = Date.now() - t0
        if (!r.ok) row.error = (await errorMessage(r)).slice(0, 200)
        else if (stream) r.body?.cancel().catch(() => {})
        else {
          const j = await r.json()
          row.finish = j?.candidates?.[0]?.finishReason ?? null
          row.chars = (j?.candidates?.[0]?.content?.parts ?? []).map((p) => p?.text ?? '').join('').length
          row.usage = j?.usageMetadata ?? null
        }
      } catch (e) { row.error = e?.name === 'AbortError' ? 'no answer in 60 seconds' : (e?.message ?? String(e)) }
      finally { clearTimeout(timer) }
      row.ms = Date.now() - t0
      return row
    }
    out.real = await Promise.all([variant('real, whole', false, real), variant('real, streamed', true, real), variant('one word, streamed', true, tiny)])
  }
  return out
}

// "this model, not now" rather than "this request is wrong": try another, or
// the same one again later; a model that is gone or out of quota is not retried
const BUSY = { 404: 'was not available (404)', 429: 'had no quota left (429)', 500: 'failed (500)', 503: 'was busy (503)', 504: 'timed out (504)' }
const SPENT = new Set([404, 429])

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// the thinking counts against maxOutputTokens, so the cap leaves room for it;
// temperature is left at the model's default, as Google asks for Gemini 3 and later
const generation = (n, think) => ({ responseMimeType: 'application/json', maxOutputTokens: 32768,
                                    ...(think && thinkingFor(n) ? { thinkingConfig: thinkingFor(n) } : {}) })

/** One answer from Gemini, read with `parse`. The model set in Settings is
 *  asked first; otherwise the one that answered last (`prefer`), then the
 *  newest Flash, the next newest, then the Flash-Lite models. A model that is
 *  busy is asked again after a pause (2, 4, 8, then 15 s), up to maxTries tries
 *  inside one time limit; one that is gone, out of quota or slow to start
 *  (startMs) is not asked again, and nor is one whose answer could not be read.
 *  Returns { model, out, skipped }: skipped says why the first choice did not
 *  write it, when it did not. */
async function ask({ apiKey, model, prefer, request, parse, fetchFn, timeoutMs, startMs, retryMs, maxTries }) {
  if (!apiKey) throw new GeminiError('GEMINI_API_KEY is not set.')
  const deadline = Date.now() + timeoutMs
  const named = (m) => (m ? (String(m).startsWith('models/') ? String(m) : `models/${m}`) : null)
  const configured = named(model)

  let listed = null
  const more = async () => {
    if (!listed) {
      const all = await listModels(apiKey, fetchFn)
      listed = [...flashModels(all), ...liteModels(all)]
      if (!listed.length && pickModel(all)) listed = [pickModel(all)]
    }
    return listed
  }

  // a model that has not started answering within startMs is passed over
  const start = async (n, think, ctl) => {
    const ms = Math.max(0, Math.min(startMs, deadline - Date.now()))
    const timer = setTimeout(() => ctl.abort(), ms)
    try {
      return await fetchFn(`${API}/${n}:streamGenerateContent?alt=sse`, { method: 'POST', signal: ctl.signal,
        headers: { 'content-type': 'application/json', 'x-goog-api-key': apiKey }, body: request(n, think) })
    } catch (e) {
      if (e?.name === 'AbortError') return { passed: `did not start answering within ${Math.round(ms / 1000)} seconds`, spent: true }
      throw new GeminiError(`Could not reach Gemini: ${e?.message ?? e}`)
    } finally { clearTimeout(timer) }
  }

  let bad = null   // the last answer that could not be read, described for the error
  const attempt = async (n) => {
    const who = n.replace('models/', '')
    const ctl = new AbortController()
    const stop = setTimeout(() => ctl.abort(), Math.max(0, deadline - Date.now()))
    try {
      let res = await start(n, true, ctl)
      // a model that does not take this thinking setting is asked again without it
      if (res.status === 400 && thinkingFor(n)) {
        const msg = await errorMessage(res)
        if (!/thinking/i.test(msg)) throw explainStatus(400, msg)
        res = await start(n, false, ctl)
      }
      if (res.passed) return res
      if (BUSY[res.status]) { res.body?.cancel().catch(() => {}); return { passed: BUSY[res.status], spent: SPENT.has(res.status) } }
      if (!res.ok) throw await explain(res)
      const { text, finish, blocked } = await readAnswer(res, who, timeoutMs, parse)
      if (!text.trim()) throw new GeminiError(`${who} returned no answer (${finish ?? blocked ?? 'no text'}).`)
      if (finish === 'MAX_TOKENS' && !answered(text, parse)) throw new GeminiError('Gemini ran out of room before finishing. Ask again.')
      try { return { model: who, out: parse(text) } } catch (e) {
        // an unreadable answer is one model's bad draw: the next may do better
        const t = text.trim()
        bad = `${who} wrote ${t.length} characters (${finish ?? 'no finish reason'}) beginning ${JSON.stringify(t.slice(0, 80))} and ending ${JSON.stringify(t.slice(-80))}`
        return { passed: `answered with ${e instanceof GeminiError ? 'unreadable JSON' : 'an error'}`, spent: true }
      }
    } finally { clearTimeout(stop) }
  }

  const queue = configured ? [configured] : [...await more()]
  if (!queue.length) throw new GeminiError('This key can reach no Gemini Flash model. Set one in Settings → AI → model.')
  const p = named(prefer)
  if (!configured && p && queue.indexOf(p) > 0) { queue.splice(queue.indexOf(p), 1); queue.unshift(p) }
  const spent = new Set()
  const why = new Map()   // model → [its latest reason, how many times]
  let first = null, tries = 0, wait = retryMs
  for (let round = 0; tries < maxTries; round++) {
    for (const n of queue) {
      if (spent.has(n) || tries >= maxTries || (tries && deadline - Date.now() < 5_000)) continue
      tries++
      const out = await attempt(n)
      const who = n.replace('models/', '')
      if (out.out) return { model: out.model, out: out.out, skipped: first && !first.startsWith(`${out.model} `) ? first : null }
      first ??= `${who} ${out.passed}`
      why.set(who, [out.passed, (why.get(who)?.[1] ?? 0) + 1])
      if (out.spent) spent.add(n)
    }
    if (deadline - Date.now() < wait + 5_000) break
    // the model set in Settings could not answer: the rest may
    if (round === 0 && configured) for (const n of await more()) if (!queue.includes(n)) queue.push(n)
    if (queue.every((n) => spent.has(n))) break
    await sleep(wait)
    wait = Math.min(wait * 2, 15_000)
  }
  const tally = [...why].map(([m, [reason, n]]) => `${m} ${reason}${n > 1 ? ` (${n} tries)` : ''}`).join('; ')
  throw new GeminiError(`No Gemini model could answer just now: ${tally}. Ask again in a few minutes.${bad ? ` The last unreadable answer: ${bad}.` : ''}`)
}

// statuses worth one more try in the middle of an exchange
const RETRYABLE = new Set([429, 500, 503, 504])

/** An answer that may look things up first. Gemini calls run_sql (carried out
 *  by runTool) as often as it needs, up to maxRounds, then answers; the last
 *  round it is told to answer with what it has. One model sees the whole
 *  exchange, since its thinking travels with its calls; a model that is busy
 *  or slow at the first call is passed over for the next, as in ask(). parse
 *  reads the answer, loose (if given) one that is not JSON.
 *  Returns { model, out, reads, skipped }: reads lists every query it ran. */
async function converse({ apiKey, model, prefer, system, contents, runTool, parse, loose = null, fetchFn, timeoutMs, maxRounds = 6 }) {
  if (!apiKey) throw new GeminiError('GEMINI_API_KEY is not set.')
  const deadline = Date.now() + timeoutMs
  const named = (m) => (m ? (String(m).startsWith('models/') ? String(m) : `models/${m}`) : null)
  const configured = named(model)
  let queue = []
  if (configured) queue = [configured]
  else {
    const all = await listModels(apiKey, fetchFn)
    queue = [...flashModels(all), ...liteModels(all)]
    if (!queue.length && pickModel(all)) queue = [pickModel(all)]
  }
  if (!queue.length) throw new GeminiError('This key can reach no Gemini Flash model. Set one in Settings → AI → model.')
  const p = named(prefer)
  if (!configured && p && queue.indexOf(p) > 0) { queue.splice(queue.indexOf(p), 1); queue.unshift(p) }

  const reads = []
  const once = (n, convo, think, final) => call(fetchFn, `${API}/${n}:generateContent`, apiKey, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: system }] }, contents: convo, tools: [READ_TOOL],
      toolConfig: { functionCallingConfig: { mode: final ? 'NONE' : 'AUTO' } },
      generationConfig: { maxOutputTokens: 32768, ...(think && thinkingFor(n) ? { thinkingConfig: thinkingFor(n) } : {}) },
    }),
  }, Math.max(1_000, Math.min(60_000, deadline - Date.now())))

  const passed = []
  for (const n of queue.slice(0, 4)) {
    if (passed.length && deadline - Date.now() < 10_000) break
    const who = n.replace('models/', '')
    const convo = [...contents]
    let think = true
    let res
    try { res = await once(n, convo, think, false) } catch (e) { passed.push(`${who}: ${e.message}`); continue }
    // a model that does not take this thinking setting is asked again without it
    if (res.status === 400 && thinkingFor(n)) {
      const msg = await errorMessage(res)
      if (!/thinking/i.test(msg)) throw explainStatus(400, msg)
      think = false
      res = await once(n, convo, think, false)
    }
    if (BUSY[res.status]) { res.body?.cancel().catch(() => {}); passed.push(`${who} ${BUSY[res.status]}`); continue }
    if (!res.ok) throw await explain(res)
    // from here this model answers the whole exchange
    for (let round = 1; ; round++) {
      const j = await res.json()
      const cand = j?.candidates?.[0]
      const parts = cand?.content?.parts ?? []
      const asked = parts.filter((x) => x?.functionCall)
      if (!asked.length) {
        const text = parts.filter((x) => !x?.thought).map((x) => x?.text ?? '').join('')
        if (!text.trim()) throw new GeminiError(`${who} returned no answer (${cand?.finishReason ?? j?.promptFeedback?.blockReason ?? 'no text'}).`)
        let out
        try { out = parse(text) } catch (e) { if (!loose) throw e; out = loose(text) }
        return { model: who, out, reads, skipped: passed[0] ?? null }
      }
      convo.push(cand.content)   // as it came: the calls carry the model's thinking
      const answers = []
      for (const c of asked) {
        const { name, args, id } = c.functionCall
        const sql = String(args?.sql ?? '')
        const result = name === 'run_sql' ? await runTool(sql) : { error: `there is no tool called ${name}` }
        if (name === 'run_sql') reads.push({ sql: sql.slice(0, 2000), rows: result?.count ?? null, error: result?.error ?? null })
        answers.push({ functionResponse: { ...(id ? { id } : {}), name, response: result } })
      }
      convo.push({ role: 'user', parts: answers })
      const last = round >= maxRounds || deadline - Date.now() < 20_000
      res = await once(n, convo, think, last)
      // a busy moment in the middle of the exchange: one more try after a pause
      if (RETRYABLE.has(res.status)) { res.body?.cancel().catch(() => {}); await sleep(2_000); res = await once(n, convo, think, last) }
      if (!res.ok) throw await explain(res)
    }
  }
  throw new GeminiError(`No Gemini model could answer just now: ${passed.join('; ') || 'out of time'}. Ask again in a few minutes.`)
}

/** Ask Gemini for the floor analysis. Returns { model, brief, reads }; the
 *  analysis says which model wrote it when the first choice could not. With
 *  runTool it may read the floor first (half the time allowed); if that fails
 *  for any reason it writes from the snapshot alone, as before. */
export async function generateBrief({ apiKey, model, prefer = null, snapshot, schema = null, runTool = null, fetchFn = fetch,
                                      timeoutMs = 110_000, startMs = 20_000, retryMs = 2_000, maxTries = 16 }) {
  const prompt = buildPrompt(snapshot)
  const started = Date.now()
  if (runTool) {
    try {
      const r = await converse({ apiKey, model, prefer, fetchFn, runTool, parse: parseBrief, maxRounds: 4, timeoutMs: Math.round(timeoutMs / 2),
        system: [SYSTEM, '', dataGuide(schema)].join('\n'), contents: [{ role: 'user', parts: [{ text: prompt }] }] })
      if (r.skipped) r.out.cautions = [`${r.skipped}, so ${r.model} wrote this analysis`, ...r.out.cautions].slice(0, 6)
      return { model: r.model, brief: r.out, reads: r.reads }
    } catch (e) {
      if (e instanceof GeminiError && /API key|GEMINI_API_KEY/.test(e.message)) throw e
    }
  }
  const r = await ask({ apiKey, model, prefer, fetchFn, startMs, retryMs, maxTries, parse: parseBrief,
    // after a reading attempt, what is left of the time (and never under 30 s)
    timeoutMs: runTool ? Math.max(30_000, timeoutMs - (Date.now() - started)) : timeoutMs,
    request: (n, think) => JSON.stringify({ systemInstruction: { parts: [{ text: SYSTEM }] },
                                           contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig: generation(n, think) }) })
  if (r.skipped) r.out.cautions = [`${r.skipped}, so ${r.model} wrote this analysis`, ...r.out.cautions].slice(0, 6)
  return { model: r.model, brief: r.out, reads: [] }
}

/** Gemini's reply to the conversation so far (the manager spoke last). With
 *  runTool it reads whatever it needs on the floor first.
 *  Returns { model, chat: { reply, lessons, lists }, reads }. */
export async function generateChat({ apiKey, model, prefer = null, snapshot, history, schema = null, runTool = null, fetchFn = fetch,
                                     timeoutMs = 100_000, startMs = 20_000, retryMs = 2_000, maxTries = 12 }) {
  const { system, contents } = buildChat({ snapshot, history, guide: runTool ? dataGuide(schema) : null })
  if (!contents.length) throw new GeminiError('There is no message to answer.')
  if (runTool) {
    const r = await converse({ apiKey, model, prefer, fetchFn, runTool, system, contents, parse: parseChat, loose: looseChat, timeoutMs })
    return { model: r.model, chat: r.out, reads: r.reads }
  }
  const r = await ask({ apiKey, model, prefer, fetchFn, timeoutMs, startMs, retryMs, maxTries, parse: parseChat,
    request: (n, think) => JSON.stringify({ systemInstruction: { parts: [{ text: system }] }, contents, generationConfig: generation(n, think) }) })
  return { model: r.model, chat: r.out, reads: [] }
}
