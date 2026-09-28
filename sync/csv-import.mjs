// Fallback importer: load a CSV exported from the console ("Export CSV")
// straight into the dialing DB — works before the API sync is configured.
//   npm run import -- path\to\leads-2026-09-23.csv
import { readFileSync } from 'node:fs'
import { upsertLeads, logRun } from './lib/supa.mjs'

function parseCsv(text) {
  const rows = []
  let cur = [''], inQ = false, row = cur
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (inQ) {
      if (c === '"') {
        if (text[i + 1] === '"') { row[row.length - 1] += '"'; i++ }
        else inQ = false
      } else row[row.length - 1] += c
    } else if (c === '"') inQ = true
    else if (c === ',') row.push('')
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++
      if (row.length > 1 || row[0] !== '') rows.push(row)
      row = ['']; rows.length && (cur = row)
    } else row[row.length - 1] += c
  }
  if (row.length > 1 || row[0] !== '') rows.push(row)
  const [head, ...body] = rows
  return body.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ''])))
}

const path = process.argv[2]
if (!path) { console.error('usage: npm run import -- <csv path>'); process.exit(1) }

const records = parseCsv(readFileSync(path, 'utf8'))
console.log(`parsed ${records.length} rows`)

logRun('csv_import', async () => {
  let total = 0
  for (let i = 0; i < records.length; i += 200) {
    const { upserted } = await upsertLeads(records.slice(i, i + 200))
    total += upserted
    console.log(`  ${Math.min(i + 200, records.length)}/${records.length}`)
  }
  return total
}).then((n) => { console.log(`import done: ${n} leads`); process.exit(0) })
  .catch((e) => { console.error(e); process.exit(1) })
