import { Fragment, useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { fillTemplate, mailtoHref, PLACEHOLDERS, type EmailTemplate } from '../lib/email'

interface EmailRow {
  id: number
  lead_id: number
  email: string
  status: string
  template: string | null
  flagged_by: string | null
  created_at: string
  sent_at: string | null
  leads: { name: string; addr_city: string | null; addr_state: string | null; category: string | null; website: string | null } | null
  profiles: { name: string } | null
}

interface Draft { templateId: number | null; subject: string; body: string }
interface TemplateDraft { id: number | null; name: string; subject: string; body: string; active: boolean }

// the editor's preview when nothing is waiting in the queue
const SAMPLE = { business: 'Sample Plumbing Co', city: 'Tampa', state: 'FL', category: 'Plumber', website: '', agent: 'Ana' }

// the waiting list and the history show the same row, so they read the same columns
const COLUMNS = 'id, lead_id, email, status, template, flagged_by, created_at, sent_at,'
  + ' leads(name, addr_city, addr_state, category, website), profiles!email_queue_flagged_by_fkey(name)'

// how many finished emails the history shows before the manager asks for more
const HISTORY_PAGE = 25

function varsFor(r: EmailRow | null, myName: string): Record<string, string> {
  if (!r) return { ...SAMPLE, my_name: myName }
  return {
    business: r.leads?.name ?? '',
    city: r.leads?.addr_city ?? '',
    state: r.leads?.addr_state ?? '',
    category: r.leads?.category ?? '',
    website: r.leads?.website ?? '',
    agent: r.profiles?.name ?? 'our team',
    my_name: myName,
  }
}

/** G5: like your SMS ritual, but for email — the system queues, fills in a
 *  template and tracks; a human sends from their own mail client. */
export default function Emails({ myName }: { myName: string }) {
  const [waiting, setWaiting] = useState<EmailRow[]>([])
  const [waitingTotal, setWaitingTotal] = useState(0) // what the server counts, not what it chose to send
  const [queueLoaded, setQueueLoaded] = useState(false)
  const [done, setDone] = useState<EmailRow[]>([])
  const [doneTotal, setDoneTotal] = useState(0)
  const [shown, setShown] = useState(HISTORY_PAGE) // rows of history asked for so far
  const [fetched, setFetched] = useState<number | null>(null) // the history size the rows on screen came from
  const [asks, setAsks] = useState<Record<number, string>>({}) // queue id → the note on the call that queued it
  const [templates, setTemplates] = useState<EmailTemplate[]>([])
  // Three things can fail on their own, so each says so on its own. One shared
  // error would make a failed note lookup tell the manager that the number of
  // waiting emails is unknown while the waiting emails sit on screen below it.
  const [queueError, setQueueError] = useState<string | null>(null)
  const [noteError, setNoteError] = useState<string | null>(null)
  const [historyError, setHistoryError] = useState<string | null>(null)
  // A refused mark-sent stays on screen. A toast that clears itself after a second
  // and a half is how a manager comes away believing an email went out when the row
  // never moved, which is the one mistake this page exists to prevent.
  const [actionError, setActionError] = useState<string | null>(null)
  const [tplError, setTplError] = useState<string | null>(null)
  const [reload, setReload] = useState(0) // bumped to ask for both halves again after a change
  const [openId, setOpenId] = useState<number | null>(null)
  const [draft, setDraft] = useState<Draft>({ templateId: null, subject: '', body: '' })
  const [edit, setEdit] = useState<TemplateDraft | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  function say(msg: string) {
    setToast(msg)
    window.setTimeout(() => setToast(null), 1800)
  }

  // Asks for both halves again, after a row has been marked sent or skipped.
  function refresh() { setReload((n) => n + 1) }

  useEffect(() => {
    // The emails still waiting are the work, so every one of them comes down, no
    // matter how many: a request that fell off the end of a page is an email a
    // customer was promised and never got. The count comes down beside them because
    // the API has its own ceiling on how many rows it will return, and without the
    // count a page capped at that ceiling would quietly under-report the backlog.
    // Oldest first, because the one promised longest ago is the late one.
    // This is its own request, separate from the history below, so that asking for
    // another page of history does not fetch the whole backlog again.
    let live = true
    supabase.from('email_queue').select(COLUMNS, { count: 'exact' })
      .eq('status', 'flagged')
      .order('created_at')
      .then(({ data, count, error: e }) => {
        // A mark-sent and the refresh it triggers can overlap, so anything this
        // request writes is gated on it still being the newest one.
        if (!live) return
        setQueueLoaded(true)
        if (e) {
          // The header, the banner and the empty table have to say the same thing,
          // so the rows from the last good load go with the count: rows on screen
          // under a header that says the count is unknown is the worse lie.
          setQueueError(`The email queue did not load: ${e.message}`)
          setWaiting([]); setWaitingTotal(0); setAsks({}); setNoteError(null)
          return
        }
        setQueueError(null)
        const list = (data ?? []) as unknown as EmailRow[]
        setWaiting(list)
        setWaitingTotal(count ?? list.length)
        if (!list.length) { setAsks({}); setNoteError(null); return }
        // what the lead asked for: the agent's note on the call that queued the email
        supabase.from('attempts')
          .select('lead_id, agent_id, note, clicked_at')
          .eq('disposition', 'email_requested')
          .in('lead_id', [...new Set(list.map((r) => r.lead_id))])
          .order('clicked_at', { ascending: false })
          .then(({ data: calls, error: failed }) => {
            if (!live) return
            if (failed) {
              // The notes are extra detail beside a row, so their failure gets its
              // own line and leaves the count alone. The old notes go either way: a
              // note from the last refresh sitting beside a row it may not belong
              // to is worse than no note at all.
              setNoteError(`The queue loaded, but what each lead asked for did not: ${failed.message}`)
              setAsks({})
              return
            }
            setNoteError(null)
            const found: Record<number, string> = {}
            for (const r of list) {
              const call = (calls ?? []).find((c) => c.lead_id === r.lead_id && c.agent_id === r.flagged_by
                && Date.parse(c.clicked_at) <= Date.parse(r.created_at))
              if (call?.note) found[r.id] = call.note
            }
            setAsks(found)
          })
      })
    return () => { live = false }
  }, [reload])

  useEffect(() => {
    // The finished emails are only a record, so they stay capped at a page and the
    // manager asks for more when they want them.
    let live = true
    supabase.from('email_queue').select(COLUMNS, { count: 'exact' })
      .neq('status', 'flagged')
      .order('created_at', { ascending: false })
      .range(0, shown - 1)
      .then(({ data, count, error: e }) => {
        // Marking a row sent and then clicking for more history puts two requests in
        // flight. Without this the first one could land last, leaving `fetched`
        // behind `shown` for good: the button would read "Loading…", stay disabled,
        // and the history could not be paged again without reloading the page.
        if (!live) return
        setFetched(shown)
        if (e) {
          setHistoryError(`The sent and skipped emails did not load: ${e.message}`)
          setDone([]); setDoneTotal(0)
          return
        }
        setHistoryError(null)
        setDone((data ?? []) as unknown as EmailRow[])
        setDoneTotal(count ?? 0)
      })
    return () => { live = false }
  }, [shown, reload])

  const loadTemplates = useCallback(() => {
    supabase.from('email_templates')
      .select('id, name, subject, body, active, sort')
      .order('sort').order('name')
      .then(({ data, error: e }) => {
        if (e) { setTplError(`The templates did not load: ${e.message}`); return }
        setTplError(null)
        setTemplates((data ?? []) as EmailTemplate[])
      })
  }, [])

  useEffect(() => { loadTemplates() }, [loadTemplates])

  function copy(text: string, msg = 'Copied') {
    navigator.clipboard?.writeText(text).then(() => say(msg))
  }

  function fill(t: EmailTemplate | null, r: EmailRow): Draft {
    if (!t) return { templateId: null, subject: '', body: '' }
    const v = varsFor(r, myName)
    return { templateId: t.id, subject: fillTemplate(t.subject, v), body: fillTemplate(t.body, v) }
  }

  function toggleComposer(r: EmailRow) {
    if (openId === r.id) { setOpenId(null); return }
    setOpenId(r.id)
    setDraft(fill(templates.find((t) => t.active) ?? null, r))
  }

  async function mark(r: EmailRow, status: 'sent' | 'skipped') {
    // Skipping throws the request away and the lead was promised an email, so ask first.
    if (status === 'skipped' && !window.confirm(
      `Skip the email to ${r.leads?.name ?? r.email}? The request leaves the queue, nothing is sent, and there is no undo.`)) return
    // the template is known only when it was written here
    const used = status === 'sent' && openId === r.id ? templates.find((t) => t.id === draft.templateId)?.name ?? null : null
    const { error: e } = await supabase.from('email_queue').update({
      status,
      template: used,
      sent_by: (await supabase.auth.getUser()).data.user?.id,
      sent_at: status === 'sent' ? new Date().toISOString() : null,
    }).eq('id', r.id)
    if (e) {
      setActionError(`${r.leads?.name ?? r.email} is still waiting — it was not marked ${status}: ${e.message}`)
      return
    }
    setActionError(null)
    if (openId === r.id) setOpenId(null)
    say(status === 'sent' ? 'Marked sent' : 'Skipped')
    refresh()
  }

  async function saveTemplate() {
    if (!edit) return
    if (!edit.name.trim()) { say('Give the template a name'); return }
    const row = { name: edit.name.trim(), subject: edit.subject, body: edit.body, active: edit.active, updated_at: new Date().toISOString() }
    const { error } = edit.id
      ? await supabase.from('email_templates').update(row).eq('id', edit.id)
      : await supabase.from('email_templates').insert({ ...row, sort: Math.max(0, ...templates.map((t) => t.sort)) + 1 })
    if (error) { say(error.code === '23505' ? 'A template with that name already exists' : error.message); return }
    setEdit(null)
    say('Template saved')
    loadTemplates()
  }

  async function deleteTemplate() {
    if (!edit?.id || !window.confirm(`Delete the template "${edit.name}"? Emails already sent keep its name.`)) return
    const { error } = await supabase.from('email_templates').delete().eq('id', edit.id)
    if (error) { say(error.message); return }
    setEdit(null)
    say('Template deleted')
    loadTemplates()
  }

  // a request is in flight while the history on screen is a smaller page than the one asked for
  const historyLoading = fetched !== shown
  const historyLoaded = fetched !== null
  const active = templates.filter((t) => t.active)
  const leftover = /\{[a-z_]+\}/i.test(draft.subject + draft.body)
  // The queue is oldest first, so this is the email that has been waiting longest:
  // the row at the top of the table, and the one a manager is about to write.
  const previewRow = waiting[0] ?? null
  // placeholders the editor's text uses that nothing fills in (a typo, usually)
  const unknown = edit
    ? [...new Set([...`${edit.subject} ${edit.body}`.matchAll(/\{([a-z_]+)\}/gi)].map((m) => m[1].toLowerCase()))]
      .filter((k) => !PLACEHOLDERS.some((p) => p.key === k))
    : []
  const pv = varsFor(previewRow, myName)

  return (
    <div className="page">
      <div className="sectionhead">
        <h3>Email queue</h3>
        <span className="muted small">
          {!queueLoaded ? 'counting…' : queueError ? 'how many are waiting is unknown' : `${waitingTotal} waiting`}
          {' '}· write it from a template, send it from your own mail app, then mark it sent
        </span>
      </div>
      {queueError && <div className="card alertcard">{queueError}</div>}
      {noteError && <div className="card alertcard">{noteError}</div>}
      {actionError && <div className="card alertcard">{actionError}</div>}
      {/* The server has a ceiling on how many rows one request may return. If the
          backlog ever passes it, say so rather than let the missing requests look
          like requests that were never made. */}
      {waitingTotal > waiting.length && (
        <div className="card alertcard">
          {waitingTotal} emails are waiting, but the server would only send {waiting.length} of them at once,
          so the oldest {waiting.length} are shown here. Clear some and the rest appear.
        </div>
      )}
      <div className="card">
        <div className="tablewrap">
          <table className="data">
            <thead><tr><th>Flagged</th><th>Lead</th><th>Email</th><th>By</th><th /></tr></thead>
            <tbody>
              {waiting.map((r) => (
                <Fragment key={r.id}>
                  <tr>
                    <td>{new Date(r.created_at).toLocaleDateString()}</td>
                    <td>
                      {r.leads?.name}<br /><span className="muted small">{r.leads?.addr_city}, {r.leads?.addr_state}</span>
                      {asks[r.id] && <div className="asknote">“{asks[r.id]}”</div>}
                    </td>
                    <td>{r.email} <button className="copybtn" onClick={() => copy(r.email)}>copy</button></td>
                    <td>{r.profiles?.name ?? '—'}</td>
                    <td className="rowactions">
                      <button className={`btn ${openId === r.id ? '' : 'primary'}`} onClick={() => toggleComposer(r)}>
                        {openId === r.id ? 'Close' : 'Write email'}
                      </button>
                      {openId !== r.id && <button className="btn ghost" onClick={() => mark(r, 'sent')}>mark sent</button>}
                      <button className="btn ghost" onClick={() => mark(r, 'skipped')}>skip</button>
                    </td>
                  </tr>
                  {openId === r.id && (
                    <tr className="composerrow">
                      <td colSpan={5}>
                        <div className="composer">
                          <label>Template
                            <select value={draft.templateId ?? ''}
                              onChange={(e) => setDraft(fill(templates.find((t) => t.id === Number(e.target.value)) ?? null, r))}>
                              {active.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                              <option value="">Blank</option>
                            </select>
                          </label>
                          <label>Subject
                            <input value={draft.subject} onChange={(e) => setDraft({ ...draft, subject: e.target.value })} />
                          </label>
                          <label>Body
                            <textarea rows={11} value={draft.body} onChange={(e) => setDraft({ ...draft, body: e.target.value })} />
                          </label>
                          {leftover && <div className="warnline">A {'{placeholder}'} is still in the text: check the spelling in the template.</div>}
                          <div className="actionrow">
                            <a className="btn primary" href={mailtoHref(r.email, draft.subject, draft.body)}>Open in mail app</a>
                            <button className="btn" onClick={() => copy(draft.subject, 'Subject copied')}>Copy subject</button>
                            <button className="btn" onClick={() => copy(draft.body, 'Body copied')}>Copy body</button>
                            <span className="muted small">sent it?</span>
                            <button className="btn" onClick={() => mark(r, 'sent')}>Mark sent</button>
                          </div>
                        </div>
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
              {!waiting.length && (
                <tr>
                  <td colSpan={5} className="muted">
                    {!queueLoaded ? 'Loading the queue…'
                      : queueError ? 'The queue could not be read, so there is nothing to show here.'
                        : 'Queue is clear.'}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      <div className="sectionhead">
        <h3>Templates</h3>
        <span className="muted small">placeholders fill in from the lead and the call</span>
        <button className="btn" style={{ marginLeft: 'auto' }}
          onClick={() => setEdit({ id: null, name: '', subject: '', body: '', active: true })}>New template</button>
      </div>
      <div className="card">
        {tplError ? <span className="warnline">{tplError}</span>
          : templates.length ? (
            <div className="tablewrap">
              <table className="data">
                <tbody>
                  {templates.map((t) => (
                    <tr key={t.id}>
                      <td>
                        <b>{t.name}</b>{!t.active && <span className="tag" style={{ marginLeft: 8 }}>off</span>}
                        <div className="muted small">{t.subject}</div>
                      </td>
                      <td className="rowactions">
                        <button className="btn ghost"
                          onClick={() => setEdit({ id: t.id, name: t.name, subject: t.subject, body: t.body, active: t.active })}>edit</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <span className="muted small">No templates yet.</span>}
      </div>

      {edit && (
        <div className="card tpleditor">
          <div className="tplgrid">
            <div className="tplform">
              <label>Name<input value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} autoFocus /></label>
              <label>Subject<input value={edit.subject} onChange={(e) => setEdit({ ...edit, subject: e.target.value })} /></label>
              <label>Body<textarea rows={13} value={edit.body} onChange={(e) => setEdit({ ...edit, body: e.target.value })} /></label>
              <label className="check">
                <input type="checkbox" checked={edit.active} onChange={(e) => setEdit({ ...edit, active: e.target.checked })} />
                Offer it when writing an email
              </label>
              <div className="actionrow">
                <button className="btn primary" onClick={saveTemplate}>Save template</button>
                <button className="btn ghost" onClick={() => setEdit(null)}>Cancel</button>
                {edit.id && <button className="btn danger" style={{ marginLeft: 'auto' }} onClick={deleteTemplate}>Delete</button>}
              </div>
            </div>
            <div>
              <div className="kpilabel">Preview · {previewRow ? previewRow.leads?.name : 'a sample lead'}</div>
              <div className="mailpreview"><b>{fillTemplate(edit.subject, pv)}</b>{'\n\n'}{fillTemplate(edit.body, pv)}</div>
              {unknown.length > 0 && (
                <div className="warnline" style={{ marginBottom: 8 }}>
                  Not a placeholder: {unknown.map((k) => `{${k}}`).join(' ')}. It would go out as typed.
                </div>
              )}
              <ul className="phlist">
                {PLACEHOLDERS.map((p) => <li key={p.key}><code>{`{${p.key}}`}</code> {p.means}</li>)}
              </ul>
            </div>
          </div>
        </div>
      )}

      {/* Shown while the first page is still on its way, and when it failed, so the
          history has a "loading" line and an error of its own instead of looking
          like a floor that has never sent an email. */}
      {(!historyLoaded || historyError || doneTotal > 0) && (
        <>
          <div className="sectionhead">
            <h3>History</h3>
            <span className="muted small">
              {!historyLoaded ? 'counting…'
                : historyError ? 'how many have gone out is unknown'
                  : `${done.length === doneTotal ? `all ${doneTotal}` : `the newest ${done.length} of ${doneTotal}`}, sent or skipped`}
            </span>
          </div>
          {historyError && <div className="card alertcard">{historyError}</div>}
          <div className={`card ${historyLoading && historyLoaded ? 'stale' : ''}`}>
            <div className="tablewrap">
              <table className="data">
                <thead><tr><th>Flagged</th><th>Lead</th><th>Email</th><th>Outcome</th><th>Template</th></tr></thead>
                <tbody>
                  {done.map((r) => (
                    <tr key={r.id}>
                      <td>{new Date(r.created_at).toLocaleDateString()}</td>
                      <td>{r.leads?.name}</td>
                      <td>{r.email}</td>
                      <td>{r.status === 'sent' ? `sent${r.sent_at ? ` ${new Date(r.sent_at).toLocaleDateString()}` : ''}` : r.status}</td>
                      <td>{r.template ?? <span className="muted">—</span>}</td>
                    </tr>
                  ))}
                  {!done.length && (
                    <tr>
                      <td colSpan={5} className="muted">
                        {!historyLoaded ? 'Loading the history…'
                          : historyError ? 'The history could not be read, so none of it can be shown.'
                            : 'Nothing has been sent or skipped yet.'}
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
            {done.length < doneTotal && (
              <div className="actionrow" style={{ marginTop: 10 }}>
                <button className="btn" disabled={historyLoading} onClick={() => setShown(shown + HISTORY_PAGE)}>
                  {historyLoading ? 'Loading…' : `Show ${Math.min(HISTORY_PAGE, doneTotal - done.length)} more`}
                </button>
              </div>
            )}
          </div>
        </>
      )}
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
