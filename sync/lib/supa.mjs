import { createClient } from '@supabase/supabase-js'

export const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } },
)

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

/** Upsert a batch; returns { imported: sourceIdsNewlyInserted, upserted: count }.
 *  markPending flags newly inserted leads to be marked `contacted` in the console. */
export async function upsertLeads(rows, { markPending = false } = {}) {
  const mapped = rows.map(mapLead).filter(Boolean)
  if (!mapped.length) return { imported: [], upserted: 0 }

  const srcIds = mapped.map((m) => m.source_id)
  const { data: existing, error: exErr } = await supa
    .from('leads').select('source_id, console_mark_pending').in('source_id', srcIds)
  if (exErr) throw exErr
  const known = new Map((existing ?? []).map((r) => [r.source_id, r.console_mark_pending]))
  const fresh = srcIds.filter((id) => !known.has(id))

  // The flag rides in the same write as the lead, so a run that dies before the
  // console hears about it can't lose it: the next pull's flushContacted() retries.
  for (const m of mapped) m.console_mark_pending = known.has(m.source_id) ? known.get(m.source_id) : markPending

  const { data: up, error } = await supa
    .from('leads')
    .upsert(mapped, { onConflict: 'source_id' })
    .select('id')
  if (error) throw error

  for (const r of up ?? []) {
    const { error: rErr } = await supa.rpc('refresh_lead', { p_lead_id: r.id })
    if (rErr) throw rErr
  }
  return { imported: fresh, upserted: mapped.length }
}

export async function logRun(kind, fn) {
  const { data: run } = await supa.from('sync_runs')
    .insert({ kind }).select('id').single()
  try {
    const rows = await fn()
    await supa.from('sync_runs').update({
      finished_at: new Date().toISOString(), rows, ok: true,
    }).eq('id', run.id)
    return rows
  } catch (e) {
    await supa.from('sync_runs').update({
      finished_at: new Date().toISOString(), ok: false, detail: String(e),
    }).eq('id', run.id)
    throw e
  }
}
