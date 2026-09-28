# Dial Floor

The cold-calling system for the agency: click-to-dial through Zoom Phone, full
attempt logging, lead states with permanent DNC, daily lists, callbacks, a live
floor board, and a handoff ledger. Built from the approved
[Build Plan](https://claude.ai/artifact/Kxv3tUaHNtDmWcZ4oJok5L) (which was built
from the [Blueprint](https://claude.ai/artifact/8DVZeadTZWZwf9L4U1A5AZ) picks).

**Hard rules baked in:** no call recordings ever · SMS lives outside this system
· interested/closed leads exit to the other dashboard via the handoff ledger +
internal DNC · numbers are assigned manually in Zoom (this system only observes
them) · the scraper project is never modified.

## Parts

| Folder | What it is |
|---|---|
| `app/` | The web portal (Vite + React + Supabase). Agents: Dial + Floor. Manager: + Lists, Handoffs, Emails. |
| `supabase/migrations/` | The database schema, queue engine and seeds (already applied to project `dial-floor`, id `fevjrcxmktjwbaozbngo`). |
| `supabase/functions/zoom-webhook/` | Edge function receiving Zoom `phone.*` webhooks (already deployed). |
| `sync/` | Node worker: pulls dialable leads from the hosted console, writes terminal statuses back. Also a CSV importer. |
| `docs/` | Zoom setup, the Phase 0 checklist, Hostinger deploy. |

## Run the app locally

```bash
cd app
npm install
npm run dev
```

`app/.env.local` is already pointed at the dial-floor Supabase project.

## First-time setup (one sitting, ~1 hour)

1. **Create logins** — Supabase Dashboard → Authentication → Add user (email +
   password) for each agent and yourself. Then promote yourself:
   `update profiles set role = 'manager' where id = '<your-user-uuid>';`
   (SQL editor). Agents default to the agent role.
2. **Zoom app** — follow `docs/ZOOM-SETUP.md` (S2S OAuth app, webhook
   subscription pointing at the deployed function, secret into the function's
   env).
3. **Lead sync** — `cd sync && npm install`, copy `.env.example` → `.env`, fill
   the console password and the Supabase service key, then `npm run pull`.
   (No console access yet? Export a CSV from the console and
   `npm run import -- file.csv`.)
4. **Phase 0 checks** — run `docs/PHASE0-CHECKLIST.md` top to bottom (15
   minutes of real calls). It settles the AI-summary silence question and
   proves attribution.
5. **Deploy** — `docs/DEPLOY-HOSTINGER.md` puts the built app on your Hostinger
   hosting as a static site.

## Daily operation

- Manager builds/assigns lists (Lists tab) — or agents pull from the general
  pool ordered by score.
- Agents: **D** dials · non-connects are one key (**N/V/B/X**) · **C** opens
  the outcome popup · everything advances automatically. Mouse works
  everywhere too.
- The sync loop (`cd sync && npm run loop`) keeps leads flowing in and statuses
  flowing back. Run it on any always-on PC (Task Scheduler recipe in the
  console's own DEPLOY.md works the same here).
