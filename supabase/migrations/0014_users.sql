-- Dial Floor · 0014 users (managers add, remove and manage logins in the app)
--   The Users tab replaces the Supabase dashboard for everyday user admin.
--   Creating, deleting and resetting logins needs the service key, so that part
--   runs in the admin-users edge function, which first checks the caller is an
--   active manager. This migration gives it (and the tab) what they read:
--   · team(): + removed (the login is banned: they can't sign in) and has_history
--   · member_history(): what someone's calls and records would lose on delete; a
--     user with any history is removed (banned, off the floor) rather than
--     deleted, so the reports keep every call
--   · release_member(): hand someone's scheduled callbacks back to the queue and
--     their assigned lists to the whole team, in one go

-- ------------------------------------------------------------ member_history --
create or replace function public.member_history(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'attempts',  (select count(*) from attempts where agent_id = p_id),
    'callbacks', (select count(*) from callbacks where agent_id = p_id or requeued_by = p_id),
    'lists',     (select count(*) from lists where agent_id = p_id or created_by = p_id),
    'handoffs',  (select count(*) from handoff_ledger where agent_id = p_id or outcome_by = p_id),
    'emails',    (select count(*) from email_queue where flagged_by = p_id or sent_by = p_id),
    'taps',      (select count(*) from card_taps where agent_id = p_id),
    'radar',     (select count(*) from radar_items where agent_id = p_id),
    'library',   (select count(*) from library_items where created_by = p_id),
    'leads',     (select count(*) from lead_state where owner_agent = p_id))
$$;

-- -------------------------------------------------------------------- team --
drop function if exists public.team();
create function public.team()
returns table (id uuid, name text, role text, active boolean, email text,
               created_at timestamptz, last_sign_in_at timestamptz,
               callbacks bigint, lists bigint, removed boolean, has_history boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  return query
    select p.id, p.name, p.role, p.active, u.email::text, p.created_at, u.last_sign_in_at,
           (select count(*) from callbacks c where c.agent_id = p.id and c.status = 'scheduled'),
           (select count(*) from lists l where l.agent_id = p.id and l.status = 'active'),
           coalesce(u.banned_until > now(), false),
           exists (select 1 from jsonb_each_text(member_history(p.id)) h where h.value::int > 0)
      from profiles p left join auth.users u on u.id = p.id
     order by p.active desc, lower(p.name);
end $$;

-- ---------------------------------------------------------- release_member --
create or replace function public.release_member(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cb int; v_lists int;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  -- their promised callbacks go back to the queue (the same as "push back" on the floor)
  update callbacks set status = 'requeued', requeued_by = v_uid
   where agent_id = p_id and status = 'scheduled';
  get diagnostics v_cb = row_count;
  update lead_state set state = 'queued', owner_agent = null, updated_at = now()
   where owner_agent = p_id and state = 'callback_locked';
  -- their lists stay alive, shared with everyone
  update lists set agent_id = null where agent_id = p_id and status = 'active';
  get diagnostics v_lists = row_count;
  update lead_state set reserved_by = null, reserved_until = null where reserved_by = p_id;
  return jsonb_build_object('callbacks', v_cb, 'lists', v_lists);
end $$;

-- ---------------------------------------------------------------- API surface --
revoke execute on function public.member_history(uuid) from public, anon, authenticated;
grant execute on function public.member_history(uuid) to service_role;
revoke execute on function public.team(), public.release_member(uuid) from public, anon;
grant execute on function public.team(), public.release_member(uuid) to authenticated;
