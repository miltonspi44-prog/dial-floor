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

Scale note: one pull walks the console's whole list (3 pages today). If the
console ever grows past what fits in an edge function's clock (~150s), move the
pull back to the PC loop or page it across invocations.
