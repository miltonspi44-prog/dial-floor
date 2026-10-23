// Dial Floor · floor-ai's Gemini client: the prompt, the model, the call, and
// reading the answer back into a shape the AI page can trust. Plain JS with
// no imports, so Node's test runner checks it (sync/test/gemini.test.mjs)
// and the edge function (Deno) ships it as it is.
//
// What goes to Gemini is ai_floor_snapshot(): aggregates only — rates, counts
// and lifts by trade, state, area code and so on, each agent's record, and the
// pool's makeup. No lead's name, number or call notes ever leave the database.

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
  'Write for the floor manager. Be concrete and numeric, cite the evidence for every claim, never invent a',
  'number that is not in the data, and say plainly when the evidence is too thin to act on. Prefer a few',
  'strong recommendations to many weak ones. Answer with JSON only, no prose around it.',
].join('\n')

export const SHAPE = `{
  "headline": "one sentence: the single most useful thing to know today",
  "summary": "3 to 5 sentences on how the floor is doing and why",
  "findings": [{"title": "short", "detail": "what the data shows", "evidence": "the numbers behind it"}],
  "where_to_call": [{"segment": "e.g. remodelers in WA with no website", "when": "best hours on their clock, or 'any time'", "why": "evidence"}],
  "agent_matching": [{"agent": "an agent's name from the data", "focus": "what they should be given", "why": "evidence"}],
  "lists": [{"name": "a list name", "rules": {"tier": "A|B|C", "state": "two letters", "category": "trade keys, comma separated", "area_code": "305 or 305,786", "source": "gmaps|angi|registry|thumbtack|facebook|yelp, comma separated", "website_type": "none|social|site", "phone_type": "mobile|landline|voip", "min_score": 0}, "why": "evidence"}],
  "cautions": ["anything the manager should not over-read"]
}`

export function buildPrompt(snapshot) {
  return [
    'Analyse this dialing floor and answer in exactly this JSON shape (omit a rule key you do not need;',
    '3 to 6 findings, 3 to 6 places to call, one agent_matching entry per agent in the data, 2 to 4 lists',
    'built only from the rule keys shown, each list worth at least 50 dialable leads judging by the pool):',
    SHAPE,
    '',
    'Floor data:',
    JSON.stringify(snapshot),
  ].join('\n')
}

/** The newest stable "gemini-N-flash" model this key can call, else any Flash
 *  model that is not a preview, else null. Names change every few months, so the
 *  default is found rather than written down. */
export function pickModel(models) {
  const usable = (models ?? []).filter((m) => (m?.supportedGenerationMethods ?? []).includes('generateContent'))
  const stable = usable
    .map((m) => ({ name: String(m.name), v: /^models\/gemini-(\d+(?:\.\d+)?)-flash$/.exec(String(m.name)) }))
    .filter((x) => x.v)
    .sort((a, b) => Number(b.v[1]) - Number(a.v[1]))
  if (stable.length) return stable[0].name
  const any = usable.find((m) => /gemini.*flash/.test(m.name) && !/(preview|exp|tts|image|lite|live|embed|audio)/.test(m.name))
  return any ? String(any.name) : null
}

const TEXT = 2000
const str = (v, max = TEXT) => (typeof v === 'string' ? v.trim().slice(0, max) : '')
const RULES = {
  tier: (v) => /^[ABCS]$/i.test(String(v)) ? String(v).toUpperCase() : null,
  state: (v) => /^[A-Za-z]{2}$/.test(String(v)) ? String(v).toUpperCase() : null,
  category: (v) => { const s = String(v).toLowerCase().replace(/\s/g, ''); return /^[a-z_]+(,[a-z_]+)*$/.test(s) ? s : null },
  area_code: (v) => { const s = String(v).replace(/\s/g, ''); return /^[2-9]\d{2}(,[2-9]\d{2})*$/.test(s) ? s : null },
  source: (v) => { const s = String(v).toLowerCase().replace(/\s/g, ''); return /^[a-z]+(,[a-z]+)*$/.test(s) ? s : null },
  website_type: (v) => ['none', 'social', 'site', 'unreachable'].includes(String(v)) ? String(v) : null,
  phone_type: (v) => ['mobile', 'landline', 'voip', 'unknown'].includes(String(v)) ? String(v) : null,
  min_score: (v) => { const n = Number(v); return Number.isInteger(n) && n > 0 && n <= 100 ? n : null },
  intent: (v) => /^[a-z_]+$/.test(String(v)) ? String(v) : null,
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

/** Gemini's answer, read defensively: the page renders whatever comes out of
 *  here, so everything is a string of bounded length or a list of such objects. */
export function parseBrief(text) {
  let raw = String(text ?? '').trim()
  const fence = /^```(?:json)?\s*([\s\S]*?)\s*```$/.exec(raw)
  if (fence) raw = fence[1]
  let j
  try { j = JSON.parse(raw) } catch { throw new GeminiError('Gemini answered, but not with readable JSON.') }
  if (!j || typeof j !== 'object' || Array.isArray(j)) throw new GeminiError('Gemini answered with something other than an analysis.')
  const list = (v, n) => (Array.isArray(v) ? v.slice(0, n) : [])
  const brief = {
    headline: str(j.headline, 300),
    summary: str(j.summary),
    findings: list(j.findings, 8).map((f) => ({ title: str(f?.title, 200), detail: str(f?.detail), evidence: str(f?.evidence, 600) })).filter((f) => f.title || f.detail),
    where_to_call: list(j.where_to_call, 8).map((w) => ({ segment: str(w?.segment, 300), when: str(w?.when, 200), why: str(w?.why, 600) })).filter((w) => w.segment),
    agent_matching: list(j.agent_matching, 20).map((a) => ({ agent: str(a?.agent, 100), focus: str(a?.focus, 400), why: str(a?.why, 600) })).filter((a) => a.agent),
    lists: list(j.lists, 6).map((l) => ({ name: str(l?.name, 80), rules: cleanRules(l?.rules), why: str(l?.why, 600) }))
      .filter((l) => l.name && Object.keys(l.rules).length),
    cautions: list(j.cautions, 6).map((c) => str(c, 400)).filter(Boolean),
  }
  if (!brief.headline && !brief.summary && !brief.findings.length) throw new GeminiError('Gemini answered with an empty analysis.')
  return brief
}

async function call(fetchFn, url, apiKey, init, timeoutMs) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    return await fetchFn(url, { ...init, headers: { ...(init?.headers ?? {}), 'x-goog-api-key': apiKey }, signal: ctl.signal })
  } catch (e) {
    if (e?.name === 'AbortError') throw new GeminiError(`Gemini did not answer within ${Math.round(timeoutMs / 1000)} seconds.`)
    throw new GeminiError(`Could not reach Gemini: ${e?.message ?? e}`)
  } finally { clearTimeout(timer) }
}

