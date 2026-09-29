# Deploying the portal to Hostinger

The app builds to static files. It is live at `https://dialer.sedsolutions.online`,
which is its own website in hPanel (hosting account `u461699018`, not a folder
of `sedsolutions.online`), with Hostinger's free SSL and HTTPS redirect on.

The site only holds the static app. The database (`supabase/migrations/`) and
the `zoom-webhook` function deploy to Supabase separately.

## Every deploy

```bash
cd app
cp .env.example .env.local   # first time only: the live project's public URL + key
npm run deploy               # needs HOSTINGER_API_TOKEN in the environment
```

`npm run deploy` builds, then `scripts/deploy-hostinger.mjs`:

1. refuses to run if the build is incomplete or has no Supabase URL baked in;
2. finds the one website named `dialer.sedsolutions.online` through the
   Hostinger API;
3. zips `dist/` and uploads it into that site's `public_html`;
4. asks Hostinger to deploy the zip, which **replaces everything** in that
   site's `public_html` (the zip itself included);
5. waits until the live site serves the new build.

The target domain is hard-coded: the same Hostinger login also holds
`sedsolutions.online`, the lead console and client sites, and none of them may
ever be a deploy target. `node scripts/deploy-hostinger.mjs --zip-only out.zip`
writes the archive without uploading anything.

The API token comes from hPanel → your profile → API. Set it for the session:
PowerShell `$env:HOSTINGER_API_TOKEN="…"`, bash `export HOSTINGER_API_TOKEN=…`;
in a Claude cloud session, add it to the environment's variables. Never commit it.

`app/public/.htaccess` is copied into every build: it forces HTTPS, sends the
app's routes (`/dial`, `/floor`, …) to `index.html`, and stops browsers caching
`index.html`, so agents pick up a redeploy on their next page load.

## Without the API

hPanel → File Manager → the site's `public_html`: upload a zip of `dist/`'s
contents (not the `dist` folder itself) and Extract it there, so `index.html`
and the hidden `.htaccess` sit directly in `public_html`.

## After first deploy

- Optional: Supabase Dashboard → Authentication → URL Configuration → set the
  Site URL to `https://dialer.sedsolutions.online`. Password sign-in works
  without it; invite and password-reset emails link there.
- Log in from an agent PC and run the Phase 0 checklist against the hosted URL.
- When you later do the Smart Embed upgrade, this domain is the one to
  allow-list in the Smart Embed app config.
