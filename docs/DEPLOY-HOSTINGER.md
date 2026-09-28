# Deploying the portal to Hostinger

The app builds to static files — same hosting pattern as your lead console.
Suggested subdomain: `dial.sedsolutions.online`.

## One-time

1. hPanel → Domains → Subdomains → create `dial` on `sedsolutions.online`;
   issue SSL for it (same as the console's steps 1).
2. Because the app uses client-side routing, add this `.htaccess` to the
   subdomain's `public_html`:

```
RewriteEngine On
RewriteCond %{HTTPS} off
RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^ index.html [L]
```

## Every deploy

```bash
cd app
npm run build
```

Upload everything inside `app/dist/` to the subdomain folder (hPanel File
Manager, FTP, or reuse the Hostinger API pattern from the scraper's
`deploy/upload.js`).

## After first deploy

- Supabase Dashboard → Authentication → URL Configuration: add
  `https://dial.sedsolutions.online` to the allowed redirect/site URLs.
- Log in from an agent PC and run the Phase 0 checklist against the hosted URL.
- When you later do the Smart Embed upgrade, this domain is the one to
  allow-list in the Smart Embed app config.
