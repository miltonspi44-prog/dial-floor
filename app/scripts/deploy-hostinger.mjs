// Deploy app/dist to https://dialer.sedsolutions.online through the Hostinger API.
//
//   npm run deploy            (builds first; needs HOSTINGER_API_TOKEN in the environment)
//   node scripts/deploy-hostinger.mjs --zip-only out.zip   (just write the archive)
//
// Zips dist/, uploads the zip into the site's public_html, then asks Hostinger to
// deploy it — which REPLACES everything in that site's public_html. The target is
// fixed below on purpose: this account also hosts sedsolutions.online, the lead
// console and client sites, and none of them may ever be a deploy target.
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { deflateRawSync } from 'node:zlib'

const DOMAIN = 'dialer.sedsolutions.online'
const API = 'https://developers.hostinger.com'
const DIST = fileURLToPath(new URL('../dist/', import.meta.url))
const TOKEN = process.env.HOSTINGER_API_TOKEN

function fail(msg) { console.error(`deploy: ${msg}`); process.exit(1) }

async function api(method, path, body) {
  const res = await fetch(API + path, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  if (!res.ok) fail(`${method} ${path} -> ${res.status} ${text.slice(0, 300)}`)
  return text ? JSON.parse(text) : null
}

// --- a small zip writer (deflate), so deploying needs nothing beyond Node ---
const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})
function crc32(buf) {
  let c = 0xffffffff
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}
function zip(entries) { // [{ name, data }] — a name ending in '/' is a directory
  const parts = [], central = []
  let offset = 0
  // Stamp the files with the build time. The web server's file cache keys on size +
  // mtime: with a fixed 1980 stamp, a new index.html of the same size (it always is)
  // looked unchanged and the old one kept being served.
  const now = new Date()
  const dosTime = (now.getUTCHours() << 11) | (now.getUTCMinutes() << 5) | (now.getUTCSeconds() >> 1)
  const dosDate = ((now.getUTCFullYear() - 1980) << 9) | ((now.getUTCMonth() + 1) << 5) | now.getUTCDate()
  for (const { name, data } of entries) {
    const isDir = name.endsWith('/')
    const raw = isDir ? Buffer.alloc(0) : data
    const body = isDir ? raw : deflateRawSync(raw)
    const nameBuf = Buffer.from(name, 'utf8')
    const crc = crc32(raw)
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x0800, 6)
    local.writeUInt16LE(isDir ? 0 : 8, 8); local.writeUInt16LE(dosTime, 10); local.writeUInt16LE(dosDate, 12)
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(body.length, 18); local.writeUInt32LE(raw.length, 22)
    local.writeUInt16LE(nameBuf.length, 26)
    const cen = Buffer.alloc(46)
    cen.writeUInt32LE(0x02014b50, 0); cen.writeUInt16LE(0x0314, 4); cen.writeUInt16LE(20, 6)
    cen.writeUInt16LE(0x0800, 8); cen.writeUInt16LE(isDir ? 0 : 8, 10); cen.writeUInt16LE(dosTime, 12)
    cen.writeUInt16LE(dosDate, 14); cen.writeUInt32LE(crc, 16); cen.writeUInt32LE(body.length, 20)
    cen.writeUInt32LE(raw.length, 24); cen.writeUInt16LE(nameBuf.length, 28)
    cen.writeUInt32LE(((isDir ? 0o40755 : 0o100644) << 16) >>> 0, 38); cen.writeUInt32LE(offset, 42)
    parts.push(local, nameBuf, body)
    central.push(cen, nameBuf)
    offset += local.length + nameBuf.length + body.length
  }
  const cd = Buffer.concat(central)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10)
  end.writeUInt32LE(cd.length, 12); end.writeUInt32LE(offset, 16)
  return Buffer.concat([...parts, cd, end])
}
function walk(dir) {
  return readdirSync(dir).sort().flatMap((f) => {
    const p = join(dir, f)
    if (!statSync(p).isDirectory()) return [{ name: relative(DIST, p).split(sep).join('/'), data: readFileSync(p) }]
    return [{ name: relative(DIST, p).split(sep).join('/') + '/' }, ...walk(p)]
  })
}

