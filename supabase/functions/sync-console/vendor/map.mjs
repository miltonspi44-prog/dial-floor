// Console lead rows -> dialing DB rows. No I/O, so preview.mjs can use it too.

export function normPhone(p) {
  const d = String(p ?? '').replace(/\D/g, '')
  return d.length === 11 && d.startsWith('1') ? d.slice(1) : d
}

// A field the console has nothing in can reach us in three shapes: missing from
// the row, null, or — from a CSV export — an empty cell. All three mean "the
// console knows nothing here", never "set this to nothing", so every field below
// goes through this and comes out as a plain null the upsert knows to leave alone.
function blank(v) {
  if (v == null) return null
  if (typeof v !== 'string') return v
  const s = v.trim()
  return s === '' ? null : s
}

// An empty CSV cell used to become 0 here, because Number('') is 0: that wrote a
// score of 0 and a rating of 0 over numbers the console had sent us before.
function num(v) {
  const b = blank(v)
  if (b == null) return null
  const n = Number(b)
  return Number.isFinite(n) ? n : null
}

/** Every column mapLead writes, so a caller can read the same set back. */
export const LEAD_COLUMNS = [
  'source_id', 'place_id', 'name', 'phone_norm', 'phone_display', 'phone_type', 'phone_carrier',
  'category', 'category_key', 'categories', 'tier', 'score', 'rating', 'review_count',
  'website', 'website_type', 'platform', 'platform_detail', 'email',
  'address', 'addr_city', 'addr_state', 'zip', 'extras', 'source', 'search_query', 'maps_url',
  'first_seen', 'synced_at',
]

// What refresh_lead() reads to work out a lead's timezone and its automatic
// intents. When none of these moved, calling it again would compute the same
// answer, and on a full refresh pass that is thousands of round trips for nothing.
const REFRESH_INPUTS = [
  'phone_norm', 'addr_state', 'phone_type', 'website_type', 'platform', 'platform_detail',
  'categories', 'extras', 'rating', 'review_count', 'first_seen',
]

/** Map a console lead row onto the dialing DB's leads table. */
export function mapLead(row) {
  let extras = row.extras
  if (typeof extras === 'string') { try { extras = JSON.parse(extras) } catch { extras = null } }
  // "Paying for ads" and "Badge holder" (item 19): the console sends sponsored
  // and yelp_guaranteed as their own columns, while the intent rules read
  // extras.sponsored and extras.guaranteed — so the two intents could never
  // fire. Only a value the console actually sent lands here; a missing column
  // must not erase a flag already sitting in extras.
  const sponsored = blank(row.sponsored)
  const guaranteed = blank(row.yelp_guaranteed)
  if (sponsored != null || guaranteed != null) {
    extras = { ...(extras ?? {}) }
    if (sponsored != null) extras.sponsored = sponsored
    if (guaranteed != null) extras.guaranteed = guaranteed
  }
  const phone = normPhone(row.phone)
  if (phone.length !== 10) return null
  const category = blank(row.category)
  const categories = Array.isArray(extras?.categories) && extras.categories.length
    ? extras.categories
    : (category ? [category] : null)
  return {
    source_id: num(row.id),
    place_id: blank(row.place_id),
    // The dialing DB insists on a name. A row with none is left null here and
    // filled in by whoever writes it, so a blank from the console cannot
    // overwrite the name we already show the agent.
    name: blank(row.name),
    phone_norm: phone,
    phone_display: blank(row.phone),
    phone_type: blank(row.phone_type),
    phone_carrier: blank(row.phone_carrier),
    category,
    category_key: blank(row.category_key),
    categories,
    tier: blank(row.tier),
    score: num(row.lead_score),
    rating: num(row.rating),
    review_count: num(row.review_count),
    website: blank(row.website),
    website_type: blank(row.website_type),
    platform: blank(row.platform),
    platform_detail: blank(row.platform_detail),
    email: blank(row.email) ?? blank(extras?.email),
    address: blank(row.address),
    addr_city: blank(row.addr_city) ?? blank(row.city),
    addr_state: blank(row.addr_state) ?? blank(row.state),
    zip: blank(row.zip),
    extras: extras ?? null,
    source: blank(row.source),
    search_query: blank(row.search_query),
    maps_url: blank(row.maps_url),
    first_seen: blank(row.first_seen) ?? blank(row.created_at),
    synced_at: new Date().toISOString(),
  }
}

