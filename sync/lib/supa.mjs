import { createClient } from '@supabase/supabase-js'
import { mapLead } from './map.mjs'

export { normPhone, mapLead } from './map.mjs'

if (!process.env.SUPABASE_SERVICE_KEY) throw new Error('SUPABASE_SERVICE_KEY missing (.env or environment)')
export const supa = createClient(
  process.env.SUPABASE_URL ?? 'https://fevjrcxmktjwbaozbngo.supabase.co',
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } },
)

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
