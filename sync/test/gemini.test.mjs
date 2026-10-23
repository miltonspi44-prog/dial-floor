// floor-ai's Gemini client, without a key: a fake fetch stands in for Google.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { pickModel, parseBrief, cleanRules, buildPrompt, generateBrief, probe, GeminiError } from '../../supabase/functions/floor-ai/gemini.mjs'

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

// a streamed reply is server-sent events, one GenerateContentResponse per event
const sse = (chunks) => chunks.map((c) => `data: ${JSON.stringify(c)}\r\n\r\n`).join('')
const piece = (text, finishReason) => ({ candidates: [{ content: { parts: [{ text }] }, ...(finishReason ? { finishReason } : {}) }] })

function fakeFetch(routes, seen = []) {
  return async (url, init) => {
    seen.push({ url, init })
    for (const [pattern, reply] of routes) {
      if (pattern.test(url)) {
        const r = typeof reply === 'function' ? reply(url, init) : reply
        return new Response(r.sse ? sse(r.sse) : JSON.stringify(r.body), { status: r.status })
      }
    }
    return new Response('{}', { status: 500 })
  }
}

const answer = { status: 200, sse: [piece('{"headline":"h",'), piece('"summary":"s","findings":[]}', 'STOP')] }

test('with no model set, the newest Flash is found and asked; the key travels in a header, never the URL', async () => {
  const seen = []
  const f = fakeFetch([
    [/\/models\?/, { status: 200, body: { models: [{ name: 'models/gemini-3.5-flash', supportedGenerationMethods: gen }] } }],
    [/gemini-3\.5-flash:streamGenerateContent\?alt=sse$/, answer],
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
    [/gemini-1\.0-flash:streamGenerateContent/, { status: 404, body: { error: { message: 'not found' } } }],
    [/\/models\?/, { status: 200, body: { models: [{ name: 'models/gemini-3-flash', supportedGenerationMethods: gen }] } }],
    [/gemini-3-flash:streamGenerateContent/, answer],
  ])
  const out = await generateBrief({ apiKey: 'k', model: 'gemini-1.0-flash', snapshot: {}, fetchFn: f })
  assert.equal(out.model, 'gemini-3-flash')
  assert.match(out.brief.cautions[0], /gemini-1\.0-flash was not available \(404\), so gemini-3-flash wrote this analysis/)
})

test('a refused key, a spent quota and a missing key each say what to do', async () => {
  const bad = fakeFetch([[/GenerateContent/, { status: 400, body: { error: { message: 'API key not valid. Please pass a valid API key.' } } }]])
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3-flash', snapshot: {}, fetchFn: bad }), /refused the API key.*Secrets/)
  const quota = fakeFetch([
    [/\/models\?/, { status: 200, body: { models: [{ name: 'models/gemini-3-flash', supportedGenerationMethods: gen }] } }],
    [/GenerateContent/, { status: 429, body: { error: { message: 'Resource exhausted' } } }]])
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3-flash', snapshot: {}, fetchFn: quota }), /gemini-3-flash had no quota left \(429\)/)
  await assert.rejects(generateBrief({ apiKey: '', model: '', snapshot: {} }), /GEMINI_API_KEY is not set/)
})

test('an answer cut off by the output cap is reported as such, not as broken JSON', async () => {
  const f = fakeFetch([[/GenerateContent/, { status: 200, sse: [piece('{"headline":"h","summ', 'MAX_TOKENS')] }]])
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3-flash', snapshot: {}, fetchFn: f }), /ran out of room/)
})

test('Gemini 3 and later are asked to think lightly, 2.5 gets a budget, and temperature is left alone', async () => {
  const seen = []
  const f = fakeFetch([[/GenerateContent/, answer]], seen)
  await generateBrief({ apiKey: 'k', model: 'gemini-3.8-flash', snapshot: {}, fetchFn: f })
  await generateBrief({ apiKey: 'k', model: 'gemini-2.5-flash', snapshot: {}, fetchFn: f })
  const [g3, g25] = seen.map((s) => JSON.parse(s.init.body).generationConfig)
  assert.deepEqual(g3.thinkingConfig, { thinkingLevel: 'LOW' })
  assert.deepEqual(g25.thinkingConfig, { thinkingBudget: 2048 })
  assert.ok(!('temperature' in g3) && !('temperature' in g25))
})

test('a model that refuses the thinking setting is asked again without it', async () => {
  const seen = []
  const f = fakeFetch([[/GenerateContent/, (url, init) => JSON.parse(init.body).generationConfig.thinkingConfig
    ? { status: 400, body: { error: { message: 'Thinking level is not supported for this model.' } } }
    : answer]], seen)
  const out = await generateBrief({ apiKey: 'k', model: 'gemini-3-flash', snapshot: {}, fetchFn: f })
  assert.equal(out.brief.headline, 'h')
  assert.equal(seen.length, 2)
  const other = fakeFetch([[/GenerateContent/, { status: 400, body: { error: { message: 'Request contains an invalid argument.' } } }]])
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3-flash', snapshot: {}, fetchFn: other }), /invalid argument/)
})

test('a model too slow to answer is named in the message', async () => {
  const slow = async (url, init) => new Promise((_, reject) => init.signal.addEventListener('abort', () => {
    const e = new Error('aborted'); e.name = 'AbortError'; reject(e)
  }))
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3.8-flash', snapshot: {}, fetchFn: slow, timeoutMs: 20 }),
    /gemini-3\.8-flash did not start answering within 0 seconds/)
})

