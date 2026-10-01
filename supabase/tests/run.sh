#!/usr/bin/env bash
# Queue-engine tests: applies supabase/migrations to a throwaway Postgres (with
# Supabase's auth pieces stubbed) and runs queue_test.sql against it.
# Needs Postgres 15+ server binaries (initdb, pg_ctl, psql); set PG_BIN if they
# aren't on PATH.   Usage: supabase/tests/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="${PG_BIN:-}"
if [ -z "$bin" ]; then
  if command -v pg_ctl >/dev/null 2>&1; then bin="$(dirname "$(command -v pg_ctl)")"
  else bin="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"; fi
fi
[ -x "$bin/pg_ctl" ] || { echo "Postgres server binaries not found; set PG_BIN" >&2; exit 2; }

# Postgres refuses to run as root: hand the whole run to the postgres user.
if [ "$(id -u)" = 0 ]; then
  args=""; for a in "$@"; do args="$args '$a'"; done
  exec su postgres -s /bin/bash -c "PG_BIN='$bin' PG_PORT='${PG_PORT:-}' '$here/run.sh'$args"
fi

work="$(mktemp -d)"
port="${PG_PORT:-54329}"
trap '"$bin/pg_ctl" -D "$work/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

"$bin/initdb" -D "$work/data" -U postgres --auth=trust -E UTF8 >/dev/null
"$bin/pg_ctl" -D "$work/data" -o "-p $port -k $work -c listen_addresses=" -l "$work/log" -w start >/dev/null

psql=("$bin/psql" -h "$work" -p "$port" -U postgres -X -q -v ON_ERROR_STOP=1)
"${psql[@]}" -d postgres -c "create database dialfloor" -c "alter database dialfloor set timezone to 'UTC'"
"${psql[@]}" -d dialfloor -f "$here/supabase_stub.sql"
for f in "$here"/../migrations/*.sql; do
  "${psql[@]}" -d dialfloor -f "$f" >/dev/null
done
"${psql[@]}" -d dialfloor -f "$here/queue_test.sql"

# Extra groups live one file per topic in groups/, so separate work can add tests
# without editing the same file. Pass a file to run only that one.
if [ "$#" -gt 0 ]; then
  for f in "$@"; do "${psql[@]}" -d dialfloor -f "$f"; done
else
  for f in "$here"/groups/*.sql; do [ -e "$f" ] || continue; "${psql[@]}" -d dialfloor -f "$f"; done
fi
echo 'all tests passed'
