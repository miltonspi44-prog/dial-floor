# Phase 0 checklist — 15 minutes of real calls before the floor goes live

Run top to bottom once Zoom setup (`ZOOM-SETUP.md`) is done. Each item says
what "pass" looks like.

## 1 · Webhook spine (2 min)
Dial your own cell from the Zoom desktop app, let it ring out, hang up.
**Pass:** a `phone.caller_ended` row in `webhook_events` (Supabase table
editor), `processed = true`.

## 2 · Attribution proof (5 min)
Sign into the portal as an agent, make sure one test lead exists (CSV import
one row with your own cell number), press **D**.
**Pass:** Zoom desktop pops dialing; after hangup the `attempts` row has
`matched = true`, `number_used` filled, and the right duration. Repeat from the
second PC on the same Zoom login at the same time — both attempts must match to
the right agent. (You already know simultaneous calls work — this proves the
data side agrees.)
While a call is up, the Floor tab on the other PC must show that agent as
**dialing** (not offline). Back on the Dial screen, press **S** on a lead
before dialing: a different lead must load. Log a test callback for tomorrow
10:00 — the form shows the lead's own local time, and the manager's Floor tab
lists it at the same moment in the viewer's timezone (a 10:00 New York callback
shows as 7:00 AM on a Pacific PC).

## 3 · The AI-summary silence test (5 min) — decides Fork 1-B
Recording policies OFF account-wide (they already are). Admin → Zoom Phone →
Call summary with AI → find **"Play a prompt to call participant when call
summary has started"** and turn it **off** if present.
Call your own cell from Zoom, trigger the summary (or have Automatic call
summary on for the test user), and LISTEN on the cell.
- **Silent** → Fork 1-B is a go whenever you want it:
  `update app_settings set value='true' where key='ai_summaries_enabled';`
- **Anything audible** → stay on metadata-only (the default), exactly per your
  fork note. Nothing else changes.
Note: with the prompt off, any disclosure duty for AI transcription shifts to
you — the one question worth an hour of counsel if you enable this.

## 4 · Phone API sanity (1 min)
From the Zoom app's credentials, any REST client:
`GET https://api.zoom.us/v2/phone/users` with an S2S token.
**Pass:** 200 with your users. (401/account-type error → the one known
contingency: one paid Workplace seat on the admin account.)

## 5 · Calling-window guard (1 min)
In the portal before 8am / after 8:30pm lead-local time, **Load next** should
skip leads whose local window is closed (the empty-state hint says so).
Quick check: set `call_window` in `app_settings` to a narrow range, confirm the
queue refuses, set it back.

## 6 · Smart Embed spike (1 hour, later — Fork 2's v1.1)
When you're ready to upgrade from URI-launch: Marketplace → install **Zoom
Phone Smart Embed**, allow-list the portal's domain, enable "Automatically Call
From Third Party Apps", and test the embed on both PCs signed into one Zoom
account (the unproven part). If it passes, the dialer moves inline —
**you asked to be reminded of this once the floor is live.**
