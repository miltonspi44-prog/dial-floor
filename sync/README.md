# The lead sync worker

This is the small Node program that keeps the dialer and the hosted lead console in
step. It does two jobs, on two clocks:

- **Pull** (every 15 minutes) — brings dialable leads from the console into the
  dialer, tells the console those leads are taken so nothing exports them anywhere
  else again, and then goes back over the leads we already hold to pick up anything
  the console has changed about them: a corrected phone number, a lead marked
  do-not-call or wrong-number, a lead that is no longer there.
- **Push** (every minute) — sends the outcome of calls back to the console
  (do-not-call, sold, not interested, wrong number, callback, long term).

It never touches the scraper's own `leads.db`. Everything goes through the console's
`api.php`, which is the only writer that file has.

## Setting it up

```bash
cd sync
npm install
cp .env.example .env      # then fill it in
```

`.env` holds four things: the console's address and password, and the dialer's
Supabase URL and service key. It is secrets, so it stays out of git — `.gitignore`
already covers it. The console password is the same one the owner signs in with.

Then look before you leap:

```bash
npm run preview           # reads one page, writes nothing anywhere
npm run pull              # one pull
npm run push              # one push
npm run loop              # the long-running worker: pull every 15 min, push every minute
```

`PULL_INTERVAL_MIN` in `.env` changes the pull clock if 15 minutes is wrong.
`CONSOLE_TIMEOUT_MS` changes how long one console request may take before it counts as
no answer; the default is two minutes, which is generous because a thousand-row page
off shared hosting is genuinely slow.

One thing to do once, in the dialing DB: apply migration
`supabase/migrations/0025_writeback_failures.sql`. Without it the push works and
nothing is lost, but it cannot record why the console refused a row or ever stop
trying one it will never accept, and it says so in every run's detail until it is
applied.

## Leaving it running on the owner's PC (Task Scheduler)

1. Task Scheduler → **Create Task** (not Basic Task), name it `dial-floor sync`.
2. General → **Run whether user is logged on or not**, and tick **Run with highest
   privileges** only if the PC needs it.
3. Triggers → **At startup**, and tick **Repeat task every 5 minutes** →
   *for a duration of* **Indefinitely**, with **Stop the existing task** unticked.
   The worker runs forever on its own, so the repeat only matters if it has stopped.
4. Actions → **Start a program**:
   - Program: `C:\Program Files\nodejs\node.exe`
   - Arguments: `--env-file=.env run.mjs`
   - Start in: the full path to this `sync` folder.
5. Settings → tick **If the task fails, restart every 1 minute**, up to 3 times.

The worker deliberately exits with a failure code in one case only: the console has
refused the password. That is the one thing nobody but a person can fix, and it shows
up in Task Scheduler's Last Run Result as a non-zero code.

## Reading the log

Every run is also written to the `sync_runs` table, which the portal shows.

- `pull_leads: 7` — seven leads' worth of news came in. **`0` means nothing came in**,
  which is the normal reading most of the day. It counts real changes, not rows
  written: the pull re-reads every lead we hold each time, so counting writes would
  read like the whole table every quarter of an hour and tell the owner nothing.
- `push_status: 3` — three call outcomes reached the console.
- `4 status(es) waiting for the lead console, the oldest for 3 minutes.` — printed on
  every push, and the first line of the run's detail. This is the number to watch:
  `push_status: 0` on its own means either a quiet minute or a dead write-back, and
  those read the same. A minute or two of waiting is normal. Anything more is not, and
  past two hours the same line ends `— far too long` and the push prints the paragraph
  below about what it costs.
- `Nothing is waiting to go to the lead console.` — the whole queue is empty, which is
  what a genuinely quiet minute looks like.
- `pull_leads skipped: the sync before it is still running` — a pull that outlasted
  its own fifteen minutes. Nothing is lost; the next tick picks it up.
- The run's **detail** is where anything worth reading later goes: leads the console
  no longer lists, numbers it told us to stop calling, rows it holds with no phone
  number on them, statuses it would not take.

## When something is wrong

**"The lead console would not accept the sync password."** The loop stops, on
purpose, and the process exits with a failure. The console locks sign-ins after about
ten wrong tries in fifteen minutes and that lock applies to the owner's own sign-in
too, so the worker never tries a password the console has already refused. Fix
`CONSOLE_PASSWORD` in `.env` and start it again.

