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
  console.error('                    leads are taken — straight away if there is a console')
  console.error('                    password in sync/.env, otherwise the import says which')
  console.error('                    command to run — so nothing exports them elsewhere again.')
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
// Only promise what will actually happen: telling the console needs the password.
console.log(mark
  ? (process.env.CONSOLE_PASSWORD
    ? `importing ${usable.length} rows and then telling the console they are taken`
    : `importing ${usable.length} rows; read the note at the end about telling the console`)
  : `importing ${usable.length} rows and leaving them on offer in the console`)

logRun('csv_import', async () => {
  let total = 0, fresh = 0
  const unusable = []
  for (let i = 0; i < usable.length; i += 200) {
    const r = await upsertLeads(usable.slice(i, i + 200), { markPending: mark })
    total += r.upserted
    fresh += r.imported.length
    unusable.push(...r.unusable)
    console.log(`  ${Math.min(i + 200, usable.length)}/${usable.length}`)
  }
  if (unusable.length) {
    const named = unusable.filter((u) => u.id != null).map((u) => u.id).slice(0, 20).join(', ')
    console.log(`  ${unusable.length} row(s) left out: no phone number anyone could dial`
      + `${named ? ` (lead ${named}${unusable.length > 20 ? ', and more' : ''})` : ''}`)
  }
  const notes = [`${fresh} new, ${total - fresh} already here.`]
  if (idless) notes.push(`${idless} row(s) had no lead id.`)
  if (unusable.length) notes.push(`${unusable.length} row(s) had no dialable phone number.`)
  if (leave) notes.push('Left on offer in the console at the importer\'s request.')
  const told = mark ? await tellConsole() : null
  if (told) notes.push(told)
  return { rows: total, detail: notes.join(' ') }
}).then((n) => { console.log(`import done: ${n} leads`); process.exit(0) })
  .catch((e) => { console.error(e); process.exit(1) })

/** Tell the console these leads are taken, here and now if we can.
 *
 *  The import only flags them; something has to carry the flag over to the console,
 *  and until now that was the next API sync. But this importer is for the case where
 *  there is no API sync yet, so for exactly the people who need it nothing ever
 *  carried it, and the scraper went on offering the same leads elsewhere. With a
 *  password in hand we do it here; without one, the owner is told the one command
 *  that does it, instead of being promised something that will not happen. */
async function tellConsole() {
  if (!process.env.CONSOLE_PASSWORD) {
    console.log('')
    console.log('The console has NOT been told yet — there is no console password in sync/.env.')
    console.log('Until it is told, the scraper can export these same leads somewhere else again.')
    console.log('Once the password is in sync/.env, run:  npm run pull -- --marks-only')
    return 'The console was not told these leads are taken: no password. Run npm run pull -- --marks-only.'
  }
  try {
    // Loaded here rather than at the top so an import with no console access never
    // needs the console client at all.
    const { ensureAuth } = await import('./lib/console.mjs')
    const { flushContacted } = await import('./pull-leads.mjs')
    await ensureAuth()
    const { marked, note } = await flushContacted()
    console.log(`  told the console about ${marked} lead(s)`)
    return [`Told the console about ${marked} lead(s).`, note].filter(Boolean).join(' ')
  } catch (e) {
    // The import itself is good and the flags are saved, so this is not a failure of
    // the import — it is a thing still to do.
    console.log('')
    console.log(`The console could not be told just now: ${e.message}`)
    console.log('The leads are imported and the flags are kept. When the console is back, run:')
    console.log('  npm run pull -- --marks-only')
    return `The console could not be told these leads are taken (${e.message}).`
      + ' Run npm run pull -- --marks-only.'
  }
}
