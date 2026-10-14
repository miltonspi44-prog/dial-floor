import { useCallback, useEffect, useState } from 'react'
import { supabase, fmtPhone, loadTargets } from '../lib/supabase'
import { breakLabel, dispositionLabel, tapsByObjection } from '../lib/types'
import { callBody, saveToLibrary, scenarioFor } from '../lib/library'
import type { FloorBoard, FloorRow, PaceRow, RecentCall, Targets } from '../lib/types'
import AlertsPanel from '../components/AlertsPanel'
import LeaderboardCard from '../components/LeaderboardCard'
import LoadError from '../components/LoadError'

type View = 'live' | 'board' | 'calls'

/** "4m", "1h 5m" since a timestamp. */
function since(ts: string | null): string {
  if (!ts) return ''
  const m = Math.max(0, Math.round((Date.now() - Date.parse(ts)) / 60000))
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`
}

function statusLine(r: FloorRow, p: PaceRow | undefined): string {
  if (r.status === 'offline') return r.last_seen ? `offline · seen ${since(r.last_seen)} ago` : 'offline'
  // a pause shows its reason (A4)
  if (r.status === 'break' && p?.on_break) {
    return `on ${breakLabel(p.break_reason).toLowerCase()}${p.break_note ? ` (${p.break_note})` : ''} · ${since(p.break_since)}`
  }
  return r.since ? `${r.status} · ${since(r.since)}` : r.status
}

/** Talk time from Zoom, once its event has matched the call. */
function talkTime(c: RecentCall): string {
  if (!c.matched) return 'waiting for Zoom'
  const s = c.duration_seconds ?? 0
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

/** The promise's time on the lead's own clock (item 45). */
function leadLocal(iso: string, tz: string | null): string {
  try {
    return new Intl.DateTimeFormat('en-US', {
      weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
      timeZone: tz ?? 'America/New_York', timeZoneName: 'short',
    }).format(new Date(iso))
  } catch { return new Date(iso).toLocaleString() }
}

function Count({ value, target, label }: { value: number; target: number | null; label: string }) {
  return <span><b>{value}</b>{label}{target ? <span className="of"> / {target}</span> : null}</span>
}

export default function Floor({ isManager, me }: { isManager: boolean; me: string }) {
  const [view, setView] = useState<View>('live')
  const [board, setBoard] = useState<FloorBoard | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [calls, setCalls] = useState<RecentCall[]>([])
  const [callsErr, setCallsErr] = useState<string | null>(null)
  const [targets, setTargets] = useState<Targets>({ dials: null, conversations: null, handoffs: null })
  const [aiOn, setAiOn] = useState(false)
  const [toast, setToast] = useState<string | null>(null)
  const [paceMap, setPaceMap] = useState<Map<string, PaceRow>>(new Map())

  // Item 42: the whole floor arrives in ONE call; the tiles between calls are
  // patched straight from realtime instead of refetching anything.
  const refresh = useCallback(() => {
    supabase.rpc('floor_board').then(({ data, error }) => {
      if (error) { setErr(error.message); return }
      setErr(null)
      const b = data as FloorBoard
      setPaceMap(new Map((b.pace ?? []).map((p) => [p.agent_id, p])))
      setBoard(b)
    })
  }, [])

  const refreshCalls = useCallback(() => {
    supabase.from('attempts')
      .select('id, agent_id, connected, clicked_at, duration_seconds, call_result, disposition, note, matched, ai_summary, leads(name), profiles!attempts_agent_id_fkey(name), card_taps(counter, battlecards(objection))')
      .not('disposition', 'eq', 'not_placed')
      .order('clicked_at', { ascending: false }).limit(25)
      .then(({ data, error }) => {
        if (error) { setCallsErr(error.message); return }
        setCallsErr(null)
        setCalls((data ?? []) as unknown as RecentCall[])
      })
  }, [])

  useEffect(() => {
    loadTargets().then(setTargets)
    supabase.from('app_settings').select('value').eq('key', 'ai_summaries_enabled')
      .then(({ data }) => setAiOn(data?.[0]?.value === true || data?.[0]?.value === 'true'))
  }, [])

  useEffect(() => {
    refresh()
    // tiles live off realtime: status changes land on the card with no query
    const chan = supabase
      .channel('floor-tiles')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'agent_status' }, (p) => {
        const s = p.new as { agent_id?: string; status?: string; lead_name?: string | null; phone_display?: string | null; since?: string; updated_at?: string }
        if (!s?.agent_id) return
        setBoard((b) => b && {
          ...b,
          tiles: b.tiles.map((t) => t.agent_id === s.agent_id
            ? { ...t, status: (s.status ?? t.status) as FloorRow['status'], lead_name: s.lead_name ?? null,
                phone_display: s.phone_display ?? null, since: s.since ?? t.since, last_seen: s.updated_at ?? t.last_seen }
            : t),
        })
      })
      .subscribe()
    const iv = window.setInterval(refresh, 30_000)
    const onShow = () => { if (!document.hidden) refresh() }
    document.addEventListener('visibilitychange', onShow)
    return () => {
      supabase.removeChannel(chan)
      window.clearInterval(iv)
      document.removeEventListener('visibilitychange', onShow)
    }
  }, [refresh])

  useEffect(() => { if (view === 'calls') refreshCalls() }, [view, refreshCalls])

  function flash(m: string) {
    setToast(m); window.setTimeout(() => setToast(null), 2500)
  }

  function copy(text: string) {
    navigator.clipboard?.writeText(text).then(() => flash('Copied'))
  }

  async function requeue(cb: NonNullable<FloorBoard['callbacks']>[number]) {
    // item 39: irreversible, so it says what it is about to do
    if (!window.confirm(`Push ${cb.lead} back to the queue?\n\n${cb.agent}'s callback is handed back and anyone can be served this lead. A lead mid-call is refused.`)) return
    const { error } = await supabase.rpc('release_lead', { p_lead_id: cb.lead_id })
    if (error) flash(error.message)
    refresh()
  }

  async function keep(c: RecentCall) {
    const lead = c.leads?.name ?? 'a lead'
    const { error } = await saveToLibrary({
      title: `${lead}: ${dispositionLabel(c.disposition)}`,
      scenario: scenarioFor(c.disposition),
      body: callBody({ disposition: c.disposition, duration: c.duration_seconds, note: c.note,
        taps: tapsByObjection(c.card_taps ?? []), summary: c.ai_summary?.summary }),
      attempt_id: c.id, lead_name: c.leads?.name ?? null, agent_name: c.profiles?.name ?? null,
    })
    flash(error ? error.message : 'Saved to the library (Playbook tab)')
  }

  /** E5: one vote a day, for someone else's conversation today; voting again moves it. */
  async function vote(c: RecentCall) {
    const lb = board?.leaderboard
    const mine = lb?.my_vote === c.id
    const { error } = await supabase.rpc('vote_call', { p_attempt_id: mine ? null : c.id })
    if (error) { flash(error.message); return }
    flash(mine ? 'Vote taken back' : `Voted for ${c.profiles?.name ?? 'that'}'s call`)
    refresh()
  }
  const votable = (c: RecentCall) => {
    const lb = board?.leaderboard
    return !!lb && !!c.disposition && !!c.connected && c.disposition !== 'gatekeeper_end'
      && Date.parse(c.clicked_at) >= Date.parse(lb.from)
  }

  // item 43: a manager who is not working the phones is not a tile on the floor
  const tiles = (board?.tiles ?? []).filter((r) =>
    r.role !== 'manager' || r.dials_today > 0 || r.status === 'dialing' || r.status === 'on_call')

  const lb = board?.leaderboard ?? null

  return (
    <div className="page">
      <div className="rangebar" role="tablist" aria-label="Floor views">
        {([['live', 'Live board'], ['board', 'Leaderboard'], ['calls', 'Calls']] as [View, string][]).map(([k, label]) => (
          <button key={k} role="tab" aria-selected={view === k}
            className={`rangebtn ${view === k ? 'active' : ''}`} onClick={() => setView(k)}>{label}</button>
        ))}
      </div>

      {err && <LoadError what="the floor board" error={err} onRetry={refresh} />}

      {view === 'live' && (
        <>
          <AlertsPanel alerts={board?.alerts ?? null} isManager={isManager} />

          <div className="floorgrid">
            {tiles.map((r) => {
              const pct = targets.dials ? Math.min(100, Math.round((100 * r.dials_today) / targets.dials)) : null
              const p = paceMap.get(r.agent_id)
              return (
                <div className="card agenttile" key={r.agent_id}>
                  <div className="aname"><span className={`statusdot ${r.status}`} />{r.name}</div>
                  <div className="small muted" style={{ minHeight: 20 }}>
                    {statusLine(r, p)}
                    {r.lead_name && <> · {r.lead_name}</>}
                  </div>
                  {r.phone_display && (
                    <div className="small">
                      {fmtPhone(r.phone_display)}
                      <button className="copybtn" onClick={() => copy(r.phone_display!)}>copy</button>
                    </div>
                  )}
                  <div className="tilecounts">
                    <Count value={r.dials_today} target={targets.dials} label="dials" />
                    <Count value={r.conversations_today} target={targets.conversations} label="conversations" />
                    <Count value={r.handoffs_today} target={targets.handoffs} label="handoffs" />
                    <span><b>{r.emails_today}</b>emails</span>
                  </div>
                  {pct != null && (
                    <div className="targetbar" title={`${pct}% of today's dial target`}><i style={{ width: `${pct}%` }} /></div>
                  )}
                  {p?.dials_per_hour != null && (
                    <div className="small muted tilepace">
                      {Math.round(p.dials_per_hour)} dials/hr{p.talk_minutes_per_hour != null ? ` · talk ${Math.round(p.talk_minutes_per_hour)} min/hr` : ''}
                    </div>
                  )}
                </div>
              )
            })}
            {!tiles.length && !err && (
              <div className="muted">{board ? (isManager ? 'No one on the floor yet: add agents on the Users tab.' : 'No one on the floor yet.') : 'Loading the floor…'}</div>
            )}
          </div>

          {isManager && board?.callbacks && (
            <>
              <div className="sectionhead"><h3>Scheduled callbacks</h3><span className="muted small">times on the lead's own clock — push back hands the promise to the queue</span></div>
              <div className="card">
                {board.callbacks.length ? (
                  <div className="tablewrap"><table className="data">
                    <thead><tr><th>Due (their time)</th><th>Lead</th><th>Agent</th><th>Tries</th><th /></tr></thead>
                    <tbody>
                      {board.callbacks.map((c) => (
                        <tr key={c.id}>
                          <td>{leadLocal(c.due_at, c.tz)}</td>
                          <td>{c.lead}</td>
                          <td>{c.agent}</td>
                          <td>{c.tries || ''}</td>
                          <td><button className="btn ghost small" onClick={() => requeue(c)}>push back to queue</button></td>
                        </tr>
                      ))}
                    </tbody>
                  </table></div>
                ) : <span className="muted small">None scheduled.</span>}
              </div>
            </>
          )}
        </>
      )}

      {view === 'board' && (
        <LeaderboardCard today={lb} sprint={board?.sprint ?? null} me={me} isManager={isManager} onChanged={refresh} />
      )}

      {view === 'calls' && (
        <>
          <div className="sectionhead"><h3>Recent calls</h3><span className="muted small">talk time from Zoom{aiOn ? '; the AI summary appears a few minutes after the call' : ''} · vote for today's call of the day</span></div>
          {callsErr && <LoadError what="the recent calls" error={callsErr} onRetry={refreshCalls} />}
          <div className="card">
            {calls.length ? (
              <div className="tablewrap">
                <table className="data">
                  <thead><tr><th>When</th><th>Agent</th><th>Lead</th><th>Talk</th><th>Outcome</th><th>Call log</th>{aiOn && <th>AI summary</th>}<th>Votes</th>{isManager && <th />}</tr></thead>
                  <tbody>
                    {calls.map((c) => {
                      const votes = lb?.votes[String(c.id)] ?? 0
                      const mine = lb?.my_vote === c.id
                      return (
                        <tr key={c.id} className={lb?.call_of_the_day?.attempt_id === c.id ? 'cotd' : ''}>
                          <td>{new Date(c.clicked_at).toLocaleString([], { dateStyle: 'short', timeStyle: 'short' })}</td>
                          <td>{c.profiles?.name ?? '—'}</td>
                          <td>{c.leads?.name ?? '—'}</td>
                          <td>{talkTime(c)}</td>
                          <td>{dispositionLabel(c.disposition)}</td>
                          <td>
                            {tapsByObjection(c.card_taps ?? []).map((t) => (
                              <div key={t.objection} className="small">
                                heard “{t.objection}”{t.counters.length ? <span className="muted"> → said: {t.counters.join(' / ')}</span> : null}
                              </div>
                            ))}
                            {c.note ? <div className="small">{c.note}</div> : !c.card_taps?.length && <span className="muted small">—</span>}
                          </td>
                          {aiOn && (
                            <td>
                              {c.ai_summary?.summary ? (
                                <div className="aisum">
                                  {c.ai_summary.summary}
                                  {c.ai_summary.next_steps && <div className="muted">Next: {c.ai_summary.next_steps}</div>}
                                </div>
                              ) : <span className="muted small">—</span>}
                            </td>
                          )}
                          <td className="rowactions">
                            {votes > 0 && <span className="votes">{votes}</span>}
                            {votable(c) && c.agent_id !== me && (
                              <button className={`btn ghost small ${mine ? 'voted' : ''}`} onClick={() => vote(c)}
                                title={mine ? 'Take your vote back' : 'Your one vote today for the call of the day'}>
                                {mine ? 'voted' : 'vote'}
                              </button>
                            )}
                          </td>
                          {isManager && (
                            <td className="rowactions">
                              {c.disposition && <button className="btn ghost small" title="Keep this call in the Playbook library" onClick={() => keep(c)}>save</button>}
                            </td>
                          )}
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            ) : <span className="muted small">{callsErr ? '' : 'No calls yet.'}</span>}
          </div>
        </>
      )}

      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
