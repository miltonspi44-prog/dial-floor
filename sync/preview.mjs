// Look before importing: logs in to the console once, reads the first page of
// dialable leads and shows how they map onto the dialing DB. Writes nothing,
// anywhere (no Supabase connection, no `contacted` marks).
//   npm run preview            (or: node preview.mjs [sample size])
import { ensureAuth, leadsPage } from './lib/console.mjs'
import { mapLead } from './lib/map.mjs'

const size = Number(process.argv[2] ?? 20)
await ensureAuth()
const { total, leads = [] } = await leadsPage(size, 0)
const mapped = leads.map(mapLead)
const ok = mapped.filter(Boolean)

console.log(`console reports ${total} dialable leads; sampled ${leads.length}`)
console.log(`fields the console sends: ${Object.keys(leads[0] ?? {}).join(', ') || '(none)'}`)
console.log(`${ok.length}/${leads.length} sampled rows map to a dialable lead (10-digit US phone)`)
for (const [i, row] of leads.slice(0, 5).entries()) {
  const m = mapped[i]
  console.log(m
    ? `  ok    #${m.source_id} ${m.name} · ${m.phone_norm} · ${m.addr_city ?? '?'}, ${m.addr_state ?? '?'} · score ${m.score ?? '—'} · ${m.website_type ?? '—'}`
    : `  SKIP  #${row.id}: phone ${JSON.stringify(row.phone ?? null)} is not a 10-digit US number`)
}
if (!leads.length || ok.length / leads.length < 0.8) {
  console.error('preview: most rows would be skipped — check the field names above before pulling')
  process.exit(1)
}
