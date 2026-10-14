-- Dial Floor · 0034 the sync runs itself (items 48–49)
-- Two cron jobs call the sync-console edge function: pushes every minute, pulls
-- every quarter of an hour; a third runs the morning radar so the day's lists
-- exist before the first person opens the app. Everything is guarded: without
-- pg_cron, pg_net and a Vault secret this migration installs nothing and says
-- so, and the local test stub (which has none of them) sails through.
--
-- The one secret: the jobs authenticate to the function with the value stored
-- in Vault under the name sync_cron_secret. Putting it in Vault (Dashboard →
-- Project settings → Vault) and in the function's secrets as CRON_SECRET is an
-- owner step — the repo never carries it. Re-running this migration after the
-- secret exists installs the jobs.
do $$
declare
  v_secret_ok boolean := false;
  v_url text := 'https://fevjrcxmktjwbaozbngo.supabase.co/functions/v1/sync-console';
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'sync cron: pg_cron is not available here, so no jobs were installed.';
    return;
  end if;
  if not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice 'sync cron: pg_net is not available here, so no jobs were installed.';
    return;
  end if;
  execute 'create extension if not exists pg_cron';
  -- schema named at install: pg_net is not relocatable, and without this it
  -- lands in public, where the security advisor rightly complains about it
  execute 'create extension if not exists pg_net schema extensions';

  begin
    execute $q$select exists (select 1 from vault.decrypted_secrets where name = 'sync_cron_secret')$q$
      into v_secret_ok;
  exception when others then
    v_secret_ok := false;
  end;
  if not v_secret_ok then
    raise notice 'sync cron: no Vault secret named sync_cron_secret yet, so no jobs were installed. '
      'Add it (and the same value as CRON_SECRET on the sync-console function), then re-run this block.';
    return;
  end if;

  -- idempotent: put each job back exactly as written here
  perform cron.unschedule(jobid) from cron.job
    where jobname in ('dial-floor push', 'dial-floor pull', 'dial-floor morning radar');

  -- Each request waits as long as an edge function may run (150 s): a pull
  -- outlives a shorter wait and still finishes, but its answer would read as a
  -- timeout. sync_runs is the record either way.
  perform cron.schedule('dial-floor push', '* * * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_cron_secret')),
      body := '{"task":"push"}'::jsonb,
      timeout_milliseconds := 150000)
  $job$, v_url));

  perform cron.schedule('dial-floor pull', '*/15 * * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_cron_secret')),
      body := '{"task":"pull"}'::jsonb,
      timeout_milliseconds := 150000)
  $job$, v_url));

  -- 49: the radar deals the day on a clock instead of off the first page load.
  -- 13:00 UTC covers the business morning in every US zone (05:00–09:00 local);
  -- radar_cron() itself refuses to deal the same business day twice, so a lazy
  -- page-load run beating it to the punch costs nothing.
  perform cron.schedule('dial-floor morning radar', '0 13 * * *',
    'select public.radar_cron()');

  raise notice 'sync cron: three jobs installed (push each minute, pull each quarter hour, radar at 13:00 UTC).';
end $$;
