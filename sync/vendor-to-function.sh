#!/usr/bin/env bash
# Copies the sync passes into the edge function's folder for deploy.
# sync/ is the source of truth; run this after any change there, before
# deploying supabase/functions/sync-console. The copies are committed so a
# reviewer sees exactly what ships.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$here/../supabase/functions/sync-console/vendor"
mkdir -p "$dest"
# the Node-only self-run bootstrap stays out of the bundle: the guard around it
# is false under Deno, but a bundler may still chase the import's string literal
sed -e 's#./lib/#./#g' -e '/client-node/d' "$here/pull-leads.mjs"  > "$dest/pull-leads.mjs"
sed -e 's#./lib/#./#g' -e '/client-node/d' "$here/push-status.mjs" > "$dest/push-status.mjs"
cp "$here/lib/console.mjs" "$dest/console.mjs"
cp "$here/lib/supa.mjs"    "$dest/supa.mjs"
cp "$here/lib/map.mjs"     "$dest/map.mjs"
cp "$here/lib/env.mjs"     "$dest/env.mjs"
echo "vendored $(ls "$dest" | wc -l) files into supabase/functions/sync-console/vendor/"
