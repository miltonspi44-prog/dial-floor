# Zoom setup (one-time, ~20 minutes, you do this part)

Everything here happens in the Zoom web portal / Marketplace with your admin
login. The system needs no Zoom code changes — just an app registration and two
admin toggles.

## 1 · Server-to-Server OAuth app

1. Go to https://marketplace.zoom.us → Develop → **Build App** → **Server-to-Server OAuth**.
2. Name: `Dial Floor`. Note the three credentials: **Account ID**, **Client ID**, **Client Secret**.
3. **Scopes** — add (granular; if a granular scope is missing from the picker, add the
   classic `phone:read:admin` instead — that's Zoom's documented workaround):
   - Call history read (e.g. `phone:read:list_call_logs:admin`, `phone:read:call_log:admin`)
   - Users read (`phone:read:list_users:admin` or classic `phone:read:admin`)
   - AI call summary read: `phone:read:ai_call_summary:admin` (search "ai_call_summary";
     classic `phone:read:admin` covers it if absent). Without it the summaries can't be fetched.
4. Activate the app.

## 2 · Webhook (Event Subscription)

1. In the same app → **Features → Event Subscriptions** → add subscription.
2. Event notification endpoint URL:
   `https://fevjrcxmktjwbaozbngo.supabase.co/functions/v1/zoom-webhook`
3. Add events (under Phone):
   - **Caller ended** (`phone.caller_ended`)
   - **Callee ended** (`phone.callee_ended`)
   - **Call Summary Changed** (`phone.ai_call_summary_changed`; the Marketplace lists it
     without "AI" in the name). It only names the summary: the webhook fetches the text
     from the Phone API with the three credentials below.
4. Copy the subscription's **Secret Token**.
5. Put the secret into the edge function: Supabase Dashboard → project
   `dial-floor` → Edge Functions → `zoom-webhook` → Secrets → add
   `ZOOM_WEBHOOK_SECRET_TOKEN` = the secret. Add `ZOOM_ACCOUNT_ID`,
   `ZOOM_CLIENT_ID`, `ZOOM_CLIENT_SECRET` too (the S2S app's three credentials):
   the webhook uses them to fetch AI call summaries. If they're missing or
   wrong, the summary event is kept in `webhook_events` with the reason in
   `error` (e.g. `Zoom token: HTTP 401 …`).
6. Back in Zoom, click **Validate** — it must turn green (the function answers
   Zoom's challenge). Save.

## 3 · Make a test call

Dial any number from the Zoom desktop app. Then check: Supabase → Table editor
→ `webhook_events` — a `phone.caller_ended` row should appear within seconds.
That's the data spine working.

## 4 · AI Companion (only when you're ready for Fork 1-B)

**Not available on the current Zoom plan (2026-09-29)**, so this section is
parked: `ai_summaries_enabled` stays `false`, the S2S credentials in §2 aren't
needed, and the portal shows no summary column. The webhook code for it stays
in place, idle, in case summaries are added to the plan later.

Admin portal → Account Settings → **Zoom Phone** → *Call summary with AI*:

- The critical toggle: **"Play a prompt to call participant when call summary
  has started."** Your requirement is that the customer hears NOTHING — run the
  silence test in `PHASE0-CHECKLIST.md` before enabling summaries for agents.
- Recording stays off everywhere; summaries don't need it.
- `ai_summaries_enabled` (app_settings) decides whether the webhook keeps them:
  `update app_settings set value = 'true' where key = 'ai_summaries_enabled';`
  It doesn't change what the caller hears; that's Zoom's prompt toggle above.
  To go back to metadata-only: set it to `'false'`. No code changes either way.
- Where they show: the Floor page's **Recent calls** table, and under the call
  in the lead's **Previous touches** on the Dial page. Zoom produces a summary
  a few minutes after the call ends. The portal shows it only for calls placed
  with its Dial button: a call dialed straight from Zoom has no attempt to attach it to.

## Notes

- The webhook function verifies Zoom's HMAC signature on every event and
  ignores duplicates. Until the secret is set it answers `503` to everything,
  Zoom's validation included — set the secret before clicking Validate.
- Your account shape (free Workplace base + paid Phone licenses): S2S app
  creation shows no paid gate in Zoom's docs; if the Phone API unexpectedly
  refuses (`GET /phone/users` erroring about account type), the fix is one paid
  Workplace seat (~$14/mo) on the admin account.
