// Fallback importer: load a CSV exported from the console ("Export CSV")
// straight into the dialing DB — works before the API sync is configured.
//   npm run import -- path\to\leads-2026-09-23.csv --mark-contacted
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

const args = process.argv.slice(2)
const path = args.find((a) => !a.startsWith('--'))
// Whether the console should stop offering these leads is not something to guess
// at: getting it wrong either hides leads nobody has called or hands the same
// leads out twice. So the person running the import says which it is.
const mark = args.includes('--mark-contacted')
const leave = args.includes('--leave-in-console')

if (!path || mark === leave) {
  console.error('usage: npm run import -- <csv path> --mark-contacted')
  console.error('   or: npm run import -- <csv path> --leave-in-console')
  console.error('')
  console.error('--mark-contacted    normal for a console export: the console is told these')
  console.error('                    leads are taken, the next time the sync talks to it, so')
  console.error('                    nothing exports them to anywhere else again.')
  console.error('--leave-in-console  the console keeps offering them. Only for a file that did')
  console.error('                    not come from the console, or for a trial run.')
  process.exit(1)
}

const records = parseCsv(readFileSync(path, 'utf8'))
console.log(`parsed ${records.length} rows`)

// A row with no console lead id has nothing to match an earlier import on, so the
// upsert can only ever insert it: re-importing the same file would add a second
// copy of every one of them, and a third next week. They are left out.
const hasId = (r) => Number.isFinite(Number(String(r.id ?? '').trim())) && Number(r.id) > 0
const usable = records.filter(hasId)
const idless = records.length - usable.length
if (idless) {
  console.log(`${idless} row(s) have no lead id and are being left out — without one there is`)
  console.log('nothing to recognise them by later, so every import would add another copy.')
  console.log('Export the file again from the console to get the id column.')
}
if (!usable.length) {
  console.error('nothing to import: not one row has a lead id.')
  process.exit(1)
}
console.log(mark
  ? `importing ${usable.length} rows; the console will be told they are taken on the next sync`
  : `importing ${usable.length} rows and leaving them on offer in the console`)

logRun('csv_import', async () => {
  let total = 0, fresh = 0, unusable = 0
  for (let i = 0; i < usable.length; i += 200) {
    const r = await upsertLeads(usable.slice(i, i + 200), { markPending: mark })
    total += r.upserted
    fresh += r.imported.length
    unusable += r.unusable
    console.log(`  ${Math.min(i + 200, usable.length)}/${usable.length}`)
  }
  if (unusable) console.log(`  ${unusable} row(s) left out: no phone number anyone could dial`)
  const notes = [`${fresh} new, ${total - fresh} already here.`]
  if (idless) notes.push(`${idless} row(s) had no lead id.`)
  if (unusable) notes.push(`${unusable} row(s) had no dialable phone number.`)
  if (leave) notes.push('Left on offer in the console at the importer\'s request.')
  return { rows: total, detail: notes.join(' ') }
}).then((n) => { console.log(`import done: ${n} leads`); process.exit(0) })
  .catch((e) => { console.error(e); process.exit(1) })
