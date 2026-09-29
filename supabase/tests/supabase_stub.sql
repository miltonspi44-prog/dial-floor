-- Stand-ins for what a Supabase project provides, so supabase/migrations
-- apply unmodified to a plain Postgres. Tests only.
set client_min_messages = error;

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role supabase_auth_admin nologin;   -- the role Supabase Auth inserts users as

create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  last_sign_in_at timestamptz
);
-- auth.uid(): the signed-in user's id, from the request's JWT claims
create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role, supabase_auth_admin;
grant select, insert on auth.users to supabase_auth_admin;

-- API roles get table/function grants by default; RLS does the filtering
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create publication supabase_realtime;
