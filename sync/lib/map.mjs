// Console lead rows -> dialing DB rows. No I/O, so preview.mjs can use it too.

export function normPhone(p) {
  const d = String(p ?? '').replace(/\D/g, '')
  return d.length === 11 && d.startsWith('1') ? d.slice(1) : d
}

/** Map a console lead row onto the dialing DB's leads table. */
export function mapLead(row) {
  let extras = row.extras
  if (typeof extras === 'string') { try { extras = JSON.parse(extras) } catch { extras = null } }
  const phone = normPhone(row.phone)
  if (phone.length !== 10) return null
  const categories = Array.isArray(extras?.categories) && extras.categories.length
    ? extras.categories
    : (row.category ? [row.category] : null)
  return {
    source_id: Number(row.id),
    place_id: row.place_id ?? null,
    name: row.name ?? '(unnamed)',
    phone_norm: phone,
    phone_display: row.phone ?? null,
    phone_type: row.phone_type ?? null,
    phone_carrier: row.phone_carrier ?? null,
    category: row.category ?? null,
    category_key: row.category_key ?? null,
    categories,
    tier: row.tier ?? null,
    score: row.lead_score != null ? Number(row.lead_score) : null,
    rating: row.rating != null ? Number(row.rating) : null,
    review_count: row.review_count != null ? Number(row.review_count) : null,
    website: row.website ?? null,
    website_type: row.website_type ?? null,
    platform: row.platform ?? null,
    platform_detail: row.platform_detail ?? null,
    email: row.email ?? extras?.email ?? null,
    address: row.address ?? null,
    addr_city: row.addr_city ?? row.city ?? null,
    addr_state: row.addr_state ?? row.state ?? null,
    zip: row.zip ?? null,
    extras: extras ?? null,
    source: row.source ?? null,
    search_query: row.search_query ?? null,
    maps_url: row.maps_url ?? null,
    first_seen: row.first_seen ?? row.created_at ?? null,
    synced_at: new Date().toISOString(),
  }
}
