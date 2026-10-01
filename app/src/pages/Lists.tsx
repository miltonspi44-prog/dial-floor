import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { Profile } from '../lib/types'

interface ListRow {
  id: number
  name: string
  list_date: string
  status: string
  kind: 'manual' | 'radar' | 'recycle' | 'referrals'
  agent_id: string | null
  profiles: { name: string } | null
  /** Postgres counts the items for us; see the select in the effect below. */
  total: { count: number }[] | null
  served: { count: number }[] | null
}

/** A counted relation arrives as a one-row array, and as an empty one when there
 *  was nothing to count. */
function tally(c: { count: number }[] | null): number {
  return c?.[0]?.count ?? 0
}

const STATES = ['', 'FL','GA','NC','SC','TN','VA','PA','OH','NY','NJ','MA','MD','CT','AL','KY','NH','ME','RI','DE','TX','WI','IL','IN','MI','AZ','CA','WA']
const INTENTS = ['', 'no_website','social_only','free_subdomain','cheap_builder','broken_site','fresh_listing','review_rich','owner_mobile','never_answers','seasonal_window']

/** The status filter. 'open' is everything still in play, which is what this page
 *  has always shown; the rest let a manager go and find one list in particular. */
const STATUSES: { key: string; label: string }[] = [
  { key: 'open', label: 'still open' },
  { key: 'active', label: 'active' },
  { key: 'done', label: 'closed' },
  { key: 'draft', label: 'draft' },
  { key: 'archived', label: 'archived' },
  { key: 'all', label: 'any status' },
]
const KINDS = ['', 'manual', 'radar', 'recycle', 'referrals']

/** The Status column says the same word the Status filter and the close button do.
 *  The database calls a finished list 'done' and everything a manager reads calls
 *  it "closed", and a column full of "done" under a filter called "closed" reads
 *  like a bug. 'open' and 'any status' are filter-only keys, so no row matches them. */
function statusWord(status: string): string {
  return STATUSES.find((s) => s.key === status)?.label ?? status
}

/** Lists per page. The morning radar deals one list per agent per day and adds
 *  the recycle and referral lists, so a floor of four agents makes about six a
 *  day: unpaged, a manual list that is still being dialed drops off the bottom
 *  of the page inside a week and can no longer be closed or archived. */
const PAGE = 20

