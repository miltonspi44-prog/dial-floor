-- Dial Floor · 0010 team management (managers, in the portal)
--   · team(): every member with their login email, last sign-in, and what they
--     still hold (scheduled callbacks, active lists): a deactivated agent's
--     callbacks and list leads wait for them until pushed back or reassigned
--   · set_member(): rename, change role, deactivate / reactivate. Only a manager
--     can, and never on themselves for role or active, so the team always keeps
--     at least one active manager (the one making the change).
--   New logins are still created in Supabase Auth; they arrive here as agents.

-- ------------------------------------------------------------------- team --
create or replace function public.team()
returns table (id uuid, name text, role text, active boolean, email text,
               created_at timestamptz, last_sign_in_at timestamptz,
               callbacks bigint, lists bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  return query
    select p.id, p.name, p.role, p.active, u.email::text, p.created_at, u.last_sign_in_at,
           (select count(*) from callbacks c where c.agent_id = p.id and c.status = 'scheduled'),
           (select count(*) from lists l where l.agent_id = p.id and l.status = 'active')
      from profiles p left join auth.users u on u.id = p.id
     order by p.active desc, lower(p.name);
end $$;

-- ------------------------------------------------------------- set_member --
create or replace function public.set_member(p_id uuid, p_name text default null,
                                             p_role text default null, p_active boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  m profiles%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not is_manager() then raise exception 'manager only'; end if;
  if p_role is not null and p_role not in ('agent', 'manager') then
    raise exception 'role must be agent or manager';
  end if;
  if p_name is not null and btrim(p_name) = '' then raise exception 'a name can''t be empty'; end if;
  if p_id = v_uid and (p_role = 'agent' or p_active = false) then
    raise exception 'you can''t demote or deactivate yourself: ask another manager';
  end if;

  update profiles set
    name = coalesce(btrim(p_name), name),
    role = coalesce(p_role, role),
    active = coalesce(p_active, active)
  where id = p_id
  returning * into m;
  if not found then raise exception 'no such team member'; end if;

  return jsonb_build_object('id', m.id, 'name', m.name, 'role', m.role, 'active', m.active);
end $$;

revoke execute on function public.team() from public, anon;
revoke execute on function public.set_member(uuid, text, text, boolean) from public, anon;
grant execute on function public.team(), public.set_member(uuid, text, text, boolean) to authenticated;
