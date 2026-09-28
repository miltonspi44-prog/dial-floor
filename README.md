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
| `supabase/tests/` | Queue-engine tests: `supabase/tests/run.sh` applies every migration to a throwaway local Postgres and checks the dialing rules. |
| `sync/` | Node worker: pulls dialable leads from the hosted console, writes terminal statuses back. Also a CSV importer. |
| `docs/` | Zoom setup, the Phase 0 checklist, Hostinger deploy. |

## Run the app locally

```bash
cd app
npm install
npm run dev
```

Copy `app/.env.example` to `app/.env.local` first: it holds the dial-floor
project's public URL and publishable key.

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
   hosting as a static site at `https://dialer.sedsolutions.online`.

## Daily operation

- Manager builds/assigns lists (Lists tab) — or agents pull from the general
  pool ordered by score. A list assigned to an agent is theirs alone; an
  unassigned list is shared by everyone.
- Agents: **D** dials · **S** skips (the lead sits out an hour) · non-connects
  are one key (**N/V/B/X**) · **C** opens the outcome popup · everything
  advances automatically. Mouse works everywhere too.
- A loaded lead is reserved for that agent, so two agents never call the same
  business. Reloading the page mid-call brings the open call back to log.
- Callbacks are entered on the lead's own clock. Unanswered, they come back an
  hour later, up to 3 tries; then they're marked missed and the lead rejoins
  the queue.
- The sync loop (`cd sync && npm run loop`) keeps leads flowing in and statuses
  flowing back. Run it on any always-on PC (Task Scheduler recipe in the
  console's own DEPLOY.md works the same here).

## Settings

Stored in `app_settings`; change them in the Supabase SQL editor, e.g.
`update app_settings set value = '90' where key = 'min_redial_minutes';`

| Key | Default | Meaning |
|---|---|---|
| `call_window` | `{"start":"08:00","end":"20:30"}` | Dialable hours, in each lead's local time |
| `max_attempts_per_day` | `2` | Dials per lead per business day (callbacks excepted) |
| `min_redial_minutes` | `120` | Gap before the same lead is served again (`0` allows back-to-back) |
| `reserve_minutes` | `10` | How long a loaded lead stays with the agent who loaded it |
| `skip_rest_minutes` | `60` | How long a skipped lead sits out |
| `callback_retry_minutes` | `60` | Unanswered callback: try again after this long |
| `callback_max_tries` | `3` | Then the callback is marked missed |
| `rest_soft_days` / `rest_hard_days` | `10` / `20` | Rest after "not interested" soft / hard |
| `reclaim_minutes` | `30` | An abandoned in-progress lead is reclaimed after this long |
| `allow_general_pool` | `true` | Serve the general pool once lists and callbacks are empty |
| `business_tz` | `"America/Los_Angeles"` | Timezone of the business day behind "today" counts and daily caps |
| `ai_summaries_enabled` | `false` | Fork 1-B: attach Zoom AI summaries (only after the silence test) |