export default function Lists() {
  const [agents, setAgents] = useState<Profile[]>([])
  const [agentError, setAgentError] = useState<string | null>(null)
  const [lists, setLists] = useState<ListRow[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(0)
  const [filter, setFilter] = useState({ status: 'open', kind: '' })
  const [fetched, setFetched] = useState<string | null>(null) // the filter and page the rows on screen came from
  const [error, setError] = useState<string | null>(null)
  // A refused close or archive is its own banner. It says nothing about whether the
  // lists loaded, so it must not make the heading claim the count is unknown.
  const [actionError, setActionError] = useState<string | null>(null)
  const [reload, setReload] = useState(0) // bumped to ask the same question again after a change
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [form, setForm] = useState({ name: '', agent: '', state: '', tier: '', intent: '', minScore: '', mobileFirst: false, limit: '200' })

  const query = `${filter.status}|${filter.kind}|${page}`
  // the rows on screen answer an older question than the filters now ask
  const loading = fetched !== query
  const loaded = fetched !== null

  // Asks the same question again, after a build or a change to a row.
  function refresh() { setReload((n) => n + 1) }

  useEffect(() => {
    // A manager picks Status and then Kind inside the same second, so two requests
    // can be in flight at once and the slower one can land last. Everything this
    // request writes is gated on it still being the newest one. A superseded answer
    // that got through would fill the table with rows the dropdowns no longer ask
    // for, and `fetched` would never catch up to `query`, which leaves the card
    // dimmed and both pager buttons dead until the next filter change.
    let live = true
    // Both numbers in the burn-down come back with the lists themselves: Postgres
    // counts the items per list, so this is one request rather than two more for
    // every row on the page.
    let q = supabase
      .from('lists')
      .select('id, name, list_date, status, kind, agent_id, profiles!lists_agent_id_fkey(name),'
        + ' total:list_items(count), served:list_items(count)', { count: 'exact' })
      .not('served.served_at', 'is', null)
    if (filter.status === 'open') q = q.neq('status', 'archived')
    else if (filter.status !== 'all') q = q.eq('status', filter.status)
    if (filter.kind) q = q.eq('kind', filter.kind)
    // The radar builds a whole day of lists in one transaction, so they all share
    // a created_at to the microsecond; the id breaks the tie, or paging through
    // them could show one list twice and skip another.
    q.order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .range(page * PAGE, page * PAGE + PAGE - 1)
      .then(({ data, count, error: e }) => {
        if (!live) return
        setFetched(query)
        if (e) {
          // The heading, the banner and the empty table all have to say the same
          // thing, so the rows from the last good load go with the count: rows on
          // screen under a heading that says the count is unknown is the worse lie.
          setError(`The lists did not load: ${e.message}`)
          setLists([])
          setTotal(0)
          return
        }
        setError(null)
        setLists((data ?? []) as unknown as ListRow[])
        setTotal(count ?? 0)
      })
    return () => { live = false }
  }, [filter.status, filter.kind, page, query, reload])

  useEffect(() => {
    supabase.from('profiles').select('*').eq('active', true).order('name')
      .then(({ data, error: e }) => {
        if (e) { setAgentError(`The agents did not load, so this list cannot be given to one yet: ${e.message}`); return }
        setAgentError(null)
        setAgents((data ?? []) as Profile[])
      })
  }, [])

  function narrow(next: { status?: string; kind?: string }) {
    setFilter({ ...filter, ...next })
    setPage(0) // the page they were on may not exist under the new filter
  }

  async function build(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true); setMsg(null)
    const rules: Record<string, unknown> = {}
    if (form.state) rules.state = form.state
    if (form.tier) rules.tier = form.tier
    if (form.intent) rules.intent = form.intent
    if (form.minScore) rules.min_score = Number(form.minScore)
    if (form.mobileFirst) rules.phone_type = 'mobile'
    const name = form.name || `List ${new Date().toLocaleDateString()}`
    const { data, error: failed } = await supabase.rpc('build_list', {
      p_name: name,
      p_agent: form.agent || null,
      p_rules: rules,
      p_limit: Number(form.limit) || 200,
    })
    setBusy(false)
    if (failed) { setMsg(failed.message); return }
    // Naming it matters: a filter below can hide the list that was just built.
    setMsg(`Built “${name}” with ${(data as { count: number }).count} leads.`)
    if (page === 0) refresh(); else setPage(0)
  }

  async function setStatus(l: ListRow, status: 'done' | 'archived') {
    // A list built from rules that matched nothing has no leads at all, so saying
    // every lead was dialed would be a claim about leads that never existed.
    const on = tally(l.total)
    const left = on - tally(l.served)
    const ask = status === 'done'
      ? `Close “${l.name}”? ` + (left
        ? `${left} lead${left === 1 ? ' has' : 's have'} not been dialed yet, and closing the list stops them being handed out.`
        : on ? 'Every lead on it has been dialed.'
          : 'It has no leads on it.')
      : `Archive “${l.name}”? It drops out of the way, and you only see it again by asking for archived lists. Nothing on it is deleted.`
    if (!window.confirm(ask)) return
    const { error: e } = await supabase.from('lists').update({ status }).eq('id', l.id)
    if (e) { setActionError(`“${l.name}” did not change: ${e.message}`); return }
    setActionError(null)
    refresh()
  }

  const from = total ? page * PAGE + 1 : 0
  const to = page * PAGE + lists.length

  return (
    <div className="page">
      <div className="sectionhead"><h3>Build a list</h3><span className="muted small">rule-based from the eligible pool; locked/resting/suppressed leads never enter</span></div>
      <form className="card" onSubmit={build}>
        <div className="formrow">
          <label>Name<input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="FL roofers Tue" /></label>
          <label>Agent<select value={form.agent} onChange={(e) => setForm({ ...form, agent: e.target.value })}>
            <option value="">— unassigned —</option>
            {agents.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
          </select></label>
          <label>State<select value={form.state} onChange={(e) => setForm({ ...form, state: e.target.value })}>
            {STATES.map((s) => <option key={s} value={s}>{s || 'any'}</option>)}
          </select></label>
          <label>Tier<select value={form.tier} onChange={(e) => setForm({ ...form, tier: e.target.value })}>
            <option value="">any</option><option>A</option><option>B</option><option>C</option>
          </select></label>
          <label>Intent<select value={form.intent} onChange={(e) => setForm({ ...form, intent: e.target.value })}>
            {INTENTS.map((s) => <option key={s} value={s}>{s || 'any'}</option>)}
          </select></label>
          <label>Min score<input style={{ width: 80 }} value={form.minScore} onChange={(e) => setForm({ ...form, minScore: e.target.value })} inputMode="numeric" /></label>
          <label>Size<input style={{ width: 80 }} value={form.limit} onChange={(e) => setForm({ ...form, limit: e.target.value })} inputMode="numeric" /></label>
          <label style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
            <input type="checkbox" checked={form.mobileFirst} onChange={(e) => setForm({ ...form, mobileFirst: e.target.checked })} /> mobile numbers only
          </label>
          <button className="btn primary" disabled={busy}>{busy ? 'Building…' : 'Build list'}</button>
        </div>
        {agentError && <p className="warnline" style={{ marginBottom: 0 }}>{agentError}</p>}
        {msg && <p className="small" style={{ marginBottom: 0 }}>{msg}</p>}
      </form>

      <div className="sectionhead">
        <h3>Lists</h3>
        {/* Held while the rows are on their way, so a second pick cannot stack a
            request behind the first one and leave the table and the dropdowns
            telling the manager two different things. */}
        <div className="formrow">
          <label>Status<select value={filter.status} disabled={loading} onChange={(e) => narrow({ status: e.target.value })}>
            {STATUSES.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
          </select></label>
          <label>Kind<select value={filter.kind} disabled={loading} onChange={(e) => narrow({ kind: e.target.value })}>
            {KINDS.map((k) => <option key={k} value={k}>{k || 'any kind'}</option>)}
          </select></label>
        </div>
        <span className="muted small" style={{ marginLeft: 'auto' }}>
          {!loaded ? 'counting…' : error ? 'how many there are is unknown' : `${total} list${total === 1 ? '' : 's'}`}
        </span>
      </div>
      {error && <div className="card alertcard">{error}</div>}
      {actionError && <div className="card alertcard">{actionError}</div>}
      <div className={`card ${loading && loaded ? 'stale' : ''}`}>
        <div className="tablewrap">
          <table className="data">
            <thead><tr><th>Name</th><th>Date</th><th>Agent</th><th>Burn-down</th><th>Status</th><th /></tr></thead>
            <tbody>
              {lists.map((l) => (
                <tr key={l.id}>
                  <td>{l.name}{l.kind !== 'manual' && <span className="tag" style={{ marginLeft: 8 }}>{l.kind}</span>}</td>
                  <td>{l.list_date}</td>
                  <td>{l.profiles?.name ?? '—'}</td>
                  <td>{tally(l.served)}/{tally(l.total)}</td>
                  <td>{statusWord(l.status)}</td>
                  <td className="rowactions">
                    {l.status === 'active' ? <button className="btn ghost" onClick={() => setStatus(l, 'done')}>close</button>
                      : l.status === 'archived' ? <span className="muted">—</span>
                        : <button className="btn ghost" onClick={() => setStatus(l, 'archived')}>archive</button>}
                  </td>
                </tr>
              ))}
              {!lists.length && (
                <tr>
                  <td colSpan={6} className="muted">
                    {!loaded ? 'Loading the lists…'
                      : error ? 'The lists could not be read, so none can be shown.'
                        : total ? 'Nothing left on this page — go back towards the newer lists.'
                          : filter.status !== 'open' || filter.kind ? 'No lists match that filter.'
                            // "still open" is itself a filter — it hides the archived ones — so
                            // this cannot promise there are no lists at all, only none still open.
                            : 'No lists are still open. Build one above, or pick “archived” to see ones already put away.'}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        {/* The pager stays on screen on any page past the first, even when what is
            left now fits on one page: archiving the only row of page 2 drops the
            total back under a pageful, and without the second test the Newer button
            would vanish with the manager stranded on an empty page. */}
        {(total > PAGE || page > 0) && (
          <div className="actionrow" style={{ marginTop: 10 }}>
            <button className="btn" disabled={page === 0 || loading} onClick={() => setPage(page - 1)}>Newer</button>
            <button className="btn" disabled={to >= total || loading} onClick={() => setPage(page + 1)}>Older</button>
            {/* On a page whose rows have all been archived away, from–to would count
                past the total ("41–40 of 40"), so say only what is still true. */}
            <span className="muted small">{lists.length ? `${from}–${to} of ${total}` : `${total} in all`}</span>
          </div>
        )}
      </div>
    </div>
  )
}
