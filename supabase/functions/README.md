# Edge functions — how these deploy (focus item 51)

The settings below are part of the system. A redeploy that forgets one of them
silently breaks the function it belongs to, so they live here rather than in
anybody's memory.

| Function       | verify_jwt | Why |
|----------------|-----------|-----|
| `zoom-webhook` | **false** | Zoom signs its deliveries with `ZOOM_WEBHOOK_SECRET_TOKEN`; it cannot carry a Supabase JWT. The function checks the signature (constant-time) and a freshness window itself. |
| `admin-users`  | **true**  | Only a signed-in manager may call it; it re-checks the caller's profile server-side on top. |
| `sync-console` | **false** | pg_cron calls it (migration 0034) with the `x-cron-secret` header; cron carries no JWT. The secret is the whole gate. |

Deploying with the wrong flag is the failure mode item 51 was about: a default
`verify_jwt = true` redeploy of `zoom-webhook` makes Zoom's deliveries bounce
with 401 and every call outcome silently stops arriving.

## Secrets (Dashboard → Edge Functions → *function* → Secrets)

- `zoom-webhook`: `ZOOM_WEBHOOK_SECRET_TOKEN` (from the Zoom app's Feature page)
- `sync-console`: `CONSOLE_PASSWORD` (the lead console's password),
  `CRON_SECRET` (any long random string — the same value goes into Vault as
  `sync_cron_secret`, which is where 0034's cron jobs read it), and
  `CONSOLE_URL` only if the console ever moves.
- `admin-users`: none beyond the built-ins.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` arrive built in on every function.

## sync-console's code

`sync/` in the repo root is the one source of truth for the sync logic; the PC
loop (`npm run loop`) and this function run the same files. Before deploying
`sync-console`, run `bash sync/vendor-to-function.sh` — it copies the current
passes into `supabase/functions/sync-console/vendor/`, which is what the bundle
can see. The copies are committed so a diff shows exactly what ships.
`index.ts` and `refusal.mjs` are the function's own files, not copies; the
deploy carries all eight (both of them plus the six in `vendor/`).

What the hosted run adds on top of the PC loop:
- A push with nothing waiting answers `idle` without logging a run (cron asks
  every minute; 1,440 empty rows a day would say nothing).
- A password the console refuses is remembered across instances: the failed
  run's detail carries a fingerprint (an HMAC keyed with `CRON_SECRET`), and
  every instance checks for it before signing in. The same password is tried
  again at most once a day; a changed `CONSOLE_PASSWORD` is tried at once.
- Logs are trimmed nightly by migration 0035: seven days of pg_cron's run
  history, 90 days of `sync_runs`.

Scale note: one pull walks the console's whole list (4 pages at ~3,000 leads).
The first hosted pull, a four-day catch-up that brought in 602 new leads and
refreshed 2,247 more, took 89 s; the edge function's clock is 150 s. If pulls
ever approach that, move the pull back to the PC loop or page it across
invocations.