**"The lead console has locked sign-ins for fifteen minutes."** Someone — usually a
person mistyping at the console itself — has used up the ten tries. This needs
nothing from you: the lock counts tries from this connection and clears itself
fifteen minutes after the last one, and asking again while it is on does not extend
it. The worker leaves it alone for sixteen minutes and then carries on by itself.

**"signed in, but the console did not keep the session."** The password is fine; the
console is not holding on to the session it gave us, which on shared hosting usually
means its session folder is full or not writable. The worker keeps trying on its own
clock, because this normally clears up when the host is tidied, and no password
change would help it.

**"The lead console has not taken N status change(s) from the dialer."** The thing to
act on. Those leads are still dialable in the console, and the scraper can export
their numbers again — including the ones somebody asked never to be called. It is
printed on every push once the oldest has waited more than two hours. Either the
console is down (check it opens, and that its database is working) or one lead's note
is something its database will not store, in which case the lines above it name the
same lead over and over: shorten that note, or take the emoji out of it, in the
dialer. The statuses are not lost while this is showing; nothing is thrown away.

**"the console did not answer at all" / timeouts.** The host is down or very slow.
Everything waits and goes out on the next run. When a status write gets no answer at
all, the push asks the console one cheap question before concluding anything: if the
console answers, the silence was about that one row — shared hosting cuts a request
whose body its firewall dislikes — and the push carries straight on down the rest of
the batch. If the console does not answer that either, the host really is gone and the
run stops there and keeps the rest.

**"the lead console would not take console lead 404"** The console read the status
and said no — usually that lead has been deleted over there. There is no point
sending it again, so the dialer stops asking and writes the reason into the lead's
note, where a manager can read it.

**"the console would not take console lead 505 this time"** Something about that one
row upsets the console's own database — most often an emoji in a note against an
older text column. The rest of the batch still goes out, every row of it, every run.
That row is kept and tried again every minute.

A status is only ever written off unsent when the console has shown, in the same run,
that it is taking other statuses and has gone on refusing that one for a day. Time on
its own is never enough: when the console's own database is down, every row fails for
as long as that lasts, and writing a do-not-call off on the strength of it would put
the number back into circulation with nobody any the wiser. So a day-long outage
costs nothing but a day of waiting — everything goes out when the host comes back.

The flip side is that a row the console will never accept is retried for ever if it is
the only thing in the queue, because there is nothing else for the console to accept
and so no proof it is the row. That is deliberate: it costs one request a minute, and
the waiting line above is what tells the owner to go and look.

**"lead(s) we hold were not in the console's list this time"** They may have been
deleted in the console, or the list may simply have moved under us while we read it
(the console counts and lists in two queries and orders by a score the scraper keeps
changing). Nothing is deleted here on the strength of that — the dialer only reports
it.

**"The console lists N row(s) with no phone number anyone could dial"** The console's
own row for that lead has no usable number, so nothing was copied from it. If the
console has told us to stop calling that lead, that still happens: the number we hold
goes on the suppression list anyway. Fix the number in the console and it comes in on
the next sync.

## The CSV importer

For a console export, before the API sync is set up at all:

```bash
npm run import -- path\to\leads-2026-09-23.csv --mark-contacted
```

One of the two flags is required, because guessing wrong either hides leads nobody
has called or hands the same leads out twice:

- `--mark-contacted` — the normal choice for a file that came out of the console.
  The console is told these leads are taken, straight away if there is a console
  password in `.env`. If there is not, the import says so and prints the one command
  that does it later:
  `npm run pull -- --marks-only`.
- `--leave-in-console` — the console keeps offering them. Only for a file that did
  not come from the console, or for a trial run.

A row with no `id` column is left out: there would be nothing to recognise it by
later, so every re-import would add another copy of it. A row whose phone number is
not a 10-digit US number is left out too, and both are counted in what the import
prints.

## The files

| File | What it is |
|---|---|
| `run.mjs` | The long-running loop: one sync at a time, two clocks. |
| `pull-leads.mjs` | The pull, the `contacted` marks, and the refresh pass over leads we already hold. |
| `push-status.mjs` | The call outcomes going back to the console. |
| `csv-import.mjs` | The CSV fallback. |
| `preview.mjs` | Read-only look at what a pull would bring in. |
| `lib/console.mjs` | The console client: session, lockout rules, paging. |
| `lib/supa.mjs` | Everything written to the dialing DB, and which leads need recomputing. |
| `lib/map.mjs` | Console rows → dialer rows, and what counts as a real change. |
