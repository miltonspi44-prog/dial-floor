-- Dial Floor · 0004 number stats bump (called by the zoom-webhook function)
create or replace function public.bump_number_stats(p_number text, p_connect boolean)
returns void language sql security definer set search_path = public as $$
  insert into number_stats (number, stat_date, dials, connects)
  values (p_number, current_date, 1, case when p_connect then 1 else 0 end)
  on conflict (number, stat_date) do update
    set dials = number_stats.dials + 1,
        connects = number_stats.connects + (case when p_connect then 1 else 0 end);
$$;
