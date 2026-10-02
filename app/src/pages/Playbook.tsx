import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { SCENARIO_SUGGESTIONS } from '../lib/library'
import type { AbResult, AbTest, AbVariant, Battlecard, CardStats, LibraryItem } from '../lib/types'

type Section = 'cards' | 'lab' | 'library'

function pct(n: number, of: number): string {
  return of ? `${Math.round((100 * n) / of)}%` : '—'
}

/** Two-proportion z-test on "kept alive" among conversations: honest about small samples. */
function verdict(a: { k: number; n: number }, b: { k: number; n: number }): string {
  if (a.n < 30 || b.n < 30) return 'not enough conversations yet to call it (about 30 per opener)'
  const p = (a.k + b.k) / (a.n + b.n)
  const se = Math.sqrt(p * (1 - p) * (1 / a.n + 1 / b.n))
  if (!se) return 'no difference so far'
  return Math.abs((a.k / a.n - b.k / b.n) / se) >= 1.96 ? 'likely a real difference (95% confidence)' : 'could still be chance'
}

export default function Playbook() {
  const [section, setSection] = useState<Section>('cards')
  const [toast, setToast] = useState<string | null>(null)

  function say(msg: string) {
    setToast(msg)
    window.setTimeout(() => setToast(null), 2400)
  }

  return (
    <div className="page">
      <div className="rangebar" role="tablist" aria-label="Playbook sections">
        {([['cards', 'Battlecards'], ['lab', 'A/B lab'], ['library', 'Library']] as [Section, string][]).map(([k, label]) => (
          <button key={k} role="tab" aria-selected={section === k} className={`rangebtn ${section === k ? 'active' : ''}`}
            onClick={() => setSection(k)}>{label}</button>
        ))}
      </div>
      {section === 'cards' && <Cards say={say} />}
      {section === 'lab' && <Lab say={say} />}
      {section === 'library' && <Library say={say} />}
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}

// ------------------------------------------------------------------- D1 --
interface CardDraft { id: number | null; objection: string; counters: string; sort: number; active: boolean }

function Cards({ say }: { say: (m: string) => void }) {
  const [cards, setCards] = useState<Battlecard[]>([])
  const [stats, setStats] = useState<Map<number, CardStats>>(new Map())
  const [edit, setEdit] = useState<CardDraft | null>(null)

  const load = useCallback(() => {
    supabase.from('battlecards').select('*').order('sort').order('id')
      .then(({ data }) => setCards((data ?? []) as Battlecard[]))
    supabase.rpc('battlecard_stats', { p_days: 90 })
      .then(({ data }) => setStats(new Map(((data ?? []) as CardStats[]).map((s) => [s.card_id, s]))))
  }, [])
  useEffect(() => { load() }, [load])

  async function save() {
    if (!edit) return
    const counters = edit.counters.split('\n').map((c) => c.trim()).filter(Boolean)
    if (!edit.objection.trim()) { say('Name the objection'); return }
    if (!counters.length) { say('Add at least one counter'); return }
    const row = { objection: edit.objection.trim(), counters, sort: edit.sort, active: edit.active }
    const { error } = edit.id
      ? await supabase.from('battlecards').update(row).eq('id', edit.id)
      : await supabase.from('battlecards').insert(row)
    if (error) { say(error.message); return }
    setEdit(null)
    say('Battlecard saved')
    load()
  }

  async function remove() {
    if (!edit?.id) return
    const used = (stats.get(edit.id)?.calls ?? 0) > 0
    if (used) {
      // item 39: taps are coaching history; the card retires instead of taking them down
      if (!window.confirm(`Archive “${edit.objection}”? Calls stop seeing it; every tap it ever got stays in the stats and the call logs.`)) return
      const { error } = await supabase.from('battlecards').update({ active: false }).eq('id', edit.id)
      if (error) { say(error.message); return }
      setEdit(null)
      say('Battlecard archived — its history stays')
      load()
      return
    }
    if (!window.confirm(`Delete “${edit.objection}”? It has never been tapped, so no history is lost.`)) return
    const { error } = await supabase.from('battlecards').delete().eq('id', edit.id)
    if (error) { say(error.message); return }
    setEdit(null)
    say('Battlecard deleted')
    load()
  }

  const editing = edit?.id ? stats.get(edit.id) : undefined
  return (
    <>
      <div className="sectionhead">
        <h3>Battlecards</h3>
        <span className="muted small">last 90 days · a call is kept alive when it ends in a callback, an email or a handoff</span>
        <button className="btn" style={{ marginLeft: 'auto' }}
          onClick={() => setEdit({ id: null, objection: '', counters: '', sort: (cards.at(-1)?.sort ?? 0) + 10, active: true })}>
          New battlecard
        </button>
      </div>
      <div className="card">
        <div className="tablewrap">
          <table className="data">
            <thead><tr><th>Objection</th><th className="num">Heard in</th><th className="num">Kept alive</th><th className="num">Handoffs</th><th>Best counter so far</th><th /></tr></thead>
            <tbody>
              {cards.map((c) => {
                const s = stats.get(c.id)
                const best = s?.counters.find((k) => k.uses >= 5)
                return (
                  <tr key={c.id} className={c.active ? '' : 'inactive'}>
                    <td><b>{c.objection}</b>{!c.active && <span className="tag off" style={{ marginLeft: 8 }}>off</span>}</td>
                    <td className="num">{s?.calls ?? 0} calls</td>
                    <td className="num">{s?.calls ? pct(s.kept, s.calls) : '—'}</td>
                    <td className="num">{s?.won ?? 0}</td>
                    <td className="small">{best ? <>“{best.text}” <span className="muted">kept {best.kept} of {best.uses}</span></> : <span className="muted">needs 5 uses of a counter</span>}</td>
                    <td className="rowactions">
                      <button className="btn ghost" onClick={() => setEdit({ id: c.id, objection: c.objection, counters: (c.counters as string[]).join('\n'), sort: c.sort, active: c.active })}>edit</button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </div>

      {edit && (
        <div className="card tpleditor">
          <div className="tplgrid">
            <div className="tplform">
              <label>Objection<input value={edit.objection} onChange={(e) => setEdit({ ...edit, objection: e.target.value })} autoFocus /></label>
              <label>Counters, one per line
                <textarea rows={7} value={edit.counters} onChange={(e) => setEdit({ ...edit, counters: e.target.value })} />
              </label>
              <label style={{ maxWidth: 140 }}>Order<input type="number" value={edit.sort} onChange={(e) => setEdit({ ...edit, sort: Number(e.target.value) })} /></label>
              <label className="check">
                <input type="checkbox" checked={edit.active} onChange={(e) => setEdit({ ...edit, active: e.target.checked })} />
                Show it on the Dial page
              </label>
              <div className="actionrow">
                <button className="btn primary" onClick={save}>Save battlecard</button>
                <button className="btn ghost" onClick={() => setEdit(null)}>Cancel</button>
                {edit.id && !editing?.calls && <button className="btn danger" style={{ marginLeft: 'auto' }} onClick={remove}>Delete</button>}
              </div>
            </div>
            <div>
              <div className="kpilabel">How each counter has done</div>
              {editing?.counters.length ? (
                <ul className="phlist">
                  {editing.counters.map((k) => (
                    <li key={k.text}>“{k.text}”: used {k.uses}×, kept {k.kept} alive{k.won ? `, ${k.won} handoff${k.won === 1 ? '' : 's'}` : ''}</li>
                  ))}
                </ul>
              ) : <p className="muted small">No counter taps recorded yet.</p>}
              <p className="muted small">
                A reworded counter starts a fresh record: the ranking follows the words agents actually tap. Switch a card
                off rather than deleting it once it has history.
              </p>
            </div>
          </div>
        </div>
      )}
    </>
  )
}

// ------------------------------------------------------------------- D6 --
function Lab({ say }: { say: (m: string) => void }) {
  const [on, setOn] = useState<boolean | null>(null)
  const [tests, setTests] = useState<AbTest[]>([])
  const [results, setResults] = useState<Record<number, AbResult[]>>({})
  const [draft, setDraft] = useState<{ name: string; variants: AbVariant[] } | null>(null)

  const load = useCallback(() => {
    supabase.from('app_settings').select('value').eq('key', 'ab_lab_enabled').maybeSingle()
      .then(({ data }) => setOn(data?.value === true || data?.value === 'true'))
    supabase.from('ab_tests').select('*').order('created_at', { ascending: false })
      .then(({ data }) => {
        const list = (data ?? []) as AbTest[]
        setTests(list)
        for (const t of list.filter((x) => x.started_at)) {
          supabase.rpc('ab_results', { p_test_id: t.id })
            .then(({ data: r }) => setResults((prev) => ({ ...prev, [t.id]: (r ?? []) as AbResult[] })))
        }
      })
  }, [])
  useEffect(() => { load() }, [load])

  async function toggle() {
    const next = !on
    if (next && !window.confirm('Switch the A/B lab on? Agents will see the running test’s opener on the Dial page.')) return
    const { error } = await supabase.from('app_settings').update({ value: next, updated_at: new Date().toISOString() }).eq('key', 'ab_lab_enabled')
    if (error) { say(error.message); return }
    say(next ? 'A/B lab on' : 'A/B lab off: agents see no test openers')
    load()
  }

  async function setStatus(t: AbTest, status: 'running' | 'stopped') {
    const { error } = await supabase.rpc('ab_set_status', { p_test_id: t.id, p_status: status })
    if (error) { say(error.message); return }
    say(status === 'running' ? `“${t.name}” is running` : `“${t.name}” stopped`)
    load()
  }

  async function saveDraft() {
    if (!draft) return
    const variants = draft.variants.filter((v) => v.text.trim()).map((v, i) => ({ key: 'ABCD'[i], text: v.text.trim() }))
    if (!draft.name.trim()) { say('Name the test'); return }
    if (variants.length < 2) { say('Write at least two openers'); return }
    const { error } = await supabase.from('ab_tests').insert({ name: draft.name.trim(), variants })
    if (error) { say(error.message); return }
    setDraft(null)
    say('Test saved: start it when you are ready')
    load()
  }

  return (
    <>
      <div className="sectionhead"><h3>A/B lab</h3><span className="muted small">opener variants, one test at a time</span></div>
      <div className={`card ${on ? '' : 'labcard-off'}`}>
        <div className="actionrow" style={{ margin: 0 }}>
          <span className={`tag ${on ? 'hot' : 'off'}`}>{on == null ? '…' : on ? 'on' : 'off'}</span>
          <span className="small" style={{ flex: 1 }}>
            {on
              ? 'Agents see the running test’s opener on the Dial page, and every dial records which one they saw.'
              : 'Off by default. While it’s off, agents see no test openers and nothing is recorded.'}
          </span>
          <button className={`btn ${on ? '' : 'primary'}`} onClick={toggle} disabled={on == null}>{on ? 'Switch off' : 'Switch on'}</button>
        </div>
      </div>

      <div className="sectionhead">
        <h3>Tests</h3>
        <span className="muted small">each lead always gets the same opener, so a redial doesn’t mix versions</span>
        <button className="btn" style={{ marginLeft: 'auto' }}
          onClick={() => setDraft({ name: '', variants: [{ key: 'A', text: '' }, { key: 'B', text: '' }] })}>New test</button>
      </div>
      {draft && (
        <div className="card tpleditor" style={{ marginBottom: 12 }}>
          <div className="tplform">
            <label>Name<input value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} autoFocus placeholder="e.g. Reviews opener vs. missed-calls opener" /></label>
            {draft.variants.map((v, i) => (
              <label key={i}>Opener {'ABCD'[i]}
                <textarea rows={2} value={v.text}
                  onChange={(e) => setDraft({ ...draft, variants: draft.variants.map((x, j) => (j === i ? { ...x, text: e.target.value } : x)) })} />
              </label>
            ))}
            <div className="actionrow">
              <button className="btn primary" onClick={saveDraft}>Save test</button>
              {draft.variants.length < 4 && (
                <button className="btn ghost" onClick={() => setDraft({ ...draft, variants: [...draft.variants, { key: 'ABCD'[draft.variants.length], text: '' }] })}>add an opener</button>
              )}
              <button className="btn ghost" onClick={() => setDraft(null)}>Cancel</button>
            </div>
          </div>
        </div>
      )}
      {tests.map((t) => {
        const rs = results[t.id] ?? []
        const byKey = new Map(rs.map((r) => [r.variant, r]))
        const rows = t.variants.map((v) => ({ v, r: byKey.get(v.key) }))
        const ranked = rows.filter((x) => x.r?.conversations).sort((a, b) => (b.r!.kept / b.r!.conversations) - (a.r!.kept / a.r!.conversations))
        return (
          <div className="card" key={t.id} style={{ marginBottom: 12 }}>
            <div className="actionrow" style={{ marginTop: 0 }}>
              <b>{t.name}</b>
              <span className={`tag ${t.status === 'running' ? 'hot' : 'off'}`}>{t.status}</span>
              {t.started_at && <span className="muted small">started {new Date(t.started_at).toLocaleDateString()}</span>}
              <span style={{ flex: 1 }} />
              {t.status === 'running'
                ? <button className="btn" onClick={() => setStatus(t, 'stopped')}>Stop</button>
                : <button className="btn" onClick={() => setStatus(t, 'running')}>{t.started_at ? 'Resume' : 'Start'}</button>}
            </div>
            <div className="tablewrap">
              <table className="data">
                <thead><tr><th>Opener</th><th className="num">Dials</th><th className="num">Picked up</th><th className="num">Conversations</th><th className="num">Past 30 s</th><th className="num">Kept alive</th><th className="num">Handoffs</th></tr></thead>
                <tbody>
                  {rows.map(({ v, r }) => (
                    <tr key={v.key}>
                      <td><b>{v.key}</b> <span className="small">{v.text}</span></td>
                      <td className="num">{r?.dials ?? 0}</td>
                      <td className="num">{r ? pct(r.picked_up, r.dials) : '—'}</td>
                      <td className="num">{r?.conversations ?? 0}</td>
                      <td className="num">{r?.conversations ? pct(r.survived_30s, r.conversations) : '—'}</td>
                      <td className="num">{r?.conversations ? pct(r.kept, r.conversations) : '—'}</td>
                      <td className="num">{r?.won ?? 0}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {ranked.length >= 2 && (
              <p className="small" style={{ marginBottom: 0 }}>
                <b>{ranked[0].v.key}</b> keeps {pct(ranked[0].r!.kept, ranked[0].r!.conversations)} of conversations alive vs {pct(ranked[1].r!.kept, ranked[1].r!.conversations)} for <b>{ranked[1].v.key}</b>:{' '}
                {verdict({ k: ranked[0].r!.kept, n: ranked[0].r!.conversations }, { k: ranked[1].r!.kept, n: ranked[1].r!.conversations })}.
              </p>
            )}
          </div>
        )
      })}
      {!tests.length && !draft && <div className="card muted small">No tests yet.</div>}
    </>
  )
}

// ------------------------------------------------------------------- D5 --
interface LibDraft { id: number | null; title: string; scenario: string; body: string; pinned: boolean }

function Library({ say }: { say: (m: string) => void }) {
  const [items, setItems] = useState<LibraryItem[]>([])
  const [filter, setFilter] = useState<string>('')
  const [edit, setEdit] = useState<LibDraft | null>(null)

  const load = useCallback(() => {
    supabase.from('library_items').select('*').order('pinned', { ascending: false }).order('updated_at', { ascending: false })
      .then(({ data }) => setItems((data ?? []) as LibraryItem[]))
  }, [])
  useEffect(() => { load() }, [load])

  async function save() {
    if (!edit) return
    if (!edit.title.trim()) { say('Give it a title'); return }
    const row = { title: edit.title.trim(), scenario: edit.scenario.trim() || 'Other', body: edit.body, pinned: edit.pinned, updated_at: new Date().toISOString() }
    const { data: auth } = await supabase.auth.getSession()
    const { error } = edit.id
      ? await supabase.from('library_items').update(row).eq('id', edit.id)
      : await supabase.from('library_items').insert({ ...row, created_by: auth.session?.user.id ?? null })
    if (error) { say(error.message); return }
    setEdit(null)
    say('Saved')
    load()
  }

  async function remove(item: LibraryItem) {
    if (!window.confirm(`Delete “${item.title}” from the library?`)) return
    const { error } = await supabase.from('library_items').delete().eq('id', item.id)
    if (error) { say(error.message); return }
    say('Deleted')
    load()
  }

  const scenarios = [...new Set(items.map((i) => i.scenario))].sort()
  const shown = filter ? items.filter((i) => i.scenario === filter) : items
  return (
    <>
      <div className="sectionhead">
        <h3>Library</h3>
        <span className="muted small">managers only · talk tracks and the best calls, saved from Floor and Handoffs</span>
        <button className="btn" style={{ marginLeft: 'auto' }} onClick={() => setEdit({ id: null, title: '', scenario: '', body: '', pinned: false })}>New entry</button>
      </div>
      {scenarios.length > 1 && (
        <div className="rangebar">
          <button className={`rangebtn ${filter === '' ? 'active' : ''}`} onClick={() => setFilter('')}>All</button>
          {scenarios.map((sc) => <button key={sc} className={`rangebtn ${filter === sc ? 'active' : ''}`} onClick={() => setFilter(sc)}>{sc}</button>)}
        </div>
      )}
      {edit && (
        <div className="card tpleditor" style={{ marginBottom: 12 }}>
          <div className="tplform">
            <label>Title<input value={edit.title} onChange={(e) => setEdit({ ...edit, title: e.target.value })} autoFocus /></label>
            <label>Scenario<input list="scenarios" value={edit.scenario} onChange={(e) => setEdit({ ...edit, scenario: e.target.value })} /></label>
            <datalist id="scenarios">{SCENARIO_SUGGESTIONS.map((sc) => <option key={sc} value={sc} />)}</datalist>
            <label>Talk track or what happened<textarea rows={9} value={edit.body} onChange={(e) => setEdit({ ...edit, body: e.target.value })} /></label>
            <label className="check"><input type="checkbox" checked={edit.pinned} onChange={(e) => setEdit({ ...edit, pinned: e.target.checked })} /> Pin to the top</label>
            <div className="actionrow">
              <button className="btn primary" onClick={save}>Save</button>
              <button className="btn ghost" onClick={() => setEdit(null)}>Cancel</button>
            </div>
          </div>
        </div>
      )}
      <div className="libgrid">
        {shown.map((i) => (
          <div className="card libitem" key={i.id}>
            <div className="actionrow" style={{ margin: 0 }}>
              {i.pinned && <span title="pinned">★</span>}
              <b style={{ flex: 1 }}>{i.title}</b>
              <span className="tag">{i.scenario}</span>
            </div>
            {(i.lead_name || i.agent_name) && (
              <div className="muted small">{[i.agent_name && `${i.agent_name}’s call`, i.lead_name].filter(Boolean).join(' with ')} · {new Date(i.created_at).toLocaleDateString()}</div>
            )}
            <div className="libbody">{i.body}</div>
            <div className="actionrow" style={{ margin: '6px 0 0' }}>
              <button className="btn ghost" onClick={() => setEdit({ id: i.id, title: i.title, scenario: i.scenario, body: i.body, pinned: i.pinned })}>edit</button>
              <button className="btn ghost" onClick={() => remove(i)}>delete</button>
            </div>
          </div>
        ))}
      </div>
      {!items.length && !edit && <div className="card muted small">Empty so far. Save a call from the Floor’s recent calls or the Handoffs ledger, or write a talk track here.</div>}
    </>
  )
}
