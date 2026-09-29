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
  const [rows, setRows] = useState<EmailRow[]>([])
  const [asks, setAsks] = useState<Record<number, string>>({}) // queue id → the note on the call that queued it
  const [templates, setTemplates] = useState<EmailTemplate[]>([])
  const [openId, setOpenId] = useState<number | null>(null)
  const [draft, setDraft] = useState<Draft>({ templateId: null, subject: '', body: '' })
  const [edit, setEdit] = useState<TemplateDraft | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  function say(msg: string) {
    setToast(msg)
    window.setTimeout(() => setToast(null), 1800)
  }

  const refresh = useCallback(() => {
    supabase.from('email_queue')
      .select('id, lead_id, email, status, template, flagged_by, created_at, sent_at, leads(name, addr_city, addr_state, category, website), profiles!email_queue_flagged_by_fkey(name)')
      .order('created_at', { ascending: false })
      .limit(100)
      .then(({ data }) => {
        const list = (data ?? []) as unknown as EmailRow[]
        setRows(list)
        // what the lead asked for: the agent's note on the call that queued the email
        const waiting = list.filter((r) => r.status === 'flagged')
        if (!waiting.length) { setAsks({}); return }
        supabase.from('attempts')
          .select('lead_id, agent_id, note, clicked_at')
          .eq('disposition', 'email_requested')
          .in('lead_id', [...new Set(waiting.map((r) => r.lead_id))])
          .order('clicked_at', { ascending: false })
          .then(({ data: calls }) => {
            const found: Record<number, string> = {}
            for (const r of waiting) {
              const call = (calls ?? []).find((c) => c.lead_id === r.lead_id && c.agent_id === r.flagged_by
                && Date.parse(c.clicked_at) <= Date.parse(r.created_at))
              if (call?.note) found[r.id] = call.note
            }
            setAsks(found)
          })
      })
  }, [])

  const loadTemplates = useCallback(() => {
    supabase.from('email_templates')
      .select('id, name, subject, body, active, sort')
      .order('sort').order('name')
      .then(({ data }) => setTemplates((data ?? []) as EmailTemplate[]))
  }, [])

  useEffect(() => { refresh(); loadTemplates() }, [refresh, loadTemplates])

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
    // the template is known only when it was written here
    const used = status === 'sent' && openId === r.id ? templates.find((t) => t.id === draft.templateId)?.name ?? null : null
    const { error } = await supabase.from('email_queue').update({
      status,
      template: used,
      sent_by: (await supabase.auth.getUser()).data.user?.id,
      sent_at: status === 'sent' ? new Date().toISOString() : null,
    }).eq('id', r.id)
    if (error) { say(error.message); return }
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

  const pending = rows.filter((r) => r.status === 'flagged')
  const done = rows.filter((r) => r.status !== 'flagged')
  const active = templates.filter((t) => t.active)
  const leftover = /\{[a-z_]+\}/i.test(draft.subject + draft.body)
  const previewRow = pending[0] ?? null
  // placeholders the editor's text uses that nothing fills in (a typo, usually)
  const unknown = edit
    ? [...new Set([...`${edit.subject} ${edit.body}`.matchAll(/\{([a-z_]+)\}/gi)].map((m) => m[1].toLowerCase()))]
      .filter((k) => !PLACEHOLDERS.some((p) => p.key === k))
    : []
  const pv = varsFor(previewRow, myName)

  return (
    <div className="page">
      <div className="sectionhead"><h3>Email queue</h3><span className="muted small">{pending.length} waiting · write it from a template, send it from your own mail app, then mark it sent</span></div>
      <div className="card">
        <div className="tablewrap">
          <table className="data">
            <thead><tr><th>Flagged</th><th>Lead</th><th>Email</th><th>By</th><th /></tr></thead>
            <tbody>
              {pending.map((r) => (
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
              {!pending.length && <tr><td colSpan={5} className="muted">Queue is clear.</td></tr>}
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
        {templates.length ? (
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

      {done.length > 0 && (
        <>
          <div className="sectionhead"><h3>History</h3></div>
          <div className="card">
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
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}
