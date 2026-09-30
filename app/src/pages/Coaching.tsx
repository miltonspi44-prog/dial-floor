import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { dispositionLabel } from '../lib/types'
import type { Digest, Insights, Profile } from '../lib/types'

function pct(v: number | null | undefined): string {
  return v == null ? '—' : `${Math.round(v * 100)}%`
}
function share(n: number, of: number): string {
  return of ? `${Math.round((100 * n) / of)}%` : '—'
}
function hourLabel(h: number): string {
  return `${h % 12 || 12}${h < 12 ? 'am' : 'pm'}`
}

/** What each digest metric means, and the one concrete move when it is the thing to work on. */
const METRIC: Record<string, { label: string; fmt: (v: number) => string; tip: string }> = {
  pace: { label: 'Dials per day', fmt: (v) => String(Math.round(v)), tip: 'Keep wrap-up to one key: the next lead loads itself.' },
  conversation_rate: { label: 'Dials that reach a person', fmt: pct, tip: 'Dial in your best hour (below): that is when owners pick up for you.' },
  kept_rate: { label: 'Conversations kept alive', fmt: pct, tip: 'Before they hang up, ask for a next step: a callback time or an email address.' },
  handoff_rate: { label: 'Conversations that hand off', fmt: pct, tip: 'Ask for the chance plainly: “Can we build your homepage and show you Friday?”' },
  notes: { label: 'Conversations with a note', fmt: pct, tip: 'One line on every conversation: callbacks and the next agent depend on it.' },
  battlecards: { label: 'Objections tapped', fmt: pct, tip: 'Tap the objection you hear, then the counter you used: that is how the best counters rise to the top.' },
  callbacks_kept: { label: 'Callbacks kept', fmt: pct, tip: 'Callbacks come first in your queue: take them on time.' },
}

export default function Coaching({ profile }: { profile: Profile | null }) {
  const isManager = profile?.role === 'manager'
  const [people, setPeople] = useState<Profile[]>([])
  const [who, setWho] = useState<string | null>(profile?.id ?? null)
  const [days, setDays] = useState(1)

  useEffect(() => {
    if (!isManager) return
    supabase.from('profiles').select('id, name, role, active').eq('active', true).order('name')
      .then(({ data }) => {
        const list = (data ?? []) as Profile[]
        setPeople(list)
        const firstAgent = list.find((p) => p.role === 'agent')
        if (firstAgent) setWho(firstAgent.id)
      })
  }, [isManager])

  return (
    <div className="page">
      <div className="actionrow" style={{ marginTop: 0 }}>
        {isManager && (
          <label className="small muted">Agent{' '}
            <select value={who ?? ''} onChange={(e) => setWho(e.target.value)}>
              {people.map((p) => <option key={p.id} value={p.id}>{p.name}{p.role === 'manager' ? ' (manager)' : ''}</option>)}
            </select>
          </label>
        )}
        <div className="rangebar" role="group" aria-label="Period" style={{ margin: 0 }}>
          {[[1, 'Today'], [7, 'Last 7 days']].map(([d, label]) => (
            <button key={d} className={`rangebtn ${days === d ? 'active' : ''}`} onClick={() => setDays(d as number)}>{label}</button>
          ))}
        </div>
      </div>
      {who && <DigestView agent={who} days={days} />}
      {isManager && <InsightsView />}
    </div>
  )
}