// --- 1. the build must be complete and point at Supabase -----------------
const files = walk(DIST)
const indexHtml = files.find((f) => f.name === 'index.html')?.data.toString()
if (!indexHtml) fail('dist/index.html missing: run the build first')
if (!files.some((f) => f.name === '.htaccess')) fail('dist/.htaccess missing (it comes from app/public/)')
const entry = indexHtml.match(/src="\/(assets\/[^"]+\.js)"/)?.[1]
const bundle = files.find((f) => f.name === entry)?.data.toString() ?? ''
if (!/https:\/\/[a-z0-9]+\.supabase\.co/.test(bundle)) fail('the build has no Supabase URL: copy app/.env.example to app/.env.local and rebuild')
if (process.argv[2] === '--zip-only') {
  writeFileSync(process.argv[3] ?? 'dist.zip', zip(files))
  console.log(`deploy: wrote ${process.argv[3] ?? 'dist.zip'} (${files.length} entries); nothing uploaded`)
  process.exit(0)
}
if (!TOKEN) fail('HOSTINGER_API_TOKEN is not set')

// --- 2. find the site (exactly one website with this exact domain) --------
const found = (await api('GET', `/api/hosting/v1/websites?domain=${DOMAIN}&per_page=100`)).data
  .filter((w) => w.domain === DOMAIN)
if (found.length !== 1) fail(`expected exactly one website named ${DOMAIN}, found ${found.length}`)
const username = found[0].username
console.log(`deploy: ${DOMAIN} (hosting account ${username}), ${files.length} entries, entry ${entry}`)

// --- 3. upload the zip into its public_html (TUS, as Hostinger documents) --
const archive = zip(files)
const archiveName = `deploy-${Date.now()}.zip`
const up = await api('POST', '/api/hosting/v1/files/upload-urls', { username, domain: DOMAIN })
const target = `${up.url.replace(/\/$/, '')}/${archiveName}?override=true`
const tus = { 'X-Auth': up.auth_key, 'X-Auth-Rest': up.rest_auth_key, 'Tus-Resumable': '1.0.0' }
let res = await fetch(target, { method: 'POST', headers: { ...tus, 'Upload-Length': String(archive.length), 'Upload-Offset': '0' } })
if (res.status !== 201) fail(`upload create -> ${res.status} ${(await res.text()).slice(0, 200)}`)
res = await fetch(target, {
  method: 'PATCH',
  headers: { ...tus, 'Content-Type': 'application/offset+octet-stream', 'Upload-Offset': '0' },
  body: archive,
})
if (res.status !== 204 || Number(res.headers.get('upload-offset')) !== archive.length) {
  fail(`upload -> ${res.status}, offset ${res.headers.get('upload-offset')} of ${archive.length}`)
}
console.log(`deploy: uploaded ${archiveName} (${archive.length} bytes)`)

// --- 4. deploy it: replaces the site's public_html with the zip's contents -
await api('POST', `/api/hosting/v1/accounts/${username}/websites/${DOMAIN}/deploy`, { archive_path: archiveName })
console.log('deploy: accepted by Hostinger, waiting for the new build to be served…')

// --- 5. wait until the live site serves this build's index.html -----------
// One good answer isn't enough: the site answers from several servers, and a
// stale one can keep serving the old index.html after a fresh one serves the new.
let streak = 0
for (let i = 0; i < 60 && streak < 5; i++) {
  await new Promise((r) => setTimeout(r, 3000))
  const live = await fetch(`https://${DOMAIN}/?deploy=${Date.now()}`).then((r) => r.text()).catch(() => '')
  streak = live.includes(entry) ? streak + 1 : 0
}
if (streak < 5) fail(`timed out: https://${DOMAIN} is not consistently serving ${entry} yet (check hPanel)`)
const js = await fetch(`https://${DOMAIN}/${entry}`)
if (!js.ok || !(await js.text()).includes(bundle.slice(0, 200))) fail(`live index.html is new but /${entry} isn't this build's bundle`)
console.log(`deploy: live — https://${DOMAIN} serves ${entry} (5 checks in a row)`)