// A timestamp from the console has no timezone on it ("2026-09-01 12:00:00") and
// Postgres hands the same moment back as "2026-09-01T12:00:00+00:00". Date.parse
// reads the first shape in whatever timezone this PC is set to, so on the owner's
// machine the two differ by the offset and every lead looks changed every quarter
// of an hour. The console keeps UTC and so does the dialing DB, so a stamp with no
// zone on it is read as UTC here — which is exactly how Postgres read it when we
// wrote it. Only something that really looks like a date is treated as one:
// Date.parse says yes to far too much.
const DATEISH = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$/

function instant(v) {
  if (typeof v !== 'string') return null
  const m = DATEISH.exec(v.trim())
  if (!m) return null
  // A zone is on it: read it as written.
  if (m[8]) {
    const t = Date.parse(v.trim().replace(' ', 'T'))
    return Number.isFinite(t) ? t : null
  }
  return Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0), +(m[6] ?? 0),
    m[7] ? Math.round(Number(m[7]) * 1000) : 0)
}

// Two values mean the same thing, allowing for the trip through two databases:
// Postgres hands back 7 where MySQL sent "7", a timestamp comes back in a
// different shape than it went out in, and jsonb comes back with its keys in
// Postgres's own order — shortest first, then alphabetical — not the order the
// console wrote them in. Comparing the printed JSON of two objects therefore says
// "different" about two identical ones, so objects are compared key by key.
function same(a, b) {
  if (a === b) return true
  if (a == null || b == null) return a == null && b == null
  if (typeof a === 'boolean' || typeof b === 'boolean') return a === b
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
    return a.every((v, i) => same(v, b[i]))
  }
  if (typeof a === 'object' || typeof b === 'object') {
    if (typeof a !== 'object' || typeof b !== 'object') return false
    const ka = Object.keys(a), kb = Object.keys(b)
    if (ka.length !== kb.length) return false
    return ka.every((k) => Object.hasOwn(b, k) && same(a[k], b[k]))
  }
  const na = Number(a), nb = Number(b)
  if (Number.isFinite(na) && Number.isFinite(nb)) return na === nb
  const ta = instant(a), tb = instant(b)
  if (ta != null && tb != null) return ta === tb
  return String(a) === String(b)
}

/** Fill a mapped row's blanks from the lead we already hold, in place.
 *  The console having nothing to say about a field is not a reason to throw away
 *  what is in that field — an email an agent captured on a call lives in one, and
 *  the console has no email column at all, so a plain copy wipes it every pull. */
export function keepWhatWeHave(next, prev) {
  for (const col of LEAD_COLUMNS) {
    if (col === 'synced_at' || col === 'source_id') continue
    if (next[col] == null && prev[col] != null) next[col] = prev[col]
  }
  return next
}

/** Would writing this row change anything refresh_lead() looks at? */
export function needsRefresh(next, prev) {
  return REFRESH_INPUTS.some((col) => !same(next[col], prev[col]))
}

/** Has the console actually got something different to say about this lead?
 *  The refresh pass walks the console's whole list every quarter of an hour and
 *  writes every row it recognises, so "rows written" counts the table, not the
 *  news. This is what the run counter should count: when it reads 0 the owner can
 *  trust that nothing came in. `synced_at` is when we last asked, which changes on
 *  every pass and is not news about the lead. */
export function sameRow(next, prev) {
  return LEAD_COLUMNS.every((col) => col === 'synced_at' || same(next[col], prev[col]))
}