function DigestView({ agent, days }: { agent: string; days: number }) {
  const [d, setD] = useState<Digest | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [key, setKey] = useState('')

  useEffect(() => {
    let live = true
    supabase.rpc('digest', { p_agent: agent, p_days: days }).then(({ data, error: e }) => {
      if (!live) return
      if (e) { setError(e.message); setD(null) } else { setError(null); setD(data as Digest) }
      setKey(`${agent}:${days}`)
    })
    return () => { live = false }
  }, [agent, days])

  if (error) return <div className="card alertcard">{error}</div>
  if (!d) return <div className="emptystate">Loading the digest…</div>
  const stale = key !== `${agent}:${days}`
  const m = new Map(d.metrics.map((x) => [x.key, x]))
  const ref = (k: string) => {
    const x = m.get(k)
    if (!x || x.reference == null) return ''
    const target = k === 'pace' && d.targets.dials
    return `${METRIC[k].fmt(x.reference)} ${target ? 'target' : 'floor'}`
  }
  const line = (k: string) => {
    const x = m.get(k)
    return x?.value == null ? METRIC[k]?.label : `${METRIC[k].label}: ${METRIC[k].fmt(x.value)} vs ${ref(k)}`
  }
  const perDay = (n: number) => Math.round(n / Math.max(1, d.me.days_active ?? 1))

  return (
    <div className={stale ? 'stale' : ''}>
      <div className="sectionhead"><h3>{d.agent?.name ?? 'Digest'} · {d.days === 1 ? 'today' : `last ${d.days} days`}</h3></div>
      <div className="kpirow">
        <div className="card kpi"><div className="kpilabel">Dials</div><div className="kpivalue">{d.me.dials}</div>
          <div className="kpisub">{perDay(d.me.dials)} a day{d.targets.dials ? ` · target ${d.targets.dials}` : ''}</div></div>
        <div className="card kpi"><div className="kpilabel">Conversations</div><div className="kpivalue">{d.me.conversations}</div>
          <div className="kpisub">{share(d.me.conversations, d.me.dials)} of dials · floor {share(d.floor.conversations, d.floor.dials)}</div></div>
        <div className="card kpi"><div className="kpilabel">Kept alive</div><div className="kpivalue">{d.me.kept}</div>
          <div className="kpisub">{share(d.me.kept, d.me.conversations)} of conversations · floor {share(d.floor.kept, d.floor.conversations)}</div></div>
        <div className="card kpi"><div className="kpilabel">Handoffs</div><div className="kpivalue">{d.me.won}</div>
          <div className="kpisub">{d.targets.handoffs ? `target ${d.targets.handoffs} a day` : 'chance given / sale closed'}</div></div>
      </div>

      <div className="digestgrid">
        <div className="card">
          <h4 className="cardhead">Going well</h4>
          {d.strengths.length ? d.strengths.map((k) => <div key={k} className="digestline good">{line(k)}</div>)
            : <p className="muted small">{d.me.dials < 20 ? 'Not enough calls yet: the digest fills in after about 30 dials.' : 'Nothing stands out above the floor yet.'}</p>}
        </div>
        <div className="card">
          <h4 className="cardhead">Work on</h4>
          {d.fix ? (
            <>
              <div className="digestline fix">{line(d.fix)}</div>
              <p className="small" style={{ marginBottom: 0 }}>{METRIC[d.fix]?.tip}</p>
            </>
          ) : <p className="muted small">{d.me.dials < 20 ? 'Not enough calls yet.' : 'Nothing is behind the floor or the targets.'}</p>}
          {d.best_hour && (
            <p className="small muted" style={{ marginBottom: 0 }}>
              Best hour: {hourLabel(d.best_hour.hour)} their time. {d.best_hour.rate}% of {d.best_hour.dials} dials reached a person (last 30 days).
            </p>
          )}
        </div>
      </div>

      <div className="sectionhead"><h3>Objections heard</h3><span className="muted small">kept alive = the call ended in a callback, an email or a handoff</span></div>
      <div className="card">
        {d.objections.length ? (
          <div className="tablewrap">
            <table className="data">
              <thead><tr><th>Objection</th><th className="num">Heard</th><th className="num">Kept alive</th><th className="num">Floor</th><th>Counter to try</th></tr></thead>
              <tbody>
                {d.objections.map((o) => (
                  <tr key={o.objection}>
                    <td>{o.objection}</td>
                    <td className="num">{o.heard}</td>
                    <td className="num">{share(o.kept, o.heard)}</td>
                    <td className="num">{pct(o.floor_rate)}</td>
                    <td className="small">{o.try ? <>“{o.try.text}” <span className="muted">kept {o.try.kept} of {o.try.uses} on the floor</span></> : <span className="muted">no counter has 5 uses yet</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <span className="muted small">No objections tapped in this period.</span>}
      </div>
    </div>
  )
}

function InsightsView() {
  const [days, setDays] = useState(30)
  const [f, setF] = useState<Insights | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let live = true
    supabase.rpc('insights', { p_days: days }).then(({ data, error: e }) => {
      if (!live) return
      if (e) { setError(e.message); return }
      setError(null)
      setF(data as Insights)
    })
    return () => { live = false }
  }, [days])

  const maxTalk = Math.max(1, ...(f?.talk ?? []).map((t) => t.calls))
  const maxOut = Math.max(1, ...(f?.outcomes ?? []).map((o) => o.calls))
  return (
    <>
      <div className="sectionhead" style={{ marginTop: 34 }}>
        <h3>Floor insights</h3>
        <span className="muted small">conversations past the gatekeeper only: gatekeeper calls are left out</span>
        <div className="rangebar" style={{ margin: '0 0 0 auto' }}>
          {[7, 30, 90].map((d) => (
            <button key={d} className={`rangebtn ${days === d ? 'active' : ''}`} onClick={() => setDays(d)}>{d} days</button>
          ))}
        </div>
      </div>
      {error && <div className="card alertcard">{error}</div>}
      {f && (
        <>
          <div className="card">
            <p className="small" style={{ marginTop: 0 }}>
              <b>{f.conversations}</b> conversations, <b>{share(f.kept, f.conversations)}</b> kept alive.
              {' '}With no objection tapped: {f.no_objection.calls} calls, {share(f.no_objection.kept, f.no_objection.calls)} kept alive.
            </p>
            {f.objections.length ? (
              <div className="tablewrap">
                <table className="data">
                  <thead><tr><th>Objection</th><th className="num">Heard in</th><th className="num">Of conversations</th><th className="num">Kept alive</th><th className="num">Handoffs</th><th>Best counter</th></tr></thead>
                  <tbody>
                    {f.objections.map((o) => (
                      <tr key={o.objection}>
                        <td>{o.objection}</td>
                        <td className="num">{o.heard}</td>
                        <td className="num">{share(o.heard, f.conversations)}</td>
                        <td className="num">{share(o.kept, o.heard)}</td>
                        <td className="num">{o.won}</td>
                        <td className="small">{o.best_counter ? <>“{o.best_counter.text}” <span className="muted">kept {o.best_counter.kept} of {o.best_counter.uses}</span></> : <span className="muted">—</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : <span className="muted small">No objections tapped yet.</span>}
          </div>

          <div className="digestgrid">
            <div className="card">
              <h4 className="cardhead">Where calls end, by talk time</h4>
              <table className="data">
                <thead><tr><th>Talk time</th><th className="barcol">Conversations</th><th className="num">Kept alive</th></tr></thead>
                <tbody>
                  {f.talk.map((t) => (
                    <tr key={t.bucket}>
                      <td className="small">{t.bucket}</td>
                      <td className="barcol"><span className="barcell"><span className="minibar"><i style={{ width: `${(100 * t.calls) / maxTalk}%` }} /></span><span className="n">{t.calls}</span></span></td>
                      <td className="num">{share(t.kept, t.calls)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="card">
              <h4 className="cardhead">How conversations end</h4>
              <table className="data">
                <tbody>
                  {f.outcomes.map((o) => (
                    <tr key={o.disposition}>
                      <td className="small">{dispositionLabel(o.disposition)}</td>
                      <td className="barcol"><span className="barcell"><span className="minibar"><i style={{ width: `${(100 * o.calls) / maxOut}%` }} /></span><span className="n">{o.calls}</span></span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div className="card">
            <h4 className="cardhead">Words in notes</h4>
            <div className="digestgrid" style={{ marginTop: 0 }}>
              <div>
                <div className="kpilabel">Calls kept alive</div>
                <div>{f.words.kept.length ? f.words.kept.map((w) => <span key={w.word} className="tag hot">{w.word} · {w.notes}</span>) : <span className="muted small">not enough notes yet</span>}</div>
              </div>
              <div>
                <div className="kpilabel">Calls lost</div>
                <div>{f.words.lost.length ? f.words.lost.map((w) => <span key={w.word} className="tag off">{w.word} · {w.notes}</span>) : <span className="muted small">not enough notes yet</span>}</div>
              </div>
            </div>
            <p className="muted small" style={{ marginBottom: 0 }}>Counted once per note, words of four letters or more; shown once in two notes or more.</p>
          </div>
        </>
      )}
    </>
  )
}
