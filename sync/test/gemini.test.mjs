// floor-ai's Gemini client, without a key: a fake fetch stands in for Google.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { pickModel, parseBrief, cleanRules, buildPrompt, generateBrief, GeminiError } from '../../supabase/functions/floor-ai/gemini.mjs'

const gen = ['generateContent']

test('the newest stable Flash model is picked, previews and other kinds left alone', () => {
  assert.equal(pickModel([
    { name: 'models/gemini-2.5-flash', supportedGenerationMethods: gen },
    { name: 'models/gemini-3.5-flash', supportedGenerationMethods: gen },
    { name: 'models/gemini-4-flash-preview', supportedGenerationMethods: gen },
    { name: 'models/gemini-3-pro', supportedGenerationMethods: gen },
    { name: 'models/text-embedding-004', supportedGenerationMethods: ['embedContent'] },
  ]), 'models/gemini-3.5-flash')
  assert.equal(pickModel([{ name: 'models/gemini-3-flash-001', supportedGenerationMethods: gen }]), 'models/gemini-3-flash-001')
  assert.equal(pickModel([{ name: 'models/gemini-3-pro', supportedGenerationMethods: gen }]), null)
})

test('only rules the list builder understands survive, in its own form', () => {
  assert.deepEqual(cleanRules({ tier: 'a', state: 'wa', category: 'remodeling, flooring', area_code: '206, 425', source: 'Angi',
                                website_type: 'none', phone_type: 'mobile', min_score: 60, city: 'Seattle', drop: 'table' }),
    { tier: 'A', state: 'WA', category: 'remodeling,flooring', area_code: '206,425', source: 'angi', website_type: 'none', phone_type: 'mobile', min_score: 60 })
  assert.deepEqual(cleanRules({ state: 'Washington', area_code: '20', tier: 'Z', min_score: 900 }), {})
})

test('an answer is read defensively: fenced, oversized or broken', () => {
  const b = parseBrief('```json\n{"headline":"Call WA remodelers","summary":"s","findings":[{"title":"t","detail":"d","evidence":"e"}],' +
    '"lists":[{"name":"WA no-site","rules":{"state":"WA","website_type":"none"},"why":"w"},{"name":"bad","rules":{"city":"x"}}],' +
    `"cautions":["${'x'.repeat(900)}"]}\n\`\`\``)
  assert.equal(b.headline, 'Call WA remodelers')
  assert.equal(b.lists.length, 1, 'a list with no usable rule is dropped')
  assert.equal(b.cautions[0].length, 400, 'text is bounded')
  assert.deepEqual(b.agent_matching, [])
  assert.throws(() => parseBrief('not json'), GeminiError)
  assert.throws(() => parseBrief('{}'), /empty analysis/)
})

test('the prompt carries the data and the shape, and nothing it was not given', () => {
  const p = buildPrompt({ model: { dials: 2576 }, agents: [{ agent: 'Alex' }] })
  assert.match(p, /"dials":2576/)
  assert.match(p, /"where_to_call"/)
})

function fakeFetch(routes, seen = []) {
  return async (url, init) => {
    seen.push({ url, init })
    for (const [pattern, reply] of routes) {
      if (pattern.test(url)) {
        const r = typeof reply === 'function' ? reply(url, init) : reply
        return { ok: r.status < 400, status: r.status, json: async () => r.body }
      }
    }
    return { ok: false, status: 500, json: async () => ({}) }
  }
}

const answer = { candidates: [{ content: { parts: [{ text: '{"headline":"h","summary":"s","findings":[]}' }] } }] }

test('with no model set, the newest Flash is found and asked; the key travels in a header, never the URL', async () => {
  const seen = []
  const f = fakeFetch([
    [/\/models\?/, { status: 200, body: { models: [{ name: 'models/gemini-3.5-flash', supportedGenerationMethods: gen }] } }],
    [/gemini-3\.5-flash:generateContent$/, { status: 200, body: answer }],
  ], seen)
  const out = await generateBrief({ apiKey: 'k-123', model: '', snapshot: {}, fetchFn: f })
  assert.equal(out.model, 'gemini-3.5-flash')
  assert.equal(out.brief.headline, 'h')
  assert.ok(seen.every((s) => !s.url.includes('k-123') && s.init.headers['x-goog-api-key'] === 'k-123'))
  const sent = JSON.parse(seen[1].init.body)
  assert.equal(sent.generationConfig.responseMimeType, 'application/json')
})

test('a configured model that is gone falls back to the newest Flash and says so', async () => {
  const f = fakeFetch([
    [/gemini-1\.0-flash:generateContent$/, { status: 404, body: { error: { message: 'not found' } } }],
    [/\/models\?/, { status: 200, body: { models: [{ name: 'models/gemini-3-flash', supportedGenerationMethods: gen }] } }],
    [/gemini-3-flash:generateContent$/, { status: 200, body: answer }],
  ])
  const out = await generateBrief({ apiKey: 'k', model: 'gemini-1.0-flash', snapshot: {}, fetchFn: f })
  assert.equal(out.model, 'gemini-3-flash')
  assert.match(out.brief.cautions[0], /gemini-1\.0-flash is not available/)
})

test('a refused key, a spent quota and a missing key each say what to do', async () => {
  const bad = fakeFetch([[/generateContent$/, { status: 400, body: { error: { message: 'API key not valid. Please pass a valid API key.' } } }]])
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3-flash', snapshot: {}, fetchFn: bad }), /refused the API key.*Secrets/)
  const quota = fakeFetch([[/generateContent$/, { status: 429, body: { error: { message: 'Resource exhausted' } } }]])
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3-flash', snapshot: {}, fetchFn: quota }), /quota/)
  await assert.rejects(generateBrief({ apiKey: '', model: '', snapshot: {} }), /GEMINI_API_KEY is not set/)
})
