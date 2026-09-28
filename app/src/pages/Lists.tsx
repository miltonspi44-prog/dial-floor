import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { Profile } from '../lib/types'

interface ListRow {
  id: number
  name: string
  list_date: string
  status: string
  agent_id: string | null
  profiles: { name: string } | null
  total?: number
  served?: number
}

const STATES = ['', 'FL','GA','NC','SC','TN','VA','PA','OH','NY','NJ','MA','MD','CT','AL','KY','NH','ME','RI','DE','TX','WI','IL','IN','MI','AZ','CA','WA']
const INTENTS = ['', 'no_website','social_only','free_subdomain','cheap_builder','broken_site','fresh_listing','review_rich','owner_mobile','never_answers']

export default function Lists() {
  const [agents, setAgents] = useState<Profile[]>([])
  const [lists, setLists] = useState<ListRow[]>([])
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [form, setForm] = useState({ name: '', agent: '', state: '', tier: '', intent: '', minScore: '', mobileFirst: false, limit: '200' })

  const refresh = useCallback(async () => {
    const { data: ls } = await supabase
      .from('lists')
      .select('id, name, list_date, status, agent_id, profiles!lists_agent_id_fkey(name)')
      .neq('status', 'archived')
      .order('created_at', { ascending: false })
      .limit(30)
    const rows = ((ls ?? []) as unknown as ListRow[])
    for (const r of rows) {
      const { count: total } = await supabase.from('list_items').select('id', { count: 'exact', head: true }).eq('list_id', r.id)
      const { count: served } = await supabase.from('list_items').select('id', { count: 'exact', head: true }).eq('list_id', r.id).not('served_at', 'is', null)
      r.total = total ?? 0
      r.served = served ?? 0
    }
    setLists(rows)
  }, [])

  useEffect(() => {
    supabase.from('profiles').select('*').eq('active', true).order('name')
      .then(({ data }) => setAgents((data ?? []) as Profile[]))
    refresh()
  }, [refresh])

  async function build(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true); setMsg(null)
    const rules: Record<string, unknown> = {}
    if (form.state) rules.state = form.state
    if (form.tier) rules.tier = form.tier
    if (form.intent) rules.intent = form.intent
    if (form.minScore) rules.min_score = Number(form.minScore)
    if (form.mobileFirst) rules.phone_type = 'mobile'
    const { data, error } = await supabase.rpc('build_list', {
      p_name: form.name || `List ${new Date().toLocaleDateString()}`,
      p_agent: form.agent || null,
      p_rules: rules,
      p_limit: Number(form.limit) || 200,
    })
    setBusy(false)
    if (error) { setMsg(error.message); return }
    setMsg(`Built with ${(data as { count: number }).count} leads.`)
    refresh()
  }

  async function setStatus(id: number, status: string) {
    await supabase.from('lists').update({ status }).eq('id', id)
    refresh()
  }

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
        {msg && <p className="small" style={{ marginBottom: 0 }}>{msg}</p>}
      </form>

      <div className="sectionhead"><h3>Lists</h3></div>
      <div className="card">
        <table className="data">
          <thead><tr><th>Name</th><th>Date</th><th>Agent</th><th>Burn-down</th><th>Status</th><th /></tr></thead>
          <tbody>
            {lists.map((l) => (
              <tr key={l.id}>
                <td>{l.name}</td>
                <td>{l.list_date}</td>
                <td>{l.profiles?.name ?? '—'}</td>
                <td>{l.served}/{l.total}</td>
                <td>{l.status}</td>
                <td>
                  {l.status === 'active'
                    ? <button className="btn ghost" onClick={() => setStatus(l.id, 'done')}>close</button>
                    : <button className="btn ghost" onClick={() => setStatus(l.id, 'archived')}>archive</button>}
                </td>
              </tr>
            ))}
            {!lists.length && <tr><td colSpan={6} className="muted">No lists yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  )
}