async function explain(res) {
  let msg = ''
  try { const j = await res.json(); msg = j?.error?.message ?? '' } catch { /* not JSON */ }
  if (res.status === 400 && /api key/i.test(msg)) return new GeminiError('Gemini refused the API key. Check GEMINI_API_KEY in Supabase → Edge Functions → Secrets.', 400)
  if (res.status === 401 || res.status === 403) return new GeminiError(`Gemini refused the request (${res.status}): ${msg || 'the key may lack access to this model'}`, res.status)
  if (res.status === 429) return new GeminiError(`Gemini's quota for this key is used up for now (429): ${msg}`, 429)
  return new GeminiError(`Gemini answered ${res.status}${msg ? `: ${msg}` : ''}`, res.status)
}

export async function newestFlash(apiKey, fetchFn = fetch, timeoutMs = 20_000) {
  const res = await call(fetchFn, `${API}/models?pageSize=200`, apiKey, { method: 'GET' }, timeoutMs)
  if (!res.ok) throw await explain(res)
  const name = pickModel((await res.json())?.models)
  if (!name) throw new GeminiError('This key can reach no Gemini Flash model. Set one in Settings → AI → model.')
  return name
}

/** Ask Gemini for the floor analysis. Returns { model, brief }. A configured
 *  model that no longer exists falls back to the newest Flash, and says so. */
export async function generateBrief({ apiKey, model, snapshot, fetchFn = fetch, timeoutMs = 90_000 }) {
  if (!apiKey) throw new GeminiError('GEMINI_API_KEY is not set.')
  const configured = model ? (String(model).startsWith('models/') ? String(model) : `models/${model}`) : null
  let name = configured ?? await newestFlash(apiKey, fetchFn)
  const body = JSON.stringify({
    systemInstruction: { parts: [{ text: SYSTEM }] },
    contents: [{ role: 'user', parts: [{ text: buildPrompt(snapshot) }] }],
    // newer Flash models think before they answer, and the thinking counts against this cap
    generationConfig: { temperature: 0.3, responseMimeType: 'application/json', maxOutputTokens: 32768 },
  })
  const ask = (n) => call(fetchFn, `${API}/${n}:generateContent`, apiKey,
    { method: 'POST', headers: { 'content-type': 'application/json' }, body }, timeoutMs)
  let res = await ask(name)
  let note = null
  if (res.status === 404 && configured) {
    name = await newestFlash(apiKey, fetchFn)
    note = `${configured.replace('models/', '')} is not available, so ${name.replace('models/', '')} was used`
    res = await ask(name)
  }
  if (!res.ok) throw await explain(res)
  const j = await res.json()
  const cand = j?.candidates?.[0]
  const text = (cand?.content?.parts ?? []).map((p) => p?.text ?? '').join('')
  if (!text) {
    const why = cand?.finishReason ?? j?.promptFeedback?.blockReason ?? 'no text'
    throw new GeminiError(`Gemini returned no analysis (${why}).`)
  }
  if (cand?.finishReason === 'MAX_TOKENS') throw new GeminiError('Gemini ran out of room before finishing the analysis. Ask again.')
  const brief = parseBrief(text)
  if (note) brief.cautions = [note, ...brief.cautions].slice(0, 6)
  return { model: name.replace('models/', ''), brief }
}
