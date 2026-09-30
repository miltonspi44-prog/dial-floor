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
| `app/` | The web portal (Vite + React + Supabase). Agents: Dial, Floor, Coaching. Manager: + Radar, Funnel, Lists, Handoffs, Playbook, Emails, Users. |
| `supabase/migrations/` | The database schema, queue engine and seeds (already applied to project `dial-floor`, id `fevjrcxmktjwbaozbngo`). |
| `supabase/functions/zoom-webhook/` | Edge function receiving Zoom `phone.*` webhooks (already deployed). |
| `supabase/functions/admin-users/` | Edge function behind the Users tab: creates, removes and resets logins (it holds the service key, so the browser never does). |
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

1. **Logins** — every login after the first manager's is made on the **Users**
   tab (below). The very first manager is made once in Supabase (Dashboard →
   Authentication → Add user, then in the SQL editor
   `update profiles set role = 'manager' where id = '<your-user-uuid>';`); the
   dialer's first manager already exists, so there is nothing to do here.
2. **Zoom app** — follow `docs/ZOOM-SETUP.md` (S2S OAuth app, webhook
   subscription pointing at the deployed function, secret into the function's
   env).
3. **Lead sync** — `cd sync && npm install`, copy `.env.example` → `.env`, fill
   the console password and the Supabase service key, then `npm run preview`
   (a read-only look at what would come in) and `npm run pull`.
   (No console access yet? Export a CSV from the console and
   `npm run import -- file.csv`.)
4. **Phase 0 checks** — run `docs/PHASE0-CHECKLIST.md` top to bottom (15
   minutes of real calls). It settles the AI-summary silence question and
   proves attribution.
5. **Deploy** — live at `https://dialer.sedsolutions.online`. Redeploy with
   `cd app && npm run deploy` (needs `HOSTINGER_API_TOKEN`); details in
   `docs/DEPLOY-HOSTINGER.md`.

## Daily operation

- Manager builds/assigns lists (Lists tab) — or agents pull from the general
  pool ordered by score. A list assigned to an agent is theirs alone; an
  unassigned list is shared by everyone.
- Agents: **D** dials · **S** skips (the lead sits out an hour) · non-connects
  are one key (**N/V/B/X**) · **C** opens the outcome popup (**R** there saves
  a referral) · **P** pauses · everything advances automatically. Mouse works
  everywhere too.
- A loaded lead is reserved for that agent, so two agents never call the same
  business. Reloading the page mid-call brings the open call back to log.
- Callbacks are entered on the lead's own clock. Unanswered, they come back an
  hour later, up to 3 tries; then they're marked missed and the lead rejoins
  the queue.
- A lead resting after "not interested" (or a language barrier) rejoins the
  queue on its own when the rest is over.
- The calling window is checked again at the moment of dialing, so a lead
  loaded just before its window closed can't be dialed after.
- The floor board shows each agent's day against the daily targets, and a tab
  that has gone quiet for 5 minutes as offline. Managers set the targets at the
  bottom of the **Funnel** tab.
- **Pacing** (Dial page): the strip shows today's dials, connects and handoffs
  against the targets, and pace: dials and talk minutes per active hour against
  the dial target spread over the shift (400 over 8 hours = 50 an hour). After
  each logged call a wrap-up countdown runs (20 s by default) before the next
  dial. It only paces: the dial is always the agent's own key press. **P**
  pauses with a reason (break, lunch, meeting, training, tech trouble, or other
  with a note): the lead on screen goes back to the queue, the floor board shows
  the reason, and pace leaves the time out. A pause survives a reload; Enter
  ends it. Managers set the shift length and the wrap-up next to the daily
  targets on the Funnel tab.
- **Referrals**: in the outcome popup, **R** saves "talk to my buddy who does
  gutters" (who, phone, trade, city and state, what they said). It becomes a
  lead marked **Warm referral**, first on the agent's own Referrals list, and
  the Dial page shows who sent us with an opener. When the number is already on
  file, that lead is linked instead (and comes back if it was parked). The agent
  still logs how the call ended. Do-not-call and handed-off numbers are refused.
  Referral leads live in the dialer only: they have no console id, so the sync
  leaves them alone.
