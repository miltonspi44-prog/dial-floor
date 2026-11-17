-- 0049: the registry hold is a setting a manager can change, 14 days unless changed.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

select t.reset() \g /dev/null
delete from app_settings where key = 'pull_hold_registry_days';

\echo '57.1 · The registry hold shows on the Settings page at 14 days, takes 0 to 60, and nothing else'
do $$
declare s jsonb;
begin
  perform t.as_user('M');
  s := (select x from jsonb_array_elements(public.settings_all()) x where x->>'key' = 'pull_hold_registry_days');
  assert s->>'grp' = 'Lead sync' and (s->>'value')::int = 14 and (s->>'def')::int = 14, format('listed, at 14 days: %s', s);
  -- every other setting is still listed
  assert jsonb_array_length(public.settings_all()) = jsonb_array_length(public.settings_registry()), 'nothing dropped from the list';
  assert (select count(*) from jsonb_array_elements(public.settings_registry())) = 27, 'the 26 there were, and this one';
  perform public.settings_set('pull_hold_registry_days', '21');
  assert public.setting('pull_hold_registry_days') = '21'::jsonb, 'changed to 21: what the pull reads';
  perform public.settings_set('pull_hold_registry_days', '0');
  assert public.setting('pull_hold_registry_days') = '0'::jsonb, 'switched off';
  perform t.fails($q$select public.settings_set('pull_hold_registry_days', '61')$q$, 'at most 60');
  perform t.fails($q$select public.settings_set('pull_hold_registry_days', '-1')$q$, 'at least 0');
  perform t.fails($q$select public.settings_set('pull_hold_registry_days', '2.5')$q$, 'whole number');
  perform t.as_user('A');
  perform t.fails($q$select public.settings_set('pull_hold_registry_days', '1')$q$, 'manager only');
end $$;

delete from app_settings where key = 'pull_hold_registry_days';