// a stream that sends these events and then stays open until the request is aborted
function hanging(chunks, every = 0) {
  return async (url, init) => {
    const enc = new TextEncoder()
    let timer = null
    const body = new ReadableStream({
      start(c) {
        for (const ch of chunks) c.enqueue(enc.encode(sse([ch])))
        if (every) timer = setInterval(() => c.enqueue(enc.encode(sse([piece(' '.repeat(500))]))), every)
        init.signal.addEventListener('abort', () => {
          clearInterval(timer)
          const e = new Error('aborted'); e.name = 'AbortError'; c.error(e)
        })
      },
      cancel() { clearInterval(timer) },
    })
    return new Response(body, { status: 200 })
  }
}

test('the answer is taken the moment it is whole, without waiting for the stream to close', async () => {
  const f = hanging([piece('{"headline":"h","summary":"s",'), piece('"findings":[]}')])
  const t0 = Date.now()
  const out = await generateBrief({ apiKey: 'k', model: 'gemini-3.8-flash', snapshot: {}, fetchFn: f, timeoutMs: 5000 })
  assert.equal(out.brief.headline, 'h')
  assert.ok(Date.now() - t0 < 1000)
})

test('a model trailing off into blank space mid-answer is stopped, and one too slow says how far it got', async () => {
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3.8-flash', snapshot: {}, timeoutMs: 5000,
    fetchFn: hanging([piece('{"headline":"h", ')], 5) }), /trailed off into blank space/)
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3.8-flash', snapshot: {}, timeoutMs: 30,
    fetchFn: hanging([piece('{"headline":"h"')]) }), /gemini-3\.8-flash was still writing after 0 seconds \(15 characters so far\)/)
  await assert.rejects(generateBrief({ apiKey: 'k', model: 'gemini-3.8-flash', snapshot: {}, timeoutMs: 30,
    fetchFn: hanging([]) }), /gemini-3\.8-flash sent nothing in 0 seconds/)
})

test('the probe reports each model it tried, with timings, and never the key', async () => {
  const f = fakeFetch([
    [/\/models\?/, { status: 200, body: { models: [
      { name: 'models/gemini-3.8-flash', supportedGenerationMethods: gen },
      { name: 'models/gemini-3.6-flash', supportedGenerationMethods: gen },
      { name: 'models/gemini-2.5-flash', supportedGenerationMethods: gen }] } }],
    [/gemini-3\.8-flash:generateContent$/, { status: 503, body: { error: { message: 'The model is overloaded.' } } }],
    [/:generateContent$/, { status: 200, body: { candidates: [{ finishReason: 'STOP', content: { parts: [{ text: 'ok' }] } }] } }],
  ])
  const out = await probe({ apiKey: 'k-secret', fetchFn: f })
  assert.equal(out.picked, 'gemini-3.8-flash')
  assert.deepEqual(out.tries.map((t) => [t.model, t.status]), [['gemini-3.8-flash', 503], ['gemini-3.8-flash', 503], ['gemini-3.6-flash', 200], ['gemini-2.5-flash', 200]])
  assert.equal(out.tries[1].thinking, null)
  assert.match(out.tries[0].error, /overloaded/)
  assert.ok(!JSON.stringify(out).includes('k-secret'))
})

test('a busy model is passed over for the next newest Flash, and the analysis says so', async () => {
  const listing = { status: 200, body: { models: ['gemini-3.8-flash', 'gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-2.5-flash']
    .map((n) => ({ name: `models/${n}`, supportedGenerationMethods: gen })) } }
  const busy = { status: 503, body: { error: { message: 'This model is currently experiencing high demand.' } } }
  const seen = []
  const f = fakeFetch([[/\/models\?/, listing], [/gemini-3\.8-flash:/, busy], [/gemini-3\.7-flash:/, answer]], seen)
  const out = await generateBrief({ apiKey: 'k', model: '', snapshot: {}, fetchFn: f })
  assert.equal(out.model, 'gemini-3.7-flash')
  assert.match(out.brief.cautions[0], /^gemini-3\.8-flash was busy \(503\), so gemini-3\.7-flash wrote this analysis$/)
  assert.ok(!seen.some((s) => /3\.6-flash/.test(s.url)), 'no further model is asked once one answers')

  const allBusy = fakeFetch([[/\/models\?/, listing], [/:streamGenerateContent/, busy]])
  await assert.rejects(generateBrief({ apiKey: 'k', model: '', snapshot: {}, fetchFn: allBusy }),
    /No Gemini model could write the analysis just now: gemini-3\.8-flash was busy \(503\); gemini-3\.7-flash was busy \(503\); gemini-3\.6-flash was busy \(503\); gemini-2\.5-flash was busy \(503\)\. Ask again/)
})

test('a model that never starts answering is passed over after the start limit', async () => {
  const listing = { status: 200, body: { models: ['gemini-3.8-flash', 'gemini-3.7-flash']
    .map((n) => ({ name: `models/${n}`, supportedGenerationMethods: gen })) } }
  const routes = fakeFetch([[/\/models\?/, listing], [/gemini-3\.7-flash:/, answer]])
  const f = (url, init) => /3\.8-flash:/.test(url)
    ? new Promise((_, reject) => init.signal.addEventListener('abort', () => { const e = new Error('aborted'); e.name = 'AbortError'; reject(e) }))
    : routes(url, init)
  const out = await generateBrief({ apiKey: 'k', model: '', snapshot: {}, fetchFn: f, timeoutMs: 30_000, startMs: 20 })
  assert.equal(out.model, 'gemini-3.7-flash')
  assert.match(out.brief.cautions[0], /gemini-3\.8-flash did not start answering within 0 seconds, so gemini-3\.7-flash/)
})
