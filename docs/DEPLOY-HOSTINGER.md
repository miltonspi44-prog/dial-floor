# Deploying the portal to Hostinger

The app builds to static files — same hosting pattern as your lead console.
Address: `https://dialer.sedsolutions.online`.

The site only holds the static app. The database (`supabase/migrations/`) and
the `zoom-webhook` function deploy to Supabase separately.

## One-time

1. hPanel → Websites → `sedsolutions.online` → Domains → Subdomains: create
   `dialer` (the folder hPanel suggests is fine).
2. hPanel → Security → SSL: make sure `dialer.sedsolutions.online` has a
   certificate; install the free one if it isn't listed. The site forces HTTPS,
   so it won't load until the certificate is active.
3. Optional: Supabase Dashboard → Authentication → URL Configuration → set the
   Site URL to `https://dialer.sedsolutions.online`. Password sign-in works
   without it; invite and password-reset emails link there.

## Every deploy

```bash
cd app
cp .env.example .env.local   # first time only: the live project's public URL + key
npm run build
```

Upload everything inside `app/dist/` into the subdomain's folder, replacing
what's there — including the hidden `.htaccess` (hPanel → File Manager: upload
a zip of `dist/`'s contents, then Extract; or FTP, or the Hostinger API pattern
from the scraper's `deploy/upload.js`). `index.html` and `.htaccess` must sit
directly in the subdomain folder, not in a `dist/` subfolder.

`app/public/.htaccess` is copied into every build: it forces HTTPS, sends the
app's routes (`/dial`, `/floor`, …) to `index.html`, and stops browsers caching
`index.html`, so agents pick up a redeploy on their next page load.

## Scripted deploys (optional)

Hostinger's API can create the subdomain and deploy a static zip
(`POST /api/hosting/v1/accounts/{username}/websites/{domain}/subdomains`,
`POST /api/hosting/v1/files/upload-urls` + a TUS upload, then
`POST …/websites/{domain}/deploy`). To have a Claude session deploy for you,
create an API token in hPanel (your profile → API) and add it to the Claude
environment as `HOSTINGER_API_TOKEN` — never to the repo. The deploy endpoint
overwrites the target website's contents, so it must only ever target the
`dialer` subdomain, never `sedsolutions.online` or the console.

## After first deploy

- Log in from an agent PC and run the Phase 0 checklist against the hosted URL.
- When you later do the Smart Embed upgrade, this domain is the one to
  allow-list in the Smart Embed app config.
