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

// Two values mean the same thing, allowing for the trip through two databases:
// Postgres hands back 7 where MySQL sent "7", and a timestamp comes back in a
// different shape than it went out in.
function same(a, b) {
  if (a == null || b == null) return a == null && b == null
  if (typeof a === 'object' || typeof b === 'object') return JSON.stringify(a) === JSON.stringify(b)
  const na = Number(a), nb = Number(b)
  if (Number.isFinite(na) && Number.isFinite(nb)) return na === nb
  const ta = Date.parse(a), tb = Date.parse(b)
  if (Number.isFinite(ta) && Number.isFinite(tb)) return ta === tb
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