- **Alerts** (Floor tab, managers): someone idle with a lead up, one call running
  long (or an outcome never logged), behind pace after their first hour, a
  callback overdue, a caller number whose connect rate collapsed. A chance given
  or a sale closed rings the bell for everyone (a banner on the Floor, a toast
  on the Dial page). Thresholds and switches are under **Alert settings** at the
  bottom of the Floor tab. **Notify me on this device** turns alerts into system
  notifications while the Floor tab is open (desktop browsers; on a phone, keep
  the Floor tab open in Chrome, or on an iPhone add the site to the home
  screen). **Bell on** plays a chime for wins.
- **Leaderboard** (Floor tab): today or this week, dials and conversations only
  (no outcome points to chase), with each agent's streak of working days at the
  dial target. Managers start a **power hour**: a race on dials or conversations
  for N minutes, optionally first to N; everyone sees it on the Floor and the
  Dial page. **Call of the day**: everyone has one vote a day for someone else's
  conversation, in Recent calls.
- The **Funnel** tab (managers) reads today, the last 7 or the last 30 days:
  dials → picked up → conversations → handoffs, then the same split by agent
  (per day, against the targets), by where the dial came from (callback, which
  list, general pool), by intent, and by the lead's local hour. Dials made
  before the funnel shipped show as "before tracking started" in the source table.
- **Emails** (managers): when an agent logs "Email requested", the address and
  their note on what the lead wants land in the queue. **Write email** fills a
  template in for that lead; **Open in mail app** hands it to your own mail
  client (or copy the subject and body), and **Mark sent** records which
  template went out. Nothing is sent by the system itself. Templates are edited
  on the same tab; placeholders like `{business}`, `{city}`, `{agent}` (who took
  the call) and `{my_name}` fill in automatically. The three starter templates
  are drafts: read them and make them yours before sending.
- **Users** (managers): everything about logins, with no trip to Supabase.
  - **Add user**: name, email, agent or manager. Leave the password blank and
    one is made up and shown once, with a button that copies the sign-in
    details to hand over; or type one (8+ characters). They can sign in
    right away.
  - Rename someone, change their login email, make them a manager or an agent,
    **reset password** (made up or typed, shown once), and **take off** the
    floor or bring them back. Someone off the floor is served nothing and
    can't dial (a call already open can still be logged).
  - **Hand back** returns someone's scheduled callbacks to the queue and
    shares their assigned lists with the whole team, in one click.
  - **Remove**: a login that never made a call or a record is deleted
    outright. Anyone with history is removed instead: they can't sign in and
    are off the floor, while every report keeps their calls. They're listed
    under **Removed**, and **restore** brings them back.
  - A manager can't remove, demote or take themselves off the floor, so there's
    always an active manager. Agents can't change their own role.
- **Radar** (managers): the first Dial or Radar page of each business day
  ranks the pool and deals every active agent their best leads as a "Radar"
  list (`radar_deal_per_agent`, 0 turns it off). Yesterday's radar lists close,
  so unworked leads get re-ranked. The cards:
  - callbacks due today;
  - leads that never answer: 4+ unanswered tries during their own business
    hours. That's the AI-receptionist list, and agents see the tries as their
    opener: "I've tried you N times during work hours. Your customers get the
    same.";
  - new no-website clusters (3+ in one trade and city this week);
  - open and upcoming seasons (from the lead-scraping plan, section 7; edit
    `seasons`);
  - what is connecting above average.

  Each card can build a shared list, which you assign on the Lists tab.

  **Recycle** (bottom of the Radar tab): leads the queue has parked come back
  when you say so: "already has a provider" leads (parked for good until now),
  resting leads after a no (before the rest ends), and resting leads whose
  season is open. Pick the pool and how long ago they were parked, see how many
  and who, and recycle them, as a shared list if you want them served before the
  pool. Provider leads come back tagged **Provider win-back**. Bringing them back
  automatically after N days is an option, off by default. Do-not-call and
  handed-off leads never come back.
