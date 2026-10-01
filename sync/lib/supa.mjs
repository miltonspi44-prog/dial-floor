import { createClient } from '@supabase/supabase-js'
import { mapLead, keepWhatWeHave, needsRefresh, LEAD_COLUMNS } from './map.mjs'

export { normPhone, mapLead } from './map.mjs'

if (!process.env.SUPABASE_SERVICE_KEY) throw new Error('SUPABASE_SERVICE_KEY missing (.env or environment)')
export const supa = createClient(
  process.env.SUPABASE_URL ?? 'https://fevjrcxmktjwbaozbngo.supabase.co',
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } },
)

// refresh_lead() is one round trip per lead, so a full import pays it thousands of
// times. Each call is its own transaction over one lead's own rows, so a handful
// at a time is safe and finishes in a fraction of the wall clock.
const REFRESH_AT_ONCE = 5

/** Upsert a batch; returns { imported, upserted, refreshed, skipped, unusable, ids }:
 *  `imported` is the source ids newly inserted, `skipped` the rows with no console
 *  id, `unusable` the rows whose phone number no one can dial, `ids` maps every
 *  written row's source id to its lead id, and `markPending` flags newly inserted
 *  leads to be marked `contacted` in the console. */
export async function upsertLeads(rows, { markPending = false } = {}) {
  const all = rows.map(mapLead).filter(Boolean)
  const unusable = rows.length - all.length
  // A lead with no console id cannot be matched on a later run — onConflict has
  // nothing to match on and Postgres treats every null as its own value — so
  // importing one means a fresh duplicate of it on every import. Better to leave
  // it out and have the caller say so than to quietly fill the floor with twins.
  const mapped = all.filter((m) => m.source_id != null)
  const skipped = all.length - mapped.length
  if (!mapped.length) return { imported: [], upserted: 0, refreshed: 0, skipped, unusable, ids: new Map() }

  // Two rows for one console id in a single statement make Postgres stop with
  // "cannot affect row a second time". The console never sends an id twice, but a
  // CSV that someone pasted two exports into does; the last one wins.
  const byId = new Map(mapped.map((m) => [m.source_id, m]))
  const batch = [...byId.values()]

  const srcIds = batch.map((m) => m.source_id)
  const { data: existing, error: exErr } = await supa
    .from('leads').select(['id', 'console_mark_pending', ...LEAD_COLUMNS].join(','))
    .in('source_id', srcIds)
  if (exErr) throw exErr
  const known = new Map((existing ?? []).map((r) => [Number(r.source_id), r]))

  for (const m of batch) {
    const prev = known.get(m.source_id)
    // The flag rides in the same write as the lead, so a run that dies before the
    // console hears about it can't lose it: the next pull's flushContacted() retries.
    m.console_mark_pending = prev ? prev.console_mark_pending : markPending
    if (prev) keepWhatWeHave(m, prev)
    // The column is not-null and the console had nothing to call this one.
    if (m.name == null) m.name = prev?.name ?? '(unnamed)'
  }

  const { data: up, error } = await supa
    .from('leads')
    .upsert(batch, { onConflict: 'source_id' })
    .select('id, source_id')
  if (error) throw error

  const ids = new Map((up ?? []).map((r) => [Number(r.source_id), r.id]))
  // A lead whose timezone and intent inputs all came back unchanged would get the
  // same answer out of refresh_lead() as last time, and the refresh pass finds
  // almost nothing changed. A brand new lead always needs it: that is the call
  // that gives it a lead_state row and puts it in the queue.
  const due = batch
    .filter((m) => { const prev = known.get(m.source_id); return !prev || needsRefresh(m, prev) })
    .map((m) => ids.get(m.source_id))
    .filter((id) => id != null)
  await refreshLeads(due)

  return {
    imported: srcIds.filter((id) => !known.has(id)),
    upserted: batch.length,
    refreshed: due.length,
    skipped,
    unusable,
    ids,
  }
}

/** Recompute timezone, queue state and automatic intents for these lead ids. */
export async function refreshLeads(leadIds) {
  for (let i = 0; i < leadIds.length; i += REFRESH_AT_ONCE) {
    const slice = leadIds.slice(i, i + REFRESH_AT_ONCE)
    const results = await Promise.all(slice.map((id) => supa.rpc('refresh_lead', { p_lead_id: id })))
    for (const { error } of results) if (error) throw error
  }
}

/** Every console lead id this dialer holds. Walks up through the ids rather than
 *  by offset so it cannot miss one, whatever page size the server decides to give. */
export async function heldSourceIds() {
  const ids = new Set()
  let after = -1
  for (;;) {
    const { data, error } = await supa.from('leads').select('source_id')
      .not('source_id', 'is', null).gt('source_id', after)
      .order('source_id', { ascending: true }).limit(1000)
    if (error) throw error
    if (!data?.length) return ids
    for (const r of data) { ids.add(Number(r.source_id)); after = Number(r.source_id) }
  }
}

/** What state each of these leads is in, so a caller can leave alone the ones that
 *  have already been dealt with. */
export async function statesOf(leadIds) {
  const states = new Map()
  for (let i = 0; i < leadIds.length; i += 200) {
    const { data, error } = await supa.from('lead_state').select('lead_id, state')
      .in('lead_id', leadIds.slice(i, i + 200))
    if (error) throw error
    for (const r of data ?? []) states.set(Number(r.lead_id), r.state)
  }
  return states
}

/** Put a lead's number on the suppression list and let refresh_lead() do the rest
 *  (state to suppressed, scheduled callbacks marked missed). */
export async function suppressLead(leadId, reason) {
  const { data: lead, error } = await supa
    .from('leads').select('phone_norm, place_id').eq('id', leadId).single()
  if (error) throw error

  const { error: insErr } = await supa.from('suppression')
    .insert({ phone_norm: lead.phone_norm, place_id: lead.place_id, reason })
  // 23505 is the unique violation: the number is already on the list for this
  // reason, which is where we wanted it. The refresh still has to happen, because
  // this lead may be a twin sharing that number that nothing has looked at yet.
  if (insErr && insErr.code !== '23505') throw insErr

  const { error: rErr } = await supa.rpc('refresh_lead', { p_lead_id: leadId })
  if (rErr) throw rErr

  // Going into suppressed queues a do_not_call write-back, which is right when an
  // agent was told not to call. Here the console is the one that told us, so
  // telling it again is a request it already knows the answer to.
  if (reason === 'dnc') {
    const { error: wbErr } = await supa.from('lead_state')
      .update({ writeback_done: true })
      .eq('lead_id', leadId).eq('writeback_status', 'do_not_call')
    if (wbErr) throw wbErr
  }
}

/** Record a run in sync_runs. The worker's fn may return a plain row count, or
 *  { rows, detail } when it has something the owner should be able to read later —
 *  leads the console no longer has, statuses it refused. */
export async function logRun(kind, fn) {
  const { data: run } = await supa.from('sync_runs')
    .insert({ kind }).select('id').single()
  try {
    const out = await fn()
    const rows = typeof out === 'number' ? out : Number(out?.rows ?? 0)
    const detail = typeof out === 'number' ? null : (out?.detail ?? null)
    await supa.from('sync_runs').update({
      finished_at: new Date().toISOString(), rows, ok: true, detail,
    }).eq('id', run.id)
    return rows
  } catch (e) {
    await supa.from('sync_runs').update({
      finished_at: new Date().toISOString(), ok: false, detail: String(e),
    }).eq('id', run.id)
    throw e
  }
}
