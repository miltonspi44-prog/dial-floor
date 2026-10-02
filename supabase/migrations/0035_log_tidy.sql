-- Dial Floor · 0035 the logs keep a week (cron) and a season (sync)
-- pg_cron writes a row into cron.job_run_details for every job it runs and never
-- clears one: with a push job every minute that is ~1,500 rows a day, each
-- carrying the job's whole command, for ever. A nightly job keeps the last seven
-- days of it, and 90 days of sync_runs — enough for any run anyone will still be
-- asking about.
--
-- HAND-APPLY AT LIVE TIME: the job's body is two deletes, which the management
-- API's confirmation scanner stalls on (see 0022). Dashboard SQL editor. Guarded
-- like 0034, so the local test stub (no pg_cron) sails through.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'log tidy: pg_cron is not installed here, so no job was installed.';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'dial-floor tidy logs';
  perform cron.schedule('dial-floor tidy logs', '17 9 * * *', $job$
    delete from cron.job_run_details where end_time < now() - interval '7 days';
    delete from public.sync_runs where started_at < now() - interval '90 days';
  $job$);
  raise notice 'log tidy: installed (daily at 09:17 UTC).';
end $$;
