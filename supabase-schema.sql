-- CollectorsHub Retail auth mapping table.
-- This table links Store Code + username to a Supabase Auth user email.

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'retail_user_role') then
    create type public.retail_user_role as enum ('owner', 'manager', 'staff', 'server_admin');
  end if;
end $$;

alter type public.retail_user_role add value if not exists 'server_admin';

do $$
begin
  if not exists (select 1 from pg_type where typname = 'server_user_role') then
    create type public.server_user_role as enum ('server_admin', 'server_ops', 'support');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'client_user_role') then
    create type public.client_user_role as enum ('client_admin', 'client_manager', 'client_staff');
  end if;
end $$;

create table if not exists public.retail_stores (
  id uuid primary key default gen_random_uuid(),
  store_code text not null unique,
  store_name text not null,
  timezone text not null default 'UTC',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.retail_users (
  id uuid primary key default gen_random_uuid(),
  store_code text not null references public.retail_stores(store_code) on update cascade,
  username text not null,
  username_lower text generated always as (lower(username)) stored,
  role public.retail_user_role not null default 'staff',
  email text not null,
  auth_user_id uuid references auth.users(id) on delete cascade,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.server_users (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  username_lower text generated always as (lower(username)) stored,
  role public.server_user_role not null default 'server_admin',
  email text not null,
  auth_user_id uuid references auth.users(id) on delete cascade,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_users (
  id uuid primary key default gen_random_uuid(),
  client_code text not null,
  username text not null,
  username_lower text generated always as (lower(username)) stored,
  role public.client_user_role not null default 'client_staff',
  email text not null,
  auth_user_id uuid references auth.users(id) on delete cascade,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.retail_users
  add column if not exists role public.retail_user_role not null default 'staff';

create unique index if not exists retail_stores_store_code_unique
  on public.retail_stores (store_code);

create unique index if not exists retail_users_store_username_unique
  on public.retail_users (store_code, username_lower);

drop index if exists public.retail_users_email_unique;
create index if not exists retail_users_email_idx
  on public.retail_users (email);

create unique index if not exists server_users_username_unique
  on public.server_users (username_lower);

create unique index if not exists server_users_email_unique
  on public.server_users (email);

create unique index if not exists client_users_client_username_unique
  on public.client_users (client_code, username_lower);

create unique index if not exists client_users_email_unique
  on public.client_users (email);

create or replace function public.set_retail_stores_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.set_retail_users_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.set_server_users_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.set_client_users_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists retail_stores_set_updated_at on public.retail_stores;
create trigger retail_stores_set_updated_at
before update on public.retail_stores
for each row
execute function public.set_retail_stores_updated_at();

drop trigger if exists retail_users_set_updated_at on public.retail_users;
create trigger retail_users_set_updated_at
before update on public.retail_users
for each row
execute function public.set_retail_users_updated_at();

drop trigger if exists server_users_set_updated_at on public.server_users;
create trigger server_users_set_updated_at
before update on public.server_users
for each row
execute function public.set_server_users_updated_at();

drop trigger if exists client_users_set_updated_at on public.client_users;
create trigger client_users_set_updated_at
before update on public.client_users
for each row
execute function public.set_client_users_updated_at();

alter table public.retail_stores enable row level security;
alter table public.retail_users enable row level security;
alter table public.server_users enable row level security;
alter table public.client_users enable row level security;

insert into public.retail_stores (store_code, store_name, timezone, is_active)
values
  ('NYC01', 'CollectorsHub New York', 'America/New_York', true),
  ('DAL02', 'CollectorsHub Dallas', 'America/Chicago', true)
on conflict (store_code)
do update set
  store_name = excluded.store_name,
  timezone = excluded.timezone,
  is_active = excluded.is_active,
  updated_at = now();

-- Add users.store_code -> stores.store_code FK for existing environments.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'retail_users_store_code_fkey'
      and conrelid = 'public.retail_users'::regclass
  ) then
    alter table public.retail_users
      add constraint retail_users_store_code_fkey
      foreign key (store_code)
      references public.retail_stores(store_code)
      on update cascade;
  end if;
end $$;

-- Login lookup RPC so browser clients do not query the table directly.
create or replace function public.retail_login_user(p_store_code text, p_username text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with matched_user as (
    select
      1 as priority,
      ru.email,
      ru.role::text as role,
      ru.store_code,
      ru.username,
      'retail'::text as user_type
    from public.retail_users ru
    where upper(ru.store_code) = upper(p_store_code)
      and upper(trim(p_store_code)) not in ('0000', 'SERVER', 'ADMIN')
      and ru.username_lower = lower(p_username)
      and ru.is_active = true

    union all

    select
      2 as priority,
      su.email,
      su.role::text as role,
      coalesce(nullif(upper(trim(p_store_code)), ''), 'SERVER') as store_code,
      su.username,
      'server'::text as user_type
    from public.server_users su
    where su.username_lower = lower(p_username)
      and su.is_active = true

    union all

    select
      3 as priority,
      cu.email,
      cu.role::text as role,
      cu.client_code as store_code,
      cu.username,
      'client'::text as user_type
    from public.client_users cu
    where upper(cu.client_code) = upper(p_store_code)
      and cu.username_lower = lower(p_username)
      and cu.is_active = true
  )
  select jsonb_build_object(
    'email', mu.email,
    'role', mu.role,
    'storeCode', mu.store_code,
    'username', mu.username,
    'userType', mu.user_type
  )
  from matched_user mu
  order by mu.priority
  limit 1;
$$;

drop function if exists public.retail_login_email(text, text);

revoke all on function public.retail_login_user(text, text) from public;
grant execute on function public.retail_login_user(text, text) to anon, authenticated;

-- List active stores (used by server admin store mode selector)
create or replace function public.retail_list_stores()
returns table (store_code text, store_name text, timezone text)
language sql
security definer
set search_path = public
as $$
  select rs.store_code, rs.store_name, rs.timezone
  from public.retail_stores rs
  where rs.is_active = true
  order by rs.store_name;
$$;

revoke all on function public.retail_list_stores() from public;
grant execute on function public.retail_list_stores() to authenticated;

-- Create or update a retail user across one or more stores.
create or replace function public.admin_create_retail_user(
  p_username text,
  p_email text,
  p_role public.retail_user_role,
  p_store_codes text[],
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_store_code text;
  v_rows integer := 0;
  v_auth_user_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1
    from public.server_users su
    where su.auth_user_id = v_uid
      and su.is_active = true
      and su.role = 'server_admin'
    union all
    select 1
    from public.retail_users ru
    where ru.auth_user_id = v_uid
      and ru.is_active = true
      and ru.role = 'server_admin'
  ) then
    raise exception 'Only server_admin can create users';
  end if;

  if p_username is null or btrim(p_username) = '' then
    raise exception 'Username is required';
  end if;

  if p_email is null or btrim(p_email) = '' then
    raise exception 'Email is required';
  end if;

  if p_store_codes is null or array_length(p_store_codes, 1) is null then
    raise exception 'At least one store must be selected';
  end if;

  select au.id
  into v_auth_user_id
  from auth.users au
  where lower(au.email) = lower(btrim(p_email))
  limit 1;

  foreach v_store_code in array p_store_codes loop
    insert into public.retail_users (store_code, username, role, email, auth_user_id, is_active)
    values (
      upper(btrim(v_store_code)),
      btrim(p_username),
      p_role,
      lower(btrim(p_email)),
      v_auth_user_id,
      coalesce(p_is_active, true)
    )
    on conflict (store_code, username_lower)
    do update set
      role = excluded.role,
      email = excluded.email,
      auth_user_id = coalesce(excluded.auth_user_id, public.retail_users.auth_user_id),
      is_active = excluded.is_active,
      updated_at = now();

    v_rows := v_rows + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'rows_upserted', v_rows,
    'email', lower(btrim(p_email)),
    'auth_user_linked', v_auth_user_id is not null
  );
end;
$$;

revoke all on function public.admin_create_retail_user(text, text, public.retail_user_role, text[], boolean) from public;
grant execute on function public.admin_create_retail_user(text, text, public.retail_user_role, text[], boolean) to authenticated;

-- Allow authenticated users to verify their own retail_users row for role checks
drop policy if exists "Authenticated users can read their own retail_user row" on public.retail_users;
create policy "Authenticated users can read their own retail_user row"
on public.retail_users
for select
to authenticated
using (auth_user_id = auth.uid());

drop policy if exists "Authenticated users can read their own server_user row" on public.server_users;
create policy "Authenticated users can read their own server_user row"
on public.server_users
for select
to authenticated
using (auth_user_id = auth.uid());

drop policy if exists "Authenticated users can read their own client_user row" on public.client_users;
create policy "Authenticated users can read their own client_user row"
on public.client_users
for select
to authenticated
using (auth_user_id = auth.uid());