- **Best time to call** (Funnel tab): the pickup rate by trade and by the lead's
  own hour, learned from the call log. Thin data is pulled toward the trade's
  all-day rate until an hour has 30+ dials, and nothing shows until the floor
  has 1,000 logged dials. Then the Dial page shows the lead's trade's best
  hours, and **Use it in the queue** (off by default) leans the general pool
  toward trades in a good hour: score × 0.7–1.3, one factor among several.
  Lists and callbacks keep their own order.
- **Coaching**: every agent sees their own digest for today or the week, against
  the floor and the targets. It shows two things going well, one thing to work
  on with a concrete move, their best hour, and a counter to try for each
  objection they hear. Managers pick any agent and also get **floor insights**:
  - how often each objection comes up and how those calls end;
  - where calls end by talk time;
  - how conversations end;
  - the words in notes of calls kept alive vs lost.

  Gatekeeper calls are left out.

  **Weekly scorecard** (the third period on the Coaching tab): four business
  weeks of an agent's funnel next to the floor's average agent, with a trend
  line, this week's handoffs, the longest conversations that still ended in a
  no, and (for managers) calls saved to the library. **Print** makes a copy for
  the weekly review.
- **Playbook** (managers):
  - **Battlecards**: edit the objections and counters agents tap on a call.
    Counters with 5+ uses are ranked on the Dial page by the calls they kept
    alive (a callback, an email or a handoff).
  - **A/B lab**: opener tests, one at a time, behind a switch that is off by
    default. Each lead always gets the same opener, the dial records which one,
    and results say "could still be chance" until there's enough data.
  - **Library**: managers only; talk tracks plus calls saved from the Floor's
    recent calls or the Handoffs ledger.
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
| `spam_alert_drop_pts` | `10` | A number whose connect rate drops this many points week over week is flagged on the floor board |
| `missed_call_threshold` | `4` | Unanswered tries during a lead's business hours that put it on the never-answers (AI-receptionist) list |
| `business_hours` | `{"start":"08:00","end":"17:00","days":[1,2,3,4,5]}` | A lead's business hours on its own clock (days 1 = Monday … 7 = Sunday), for the never-answers count |
| `radar_deal_per_agent` | `100` | Leads each active agent is dealt every morning as their Radar list; `0` turns the morning lists off (also on the Radar tab) |
| `seasons` | trades and months from the lead-scraping plan §7 | Seasonal windows: `[{"label","keys":[category keys],"months":[1-12],"states":[optional]}]`; in-season leads get the "Seasonal window open" intent |
| `wrapup_seconds` | `20` | Wrap-up countdown after each logged call, `0` = off; it never dials by itself (also on the Funnel tab) |
| `shift_hours` | `8` | The shift the daily dial target is spread over for pace (also on the Funnel tab) |
| `alerts` | `{"idle_minutes":10,"long_call_minutes":15,"pace_pct":80,"callback_overdue_minutes":15,"celebrate":true,"spam":true}` | Floor alerts; `0` or `false` turns one off (also on the Floor tab) |
| `recycle_provider_days` | `0` | Bring "has a provider" leads back on their own after this many days; `0` = only when a manager recycles them (also on the Radar tab) |
| `best_time` | `{"days":90,"min_dials":30,"min_total":1000,"prior":20,"use_in_queue":false}` | The best-time model: its window, the dials an hour needs, the dials the floor needs, how hard thin data leans on the average, and the queue switch (also on the Funnel tab) |
| `ab_lab_enabled` | `false` | The A/B lab's switch (also on the Playbook tab): off, agents see no test openers |
| `ai_summaries_enabled` | `false` | Leave off: this Zoom plan has no AI Companion call summaries, so calls are logged metadata-only (outcome, talk time, the agent's note). Turn on only if summaries are added (docs/ZOOM-SETUP.md §4) |
