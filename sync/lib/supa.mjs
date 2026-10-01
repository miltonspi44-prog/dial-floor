import { createClient } from '@supabase/supabase-js'
import { mapLead, keepWhatWeHave, needsRefresh, sameRow, LEAD_COLUMNS } from './map.mjs'

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

/** Upsert a batch; returns { imported, upserted, changed, refreshed, skipped,
 *  unusable, ids }: `imported` is the source ids newly inserted, `changed` how many
 *  rows the console actually had something different to say about, `skipped` the
 *  rows with no console id, `unusable` the rows whose phone number no one can dial
 *  (as { id, phone }, so a caller can name them), `ids` maps the source id of every
 *  row in this batch we hold — written or not — to its lead id, and `markPending`
 *  flags newly inserted leads to be marked `contacted` in the console. */
export async function upsertLeads(rows, { markPending = false } = {}) {
  const all = []
  // Kept rather than counted: a console row nobody can dial is the one case where
  // we quietly do nothing, and whoever called needs to be able to say which rows
  // those were. A do-not-call on one of them has to be acted on anyway.
  const unusable = []
  for (const row of rows) {
    const m = mapLead(row)
    if (m) all.push(m)
    else unusable.push({ id: Number(row.id) || null, phone: String(row.phone ?? '').trim() })
  }
  // A lead with no console id cannot be matched on a later run — onConflict has
  // nothing to match on and Postgres treats every null as its own value — so
  // importing one means a fresh duplicate of it on every import. Better to leave
  // it out and have the caller say so than to quietly fill the floor with twins.
  const mapped = all.filter((m) => m.source_id != null)
  const skipped = all.length - mapped.length
  if (!mapped.length) {
    return { imported: [], upserted: 0, changed: 0, refreshed: 0, skipped, unusable, ids: new Map() }
  }

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

  // What the console actually told us that we did not already know. This is the
  // number worth reporting as a run's rows: the refresh pass writes every lead it
  // recognises every quarter of an hour, so counting writes counts the table.
  const changed = batch.filter((m) => {
    const prev = known.get(m.source_id)
    return !prev || !sameRow(m, prev)
  }).length

  const { data: up, error } = await supa
    .from('leads')
    .upsert(batch, { onConflict: 'source_id' })
    .select('id, source_id')
  if (error) throw error

  // The ids of everything in this batch, taken from what we already held as well as
  // from what came back. A caller acting on one of these leads — putting a
  // do-not-call on the suppression list, say — must not depend on the upsert having
  // returned it, or an answer the console gave us gets quietly dropped.
  const ids = new Map([...known].map(([src, r]) => [src, r.id]))
  for (const r of up ?? []) ids.set(Number(r.source_id), r.id)
  // A lead whose timezone and intent inputs all came back unchanged would get the
  // same answer out of refresh_lead() as last time, and the refresh pass finds
  // almost nothing changed. A brand new lead always needs it: that is the call
  // that gives it a lead_state row and puts it in the queue.
  const due = new Set(batch
    .filter((m) => { const prev = known.get(m.source_id); return !prev || needsRefresh(m, prev) })
    .map((m) => ids.get(m.source_id))
    .filter((id) => id != null))
  // What the console told us is not the only reason a lead can need this. Our own
  // suppression list is the other one: when a twin record of the same business was
  // excluded, this second record is holding an excluded number and does not know it.
  // refresh_lead() is what moves it to suppressed and queues the console write-back
  // for this record, and nothing else ever will — the twin is already out of every
  // queue, so no agent will disposition it, and the console has nothing new to say
  // about it either. Two queries against our own tables, instead of one round trip
  // per lead.
  for (const id of await strandedBySuppression(batch, ids)) due.add(id)
  await refreshLeads([...due])

  return {
    imported: srcIds.filter((id) => !known.has(id)),
    upserted: batch.length,
    changed,
    refreshed: due.size,
    skipped,
    unusable,
    ids,
  }
}

/** The leads in this batch whose number is on the suppression list but whose state
 *  does not say so yet. refresh_lead() does nothing to a lead already suppressed or
 *  handed off, so those are left out rather than asked about every quarter of an hour. */
async function strandedBySuppression(batch, ids) {
  const phones = [...new Set(batch.map((m) => m.phone_norm).filter(Boolean))]
  const onTheList = new Set()
  for (let i = 0; i < phones.length; i += 200) {
    const { data, error } = await supa.from('suppression').select('phone_norm')
      .in('phone_norm', phones.slice(i, i + 200))
    if (error) throw error
    for (const r of data ?? []) onTheList.add(String(r.phone_norm))
  }
  if (!onTheList.size) return []
  const held = batch
    .filter((m) => onTheList.has(String(m.phone_norm)))
    .map((m) => ids.get(m.source_id))
    .filter((id) => id != null)
  if (!held.length) return []
  const states = await statesOf(held)
  return held.filter((id) => !['suppressed', 'handoff'].includes(states.get(id)))
}

/** Our lead id for each of these console lead ids, for the ones we hold. The only
 *  honest way to act on what the console says about a lead: it works whether or not
 *  that lead's row was written this time round, or at all. */
export async function leadIdsBySourceId(sourceIds) {
  const ids = new Map()
  const want = [...new Set(sourceIds.filter((id) => id != null))]
  for (let i = 0; i < want.length; i += 200) {
    const { data, error } = await supa.from('leads').select('id, source_id')
      .in('source_id', want.slice(i, i + 200))
    if (error) throw error
    for (const r of data ?? []) ids.set(Number(r.source_id), r.id)
  }
  return ids
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

  // Going into suppressed queues a write-back, which is right when an agent was the
  // one who learned this. Here the console is the one that told us, so sending it
  // back is asking it a question it already knows the answer to.
  const told = CONSOLE_TOLD_US[reason]
  if (told) {
    const { error: wbErr } = await supa.from('lead_state')
      .update({ writeback_done: true })
      .eq('lead_id', leadId).eq('writeback_status', told)
    if (wbErr) throw wbErr
  }
}

// The write-back refresh_lead() queues for each suppression reason, for the reasons
// the console itself can tell us about.
const CONSOLE_TOLD_US = { dnc: 'do_not_call', wrong_number: 'wrong_number' }

/** Record a run in sync_runs. The worker's fn may return a plain row count, or
 *  { rows, detail } when it has something the owner should be able to read later —
 *  leads the console no longer has, statuses it refused. */
export async function logRun(kind, fn) {
  const { data: run, error: startErr } = await supa.from('sync_runs')
    .insert({ kind }).select('id').single()
  // Without this the next line fails with "cannot read id of null", which tells
  // whoever reads the log nothing about what actually went wrong.
  if (startErr) throw new Error(`could not start a ${kind} run: ${startErr.message}`)
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
