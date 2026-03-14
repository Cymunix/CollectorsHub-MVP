-- CollectorsHub Retail bootstrap
-- Run this entire script in Supabase SQL Editor.

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

alter type public.server_user_role add value if not exists 'admin';
alter type public.server_user_role add value if not exists 'catalog_manager';

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

-- List all stores for admin management (includes inactive stores).
create or replace function public.admin_list_stores()
returns table (
  id uuid,
  store_code text,
  store_name text,
  timezone text,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1
    from public.server_users su
    where su.auth_user_id = auth.uid()
      and su.is_active = true
      and su.role in ('server_admin', 'server_ops', 'support')
    union all
    select 1
    from public.retail_users ru
    where ru.auth_user_id = auth.uid()
      and ru.is_active = true
      and ru.role = 'server_admin'
  ) then
    raise exception 'Only server staff can list stores';
  end if;

  return query
  select
    rs.id,
    rs.store_code,
    rs.store_name,
    rs.timezone,
    rs.is_active,
    rs.created_at,
    rs.updated_at
  from public.retail_stores rs
  order by rs.store_name;
end;
$$;

revoke all on function public.admin_list_stores() from public;
grant execute on function public.admin_list_stores() to authenticated;

-- Create or update store (server_admin only).
create or replace function public.admin_create_store(
  p_store_code text,
  p_store_name text,
  p_timezone text default 'UTC',
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
    raise exception 'Only server_admin can create stores';
  end if;

  v_store_code := upper(btrim(coalesce(p_store_code, '')));

  if v_store_code = '' then
    raise exception 'Store code is required';
  end if;

  if btrim(coalesce(p_store_name, '')) = '' then
    raise exception 'Store name is required';
  end if;

  insert into public.retail_stores (store_code, store_name, timezone, is_active)
  values (
    v_store_code,
    btrim(p_store_name),
    coalesce(nullif(btrim(p_timezone), ''), 'UTC'),
    coalesce(p_is_active, true)
  )
  on conflict (store_code)
  do update set
    store_name = excluded.store_name,
    timezone = excluded.timezone,
    is_active = excluded.is_active,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'store_code', v_store_code,
    'store_name', btrim(p_store_name)
  );
end;
$$;

revoke all on function public.admin_create_store(text, text, text, boolean) from public;
grant execute on function public.admin_create_store(text, text, text, boolean) to authenticated;

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

-- Create or update server user.
create or replace function public.admin_create_server_user(
  p_username text,
  p_email text,
  p_role text default 'server_ops',
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_caller_role text;
  v_auth_user_id uuid;
  v_instance_id uuid;
  v_auth_created boolean := false;
  v_temp_password text;
  v_existing_id uuid;
  v_result jsonb;
begin
  if v_caller_id is null then
    raise exception 'Not authenticated';
  end if;

  select role
  into v_caller_role
  from public.server_users su
  where su.auth_user_id = v_caller_id
    and su.is_active = true
  limit 1;

  if v_caller_role is distinct from 'server_admin' then
    raise exception 'Permission denied: server_admin role required';
  end if;

  if p_role not in ('server_admin', 'server_ops', 'support') then
    raise exception 'Invalid role: must be server_admin, server_ops, or support';
  end if;

  if btrim(p_username) = '' or btrim(p_email) = '' then
    raise exception 'Username and email are required';
  end if;

  select au.id
  into v_auth_user_id
  from auth.users au
  where lower(au.email) = lower(btrim(p_email))
  limit 1;

  if v_auth_user_id is null then
    select au.instance_id
    into v_instance_id
    from auth.users au
    limit 1;

    if v_instance_id is null then
      v_instance_id := '00000000-0000-0000-0000-000000000000'::uuid;
    end if;

    v_temp_password := 'Tmp!' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    )
    values (
      v_instance_id, gen_random_uuid(), 'authenticated', 'authenticated',
      lower(btrim(p_email)), crypt(v_temp_password, gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
      now(), now()
    )
    returning id into v_auth_user_id;
    v_auth_created := true;
  end if;

  select su.id
  into v_existing_id
  from public.server_users su
  where su.username_lower = lower(btrim(p_username))
  limit 1;

  if v_existing_id is not null then
    update public.server_users su
    set
      email = lower(btrim(p_email)),
      role = p_role::public.server_user_role,
      is_active = p_is_active,
      auth_user_id = coalesce(v_auth_user_id, su.auth_user_id),
      updated_at = now()
    where su.id = v_existing_id;
  else
    insert into public.server_users (username, email, role, is_active, auth_user_id)
    values (
      btrim(p_username),
      lower(btrim(p_email)),
      p_role::public.server_user_role,
      p_is_active,
      v_auth_user_id
    );
  end if;

  v_result := jsonb_build_object(
    'ok', true,
    'auth_user_linked', v_auth_user_id is not null,
    'auth_user_created', v_auth_created,
    'temporary_password', case when v_auth_created then v_temp_password else null end
  );

  return v_result;
end;
$$;

revoke all on function public.admin_create_server_user(text, text, text, boolean) from public;
grant execute on function public.admin_create_server_user(text, text, text, boolean) to authenticated;

-- ============================================================
-- CATALOG MANAGEMENT SYSTEM
-- ============================================================

-- Catalog Categories table
create table if not exists public.catalog_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  attributes jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.catalog_categories enable row level security;

drop policy if exists "Allow read active catalog_categories" on public.catalog_categories;
create policy "Allow read active catalog_categories" on public.catalog_categories
  for select using (is_active = true);

-- Catalog Subcategories table
create table if not exists public.catalog_subcategories (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.catalog_categories(id) on delete cascade,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(category_id, name)
);

alter table public.catalog_subcategories enable row level security;

drop policy if exists "Allow read active catalog_subcategories" on public.catalog_subcategories;
create policy "Allow read active catalog_subcategories" on public.catalog_subcategories
  for select using (is_active = true);

create index if not exists catalog_subcategories_category_id_idx on public.catalog_subcategories(category_id);

-- Catalog Franchises table
create table if not exists public.catalog_franchises (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.catalog_categories(id) on delete cascade,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(category_id, name)
);

alter table public.catalog_franchises enable row level security;

drop policy if exists "Allow read active catalog_franchises" on public.catalog_franchises;
create policy "Allow read active catalog_franchises" on public.catalog_franchises
  for select using (is_active = true);

create index if not exists catalog_franchises_category_id_idx on public.catalog_franchises(category_id);
create index if not exists catalog_franchises_name_idx on public.catalog_franchises(lower(name));

-- Catalog Items table
create table if not exists public.catalog_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category_id uuid not null references public.catalog_categories(id),
  subcategory_id uuid references public.catalog_subcategories(id),
  franchise_id uuid references public.catalog_franchises(id),
  brand_or_publisher text,
  set_number text,
  piece_count integer,
  edition text,
  upc text,
  release_year integer,
  series text,
  description text,
  primary_image_url text,
  created_by uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.catalog_items enable row level security;

drop policy if exists "Allow read active catalog_items" on public.catalog_items;
create policy "Allow read active catalog_items" on public.catalog_items
  for select using (is_active = true);

alter table public.catalog_items
  add column if not exists franchise_id uuid references public.catalog_franchises(id),
  add column if not exists set_number text,
  add column if not exists piece_count integer,
  add column if not exists edition text,
  add column if not exists upc text;

create index if not exists catalog_items_category_id_idx on public.catalog_items(category_id);
create index if not exists catalog_items_subcategory_id_idx on public.catalog_items(subcategory_id);
create index if not exists catalog_items_franchise_id_idx on public.catalog_items(franchise_id);
create index if not exists catalog_items_name_idx on public.catalog_items(lower(name));
create index if not exists catalog_items_created_by_idx on public.catalog_items(created_by);
create unique index if not exists catalog_items_set_number_unique_idx on public.catalog_items(set_number) where set_number is not null;

-- Variants table
create table if not exists public.variants (
  id uuid primary key default gen_random_uuid(),
  catalog_item_id uuid not null references public.catalog_items(id) on delete cascade,
  set_number text,
  piece_count integer,
  platform_or_format text,
  edition text,
  region text,
  packaging text,
  upc text,
  release_year integer,
  release_date date,
  attributes jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.variants
  add column if not exists set_number text,
  add column if not exists piece_count integer,
  add column if not exists release_year integer;

alter table public.variants enable row level security;

drop policy if exists "Allow read active variants" on public.variants;
create policy "Allow read active variants" on public.variants
  for select using (is_active = true);

create index if not exists variants_catalog_item_idx on public.variants(catalog_item_id);
create index if not exists variants_upc_idx on public.variants(upc);
create unique index if not exists variants_set_number_unique_idx
  on public.variants(set_number)
  where set_number is not null;

create or replace function public.set_catalog_items_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.set_variants_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Trigger for catalog_items updated_at
drop trigger if exists catalog_items_set_updated_at on public.catalog_items;
create trigger catalog_items_set_updated_at
before update on public.catalog_items
for each row
execute function public.set_catalog_items_updated_at();

-- Trigger for variants updated_at
drop trigger if exists variants_set_updated_at on public.variants;
create trigger variants_set_updated_at
before update on public.variants
for each row
execute function public.set_variants_updated_at();

-- Seed default categories with their attributes
insert into public.catalog_categories (name, description, attributes, is_active)
values
  ('Video Games', 'Video games across all platforms', '["Platform", "Edition", "Region", "Packaging", "UPC", "Release Date"]'::jsonb, true),
  ('Movies', 'Film and TV releases', '["Format", "Edition", "Region", "Packaging", "Disc Count", "UPC"]'::jsonb, true),
  ('Toys', 'Collectible toys and figures', '["Series", "Edition", "Packaging", "Release Year", "UPC"]'::jsonb, true),
  ('Music', 'Music albums and recordings', '["Format", "Edition", "Release Year", "Label", "UPC"]'::jsonb, true),
  ('Sports Cards', 'Sports trading and collectible cards', '["Set", "Year", "Card Number", "Parallel"]'::jsonb, true),
  ('Trading Cards', 'TCG and collectible card games', '["Set", "Edition", "Rarity", "Condition"]'::jsonb, true),
  ('Comics', 'Comic books and graphic novels', '["Issue Number", "Variant Cover", "Publisher", "Year", "Printing"]'::jsonb, true),
  ('Building Blocks', 'Construction sets and building systems', '["Brand", "Set Number", "Edition", "Release Year", "Piece Count", "UPC"]'::jsonb, true)
on conflict (name)
do update set
  description = excluded.description,
  attributes = excluded.attributes,
  is_active = excluded.is_active;

-- Seed subcategories for Video Games
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'Console', 'Home and handheld consoles', true from catalog_categories where name = 'Video Games'
union all
select id, 'PC', 'Personal computer games', true from catalog_categories where name = 'Video Games'
union all
select id, 'Arcade', 'Arcade and coin-op games', true from catalog_categories where name = 'Video Games'
on conflict do nothing;

-- Seed subcategories for Movies
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'Blu-ray', 'Blu-ray disc releases', true from catalog_categories where name = 'Movies'
union all
select id, 'DVD', 'Standard DVD releases', true from catalog_categories where name = 'Movies'
union all
select id, '4K Ultra HD', '4K ultra high definition releases', true from catalog_categories where name = 'Movies'
on conflict do nothing;

-- Seed subcategories for Toys
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'Action Figures', 'Collectible action figures', true from catalog_categories where name = 'Toys'
union all
select id, 'Statues', 'Statues and sculptures', true from catalog_categories where name = 'Toys'
union all
select id, 'Plushies', 'Plush toys and stuffed animals', true from catalog_categories where name = 'Toys'
on conflict do nothing;

-- Seed subcategories for Music
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'Vinyl', 'Vinyl records and LPs', true from catalog_categories where name = 'Music'
union all
select id, 'CD', 'Compact discs', true from catalog_categories where name = 'Music'
union all
select id, 'Cassette', 'Audio cassettes', true from catalog_categories where name = 'Music'
on conflict do nothing;

-- Seed subcategories for Sports Cards
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'Baseball', 'Baseball trading cards', true from catalog_categories where name = 'Sports Cards'
union all
select id, 'Football', 'American football trading cards', true from catalog_categories where name = 'Sports Cards'
union all
select id, 'Basketball', 'Basketball trading cards', true from catalog_categories where name = 'Sports Cards'
union all
select id, 'Hockey', 'Ice hockey trading cards', true from catalog_categories where name = 'Sports Cards'
on conflict do nothing;

-- Seed subcategories for Trading Cards
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'Pokémon', 'Pokémon Trading Card Game', true from catalog_categories where name = 'Trading Cards'
union all
select id, 'Magic: The Gathering', 'Magic the Gathering cards', true from catalog_categories where name = 'Trading Cards'
union all
select id, 'Yu-Gi-Oh', 'Yu-Gi-Oh Trading Card Game', true from catalog_categories where name = 'Trading Cards'
on conflict do nothing;

-- Seed subcategories for Comics
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'Marvel', 'Marvel Comics', true from catalog_categories where name = 'Comics'
union all
select id, 'DC', 'DC Comics', true from catalog_categories where name = 'Comics'
union all
select id, 'Independent', 'Independent and indie comics', true from catalog_categories where name = 'Comics'
on conflict do nothing;

-- Seed subcategories for Building Blocks
insert into public.catalog_subcategories (category_id, name, description, is_active)
select id, 'LEGO', 'LEGO building sets', true from catalog_categories where name = 'Building Blocks'
union all
select id, 'Mega Bloks', 'Mega Bloks construction sets', true from catalog_categories where name = 'Building Blocks'
union all
select id, 'Other Brands', 'Other brick and building systems', true from catalog_categories where name = 'Building Blocks'
on conflict do nothing;

-- Seed starter franchises for Building Blocks
insert into public.catalog_franchises (category_id, name, description, is_active)
select id, 'Star Wars', 'Star Wars building sets and tie-in products', true from public.catalog_categories where name = 'Building Blocks'
union all
select id, 'Harry Potter', 'Harry Potter building sets and tie-in products', true from public.catalog_categories where name = 'Building Blocks'
union all
select id, 'Marvel', 'Marvel building sets and tie-in products', true from public.catalog_categories where name = 'Building Blocks'
on conflict do nothing;

-- RPC: Check for duplicate catalog items by name and category
create or replace function public.check_catalog_duplicates(
  p_name text,
  p_category_id uuid,
  p_subcategory_id uuid default null
)
returns table (
  id uuid,
  item_name text,
  variant_display_name text
)
language sql
security definer
set search_path = public
as $$
  select distinct
    ci.id,
    ci.name as item_name,
    max(
      ci.name 
      || coalesce(' — ' || v.platform_or_format, '')
      || coalesce(' ' || v.edition, '')
    ) as variant_display_name
  from public.catalog_items ci
  left join public.variants v on v.catalog_item_id = ci.id
  where lower(ci.name) = lower(btrim(p_name))
    and ci.category_id = p_category_id
    and (p_subcategory_id is null or ci.subcategory_id = p_subcategory_id)
    and ci.is_active = true
  group by ci.id, ci.name
  limit 10;
$$;

revoke all on function public.check_catalog_duplicates(text, uuid, uuid) from public;
grant execute on function public.check_catalog_duplicates(text, uuid, uuid) to authenticated;

-- RPC: Admin create catalog item
create or replace function public.admin_create_catalog_item(
  p_name text,
  p_category_id uuid,
  p_subcategory_id uuid default null,
  p_franchise_id uuid default null,
  p_brand_or_publisher text default null,
  p_set_number text default null,
  p_piece_count integer default null,
  p_edition text default null,
  p_upc text default null,
  p_release_year integer default null,
  p_series text default null,
  p_description text default null,
  p_primary_image_url text default null
)
returns table (
  id uuid,
  name text,
  category_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_is_admin boolean;
  v_new_id uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  -- Check if user is a catalog manager
  v_is_admin := exists (
    select 1
    from public.server_users su
    where su.auth_user_id = v_uid
      and su.is_active = true
      and su.role::text in ('server_admin', 'admin', 'catalog_manager')
  );

  if not v_is_admin then
    raise exception 'Only catalog managers can create catalog items';
  end if;

  -- Validate inputs
  if btrim(p_name) = '' or p_category_id is null then
    raise exception 'Name and category are required';
  end if;

  -- Verify category exists
  if not exists (select 1 from public.catalog_categories where id = p_category_id and is_active = true) then
    raise exception 'Category not found';
  end if;

  -- Verify subcategory exists if provided
  if p_subcategory_id is not null then
    if not exists (select 1 from public.catalog_subcategories where id = p_subcategory_id and category_id = p_category_id and is_active = true) then
      raise exception 'Subcategory not found or does not belong to this category';
    end if;
  end if;

  -- Verify franchise exists if provided
  if p_franchise_id is not null then
    if not exists (select 1 from public.catalog_franchises where id = p_franchise_id and category_id = p_category_id and is_active = true) then
      raise exception 'Franchise not found or does not belong to this category';
    end if;
  end if;

  -- Create catalog item
  insert into public.catalog_items (
    name,
    category_id,
    subcategory_id,
    franchise_id,
    brand_or_publisher,
    set_number,
    piece_count,
    edition,
    upc,
    release_year,
    series,
    description,
    primary_image_url,
    created_by,
    is_active
  )
  values (
    btrim(p_name),
    p_category_id,
    p_subcategory_id,
    p_franchise_id,
    case when btrim(p_brand_or_publisher) = '' then null else btrim(p_brand_or_publisher) end,
    case when btrim(coalesce(p_set_number, '')) = '' then null else btrim(p_set_number) end,
    p_piece_count,
    case when btrim(coalesce(p_edition, '')) = '' then null else btrim(p_edition) end,
    case when btrim(coalesce(p_upc, '')) = '' then null else btrim(p_upc) end,
    p_release_year,
    case when btrim(p_series) = '' then null else btrim(p_series) end,
    case when btrim(p_description) = '' then null else btrim(p_description) end,
    p_primary_image_url,
    v_uid,
    true
  )
  returning catalog_items.id, catalog_items.name, catalog_items.category_id
  into v_new_id, p_name, p_category_id;

  return query select v_new_id, p_name, p_category_id;
end;
$$;

revoke all on function public.admin_create_catalog_item(text, uuid, uuid, uuid, text, text, integer, text, text, integer, text, text, text) from public;
grant execute on function public.admin_create_catalog_item(text, uuid, uuid, uuid, text, text, integer, text, text, integer, text, text, text) to authenticated;

-- RPC: Admin list catalog items
create or replace function public.admin_list_catalog_items(
  p_category_id uuid default null,
  p_search text default null,
  p_limit integer default 100
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(
      jsonb_build_object(
        'id', ci.id,
        'name', ci.name,
        'category_id', ci.category_id,
        'category_name', cat.name,
        'subcategory_id', ci.subcategory_id,
        'subcategory_name', subcat.name,
        'franchise_id', ci.franchise_id,
        'franchise_name', franchise.name,
        'brand_or_publisher', ci.brand_or_publisher,
        'set_number', ci.set_number,
        'piece_count', ci.piece_count,
        'edition', ci.edition,
        'upc', ci.upc,
        'release_year', ci.release_year,
        'series', ci.series,
        'description', ci.description,
        'primary_image_url', ci.primary_image_url,
        'variant_count', (select count(*) from public.variants v where v.catalog_item_id = ci.id and v.is_active = true),
        'created_at', ci.created_at
      )
      order by ci.name
    ), '[]'::jsonb),
    'total', count(*)
  )
  from public.catalog_items ci
  join public.catalog_categories cat on cat.id = ci.category_id
  left join public.catalog_subcategories subcat on subcat.id = ci.subcategory_id
  left join public.catalog_franchises franchise on franchise.id = ci.franchise_id
  where ci.is_active = true
    and (p_category_id is null or ci.category_id = p_category_id)
    and (p_search is null or lower(ci.name) like lower('%' || btrim(p_search) || '%'))
  limit p_limit;
$$;

revoke all on function public.admin_list_catalog_items(uuid, text, integer) from public;
grant execute on function public.admin_list_catalog_items(uuid, text, integer) to authenticated;

-- RPC: Admin list subcategories for a category
create or replace function public.admin_list_subcategories(p_category_id uuid)
returns table (
  id uuid,
  name text,
  description text,
  category_id uuid,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    cs.id,
    cs.name,
    cs.description,
    cs.category_id,
    cs.created_at
  from public.catalog_subcategories cs
  where cs.category_id = p_category_id
    and cs.is_active = true
  order by cs.name;
$$;

revoke all on function public.admin_list_subcategories(uuid) from public;
grant execute on function public.admin_list_subcategories(uuid) to authenticated;

-- RPC: Admin list franchises for a category
create or replace function public.admin_list_franchises(p_category_id uuid default null)
returns table (
  id uuid,
  name text,
  description text,
  category_id uuid,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    cf.id,
    cf.name,
    cf.description,
    cf.category_id,
    cf.created_at
  from public.catalog_franchises cf
  where cf.is_active = true
    and (p_category_id is null or cf.category_id = p_category_id)
  order by cf.name;
$$;

revoke all on function public.admin_list_franchises(uuid) from public;
grant execute on function public.admin_list_franchises(uuid) to authenticated;

-- RPC: Admin create franchise
create or replace function public.admin_create_franchise(
  p_name text,
  p_category_id uuid,
  p_description text default null
)
returns table (
  id uuid,
  name text,
  category_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_new_id uuid;
  v_name text;
  v_is_admin boolean;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  v_is_admin := exists (
    select 1
    from public.server_users su
    where su.auth_user_id = v_uid
      and su.is_active = true
      and su.role::text in ('server_admin', 'admin', 'catalog_manager')
  );

  if not v_is_admin then
    raise exception 'Only catalog managers can create franchises';
  end if;

  v_name := btrim(coalesce(p_name, ''));
  if v_name = '' or p_category_id is null then
    raise exception 'Name and category are required';
  end if;

  if not exists (select 1 from public.catalog_categories where id = p_category_id and is_active = true) then
    raise exception 'Category not found';
  end if;

  insert into public.catalog_franchises (category_id, name, description, is_active)
  values (
    p_category_id,
    v_name,
    case when btrim(coalesce(p_description, '')) = '' then null else btrim(p_description) end,
    true
  )
  on conflict (category_id, name)
  do update set
    description = coalesce(excluded.description, public.catalog_franchises.description),
    is_active = true
  returning catalog_franchises.id, catalog_franchises.name, catalog_franchises.category_id
  into v_new_id, v_name, p_category_id;

  return query select v_new_id, v_name, p_category_id;
end;
$$;

revoke all on function public.admin_create_franchise(text, uuid, text) from public;
grant execute on function public.admin_create_franchise(text, uuid, text) to authenticated;

-- RPC: Admin create variant
create or replace function public.admin_create_variant(
  p_catalog_item_id uuid,
  p_platform_or_format text default null,
  p_edition text default null,
  p_region text default null,
  p_packaging text default null,
  p_upc text default null,
  p_release_date date default null,
  p_attributes jsonb default '{}'::jsonb
)
returns table (
  id uuid,
  display_name text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_is_admin boolean;
  v_new_id uuid;
  v_display_name text;
  v_item_name text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  -- Check if user is server_admin
  v_is_admin := exists (
    select 1
    from public.server_users su
    where su.auth_user_id = v_uid
      and su.is_active = true
      and su.role = 'server_admin'
  );

  if not v_is_admin then
    raise exception 'Only server admins can create variants';
  end if;

  -- Verify catalog item exists and get its name
  select ci.name into v_item_name
  from public.catalog_items ci
  where ci.id = p_catalog_item_id and ci.is_active = true;

  if v_item_name is null then
    raise exception 'Catalog item not found';
  end if;

  -- Construct display name
  v_display_name := v_item_name 
    || coalesce(' — ' || p_platform_or_format, '')
    || coalesce(' ' || p_edition, '');

  -- Create variant
  insert into public.variants (
    catalog_item_id,
    platform_or_format,
    edition,
    region,
    packaging,
    upc,
    release_date,
    attributes,
    is_active
  )
  values (
    p_catalog_item_id,
    case when btrim(p_platform_or_format) = '' then null else btrim(p_platform_or_format) end,
    case when btrim(p_edition) = '' then null else btrim(p_edition) end,
    case when btrim(p_region) = '' then null else btrim(p_region) end,
    case when btrim(p_packaging) = '' then null else btrim(p_packaging) end,
    case when btrim(p_upc) = '' then null else btrim(p_upc) end,
    p_release_date,
    coalesce(p_attributes, '{}'::jsonb),
    true
  )
  returning variants.id, variants.created_at
  into v_new_id;

  return query select v_new_id, v_display_name;
end;
$$;

revoke all on function public.admin_create_variant(uuid, text, text, text, text, text, date, jsonb) from public;
grant execute on function public.admin_create_variant(uuid, text, text, text, text, text, date, jsonb) to authenticated;

-- RPC: Admin list variants for a catalog item
create or replace function public.admin_list_variants(p_catalog_item_id uuid)
returns table (
  id uuid,
  catalog_item_id uuid,
  platform_or_format text,
  edition text,
  region text,
  packaging text,
  upc text,
  release_date date,
  display_name text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    v.id,
    v.catalog_item_id,
    v.platform_or_format,
    v.edition,
    v.region,
    v.packaging,
    v.upc,
    v.release_date,
    ci.name 
      || coalesce(' — ' || v.platform_or_format, '')
      || coalesce(' ' || v.edition, '') as display_name,
    v.created_at
  from public.variants v
  join public.catalog_items ci on ci.id = v.catalog_item_id
  where v.catalog_item_id = p_catalog_item_id
    and v.is_active = true
  order by display_name;
$$;

revoke all on function public.admin_list_variants(uuid) from public;
grant execute on function public.admin_list_variants(uuid) to authenticated;

-- ============================================================
-- Admin User Management RPCs
-- ============================================================

create or replace function public.admin_list_server_users()
returns table (
  id uuid,
  username text,
  email text,
  role text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
as $$
declare
  v_caller_id uuid;
  v_caller_role text;
begin
  -- Verify the caller is an active server_admin
  v_caller_id := auth.uid();
  if v_caller_id is null then
    raise exception 'Not authenticated';
  end if;

  select role into v_caller_role
  from server_users
  where auth_user_id = v_caller_id and is_active = true
  limit 1;

  if v_caller_role is distinct from 'server_admin' then
    raise exception 'Permission denied: server_admin role required';
  end if;

  -- Return all server users
  return query
  select
    su.id,
    su.username,
    su.email,
    su.role::text,
    su.is_active,
    su.created_at
  from server_users su
  order by su.created_at desc;
end;
$$;

revoke all on function public.admin_list_server_users() from public;
grant execute on function public.admin_list_server_users() to authenticated;

create or replace function public.admin_list_retail_users()
returns table (
  id uuid,
  username text,
  email text,
  role text,
  store_code text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
as $$
declare
  v_caller_id uuid;
  v_caller_role text;
begin
  -- Verify the caller is an active server_admin
  v_caller_id := auth.uid();
  if v_caller_id is null then
    raise exception 'Not authenticated';
  end if;

  select role into v_caller_role
  from server_users
  where auth_user_id = v_caller_id and is_active = true
  limit 1;

  if v_caller_role is distinct from 'server_admin' then
    raise exception 'Permission denied: server_admin role required';
  end if;

  -- Return all retail users
  return query
  select
    ru.id,
    ru.username,
    ru.email,
    ru.role::text,
    ru.store_code,
    ru.is_active,
    ru.created_at
  from retail_users ru
  order by ru.created_at desc;
end;
$$;

revoke all on function public.admin_list_retail_users() from public;
grant execute on function public.admin_list_retail_users() to authenticated;

create or replace function public.admin_list_client_users()
returns table (
  id uuid,
  username text,
  email text,
  role text,
  client_code text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
as $$
declare
  v_caller_id uuid;
  v_caller_role text;
begin
  -- Verify the caller is an active server_admin
  v_caller_id := auth.uid();
  if v_caller_id is null then
    raise exception 'Not authenticated';
  end if;

  select role into v_caller_role
  from server_users
  where auth_user_id = v_caller_id and is_active = true
  limit 1;

  if v_caller_role is distinct from 'server_admin' then
    raise exception 'Permission denied: server_admin role required';
  end if;

  -- Return all client users
  return query
  select
    cu.id,
    cu.username,
    cu.email,
    cu.role::text,
    cu.client_code,
    cu.is_active,
    cu.created_at
  from client_users cu
  order by cu.created_at desc;
end;
$$;

revoke all on function public.admin_list_client_users() from public;
grant execute on function public.admin_list_client_users() to authenticated;

create or replace function public.is_current_user_server_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.server_users su
    where su.auth_user_id = auth.uid()
      and su.role = 'server_admin'
      and su.is_active = true
  );
$$;

revoke all on function public.is_current_user_server_admin() from public;
grant execute on function public.is_current_user_server_admin() to authenticated;

select 'Catalog management system initialized.' as status;
drop policy if exists "Authenticated users can read their own retail_user row" on public.retail_users;
create policy "Authenticated users can read their own retail_user row"
on public.retail_users
for select
to authenticated
using (auth_user_id = auth.uid());

drop policy if exists "Server admins can manage all retail users" on public.retail_users;
create policy "Server admins can manage all retail users"
on public.retail_users
for all
to authenticated
using (public.is_current_user_server_admin())
with check (public.is_current_user_server_admin());

drop policy if exists "Authenticated users can read their own server_user row" on public.server_users;
create policy "Authenticated users can read their own server_user row"
on public.server_users
for select
to authenticated
using (auth_user_id = auth.uid());

drop policy if exists "Server admins can manage all server users" on public.server_users;
create policy "Server admins can manage all server users"
on public.server_users
for all
to authenticated
using (public.is_current_user_server_admin())
with check (public.is_current_user_server_admin());

drop policy if exists "Authenticated users can read their own client_user row" on public.client_users;
create policy "Authenticated users can read their own client_user row"
on public.client_users
for select
to authenticated
using (auth_user_id = auth.uid());

drop policy if exists "Server admins can manage all client users" on public.client_users;
create policy "Server admins can manage all client users"
on public.client_users
for all
to authenticated
using (public.is_current_user_server_admin())
with check (public.is_current_user_server_admin());

-- Catalog manager role helper.
create or replace function public.is_current_user_catalog_manager()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.server_users su
    where su.auth_user_id = auth.uid()
      and su.is_active = true
      and su.role::text in ('server_admin', 'admin', 'catalog_manager')
  );
$$;

revoke all on function public.is_current_user_catalog_manager() from public;
grant execute on function public.is_current_user_catalog_manager() to authenticated;

drop policy if exists "Catalog managers can manage catalog_franchises" on public.catalog_franchises;
create policy "Catalog managers can manage catalog_franchises"
on public.catalog_franchises
for all
to authenticated
using (public.is_current_user_catalog_manager())
with check (public.is_current_user_catalog_manager());

-- Catalog image persistence.
create table if not exists public.variant_images (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.variants(id) on delete cascade,
  image_url text not null,
  storage_path text,
  alt_text text,
  is_primary boolean not null default false,
  sort_order integer not null default 0,
  thumb_status text not null default 'pending',
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists variant_images_variant_id_idx on public.variant_images(variant_id);
create unique index if not exists variant_images_primary_per_variant_idx
  on public.variant_images(variant_id)
  where is_primary = true;

alter table public.variant_images enable row level security;

drop policy if exists "Allow read variant_images" on public.variant_images;
create policy "Allow read variant_images"
on public.variant_images
for select
to authenticated
using (true);

drop policy if exists "Catalog managers can manage variant_images" on public.variant_images;
create policy "Catalog managers can manage variant_images"
on public.variant_images
for all
to authenticated
using (public.is_current_user_catalog_manager())
with check (public.is_current_user_catalog_manager());

create or replace function public.set_variant_images_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists variant_images_set_updated_at on public.variant_images;
create trigger variant_images_set_updated_at
before update on public.variant_images
for each row
execute function public.set_variant_images_updated_at();

-- Storage bucket for catalog images.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'catalog-images',
  'catalog-images',
  true,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public read catalog images" on storage.objects;
create policy "Public read catalog images"
on storage.objects
for select
to public
using (bucket_id = 'catalog-images');

drop policy if exists "Catalog managers upload catalog images" on storage.objects;
create policy "Catalog managers upload catalog images"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'catalog-images'
  and public.is_current_user_catalog_manager()
);

drop policy if exists "Catalog managers update catalog images" on storage.objects;
create policy "Catalog managers update catalog images"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'catalog-images'
  and public.is_current_user_catalog_manager()
)
with check (
  bucket_id = 'catalog-images'
  and public.is_current_user_catalog_manager()
);

drop policy if exists "Catalog managers delete catalog images" on storage.objects;
create policy "Catalog managers delete catalog images"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'catalog-images'
  and public.is_current_user_catalog_manager()
);

-- Catalog requests workflow.
create table if not exists public.catalog_requests (
  id uuid primary key default gen_random_uuid(),
  item_name text not null,
  category_name text,
  details text,
  requested_by_user_id uuid,
  requested_by_email text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists catalog_requests_status_idx on public.catalog_requests(status);
create index if not exists catalog_requests_created_at_idx on public.catalog_requests(created_at desc);

alter table public.catalog_requests enable row level security;

drop policy if exists "Users can submit catalog requests" on public.catalog_requests;
create policy "Users can submit catalog requests"
on public.catalog_requests
for insert
to authenticated
with check (requested_by_user_id = auth.uid() or requested_by_user_id is null);

drop policy if exists "Users can view own catalog requests" on public.catalog_requests;
create policy "Users can view own catalog requests"
on public.catalog_requests
for select
to authenticated
using (requested_by_user_id = auth.uid());

drop policy if exists "Catalog managers can manage catalog requests" on public.catalog_requests;
create policy "Catalog managers can manage catalog requests"
on public.catalog_requests
for all
to authenticated
using (public.is_current_user_catalog_manager())
with check (public.is_current_user_catalog_manager());

create or replace function public.submit_catalog_request(
  p_item_name text,
  p_category_name text default null,
  p_details text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_email text;
  v_id uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if btrim(coalesce(p_item_name, '')) = '' then
    raise exception 'Item name is required';
  end if;

  select au.email into v_email
  from auth.users au
  where au.id = v_uid;

  insert into public.catalog_requests (
    item_name,
    category_name,
    details,
    requested_by_user_id,
    requested_by_email,
    status
  )
  values (
    btrim(p_item_name),
    case when btrim(coalesce(p_category_name, '')) = '' then null else btrim(p_category_name) end,
    case when btrim(coalesce(p_details, '')) = '' then null else btrim(p_details) end,
    v_uid,
    v_email,
    'pending'
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_catalog_request(text, text, text) from public;
grant execute on function public.submit_catalog_request(text, text, text) to authenticated;

-- Operations admin helper for Pricing, Marketplace, and Logs.
create or replace function public.is_current_user_operations_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.server_users su
    where su.auth_user_id = auth.uid()
      and su.is_active = true
      and su.role::text in ('server_admin', 'admin')
  );
$$;

revoke all on function public.is_current_user_operations_admin() from public;
grant execute on function public.is_current_user_operations_admin() to authenticated;

-- Canonical item condition scale shared across pricing and marketplace.
create table if not exists public.condition_grades (
  score smallint primary key check (score between 1 and 10),
  label text not null unique,
  meaning text not null
);

insert into public.condition_grades (score, label, meaning)
values
  (10, 'Gem Mint', 'Perfect condition, no visible defects'),
  (9, 'Mint', 'Nearly perfect with extremely minor defects'),
  (8, 'Near Mint', 'Very well preserved with minimal wear'),
  (7, 'Very Fine', 'Light wear but still excellent condition'),
  (6, 'Fine', 'Moderate wear but well maintained'),
  (5, 'Very Good', 'Noticeable wear but fully functional'),
  (4, 'Good', 'Average condition with visible wear'),
  (3, 'Fair', 'Heavy wear but still usable'),
  (2, 'Poor', 'Significant damage or defects'),
  (1, 'Very Poor', 'Broken, incomplete, or barely usable')
on conflict (score)
do update set
  label = excluded.label,
  meaning = excluded.meaning;

-- =========================
-- Pricing Data tables
-- =========================
create table if not exists public.pricing_sources (
  id uuid primary key default gen_random_uuid(),
  source_name text not null unique,
  is_enabled boolean not null default true,
  last_update timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.pricing_recent_sales (
  id uuid primary key default gen_random_uuid(),
  catalog_item_id uuid references public.catalog_items(id) on delete set null,
  variant_id uuid references public.variants(id) on delete set null,
  catalog_item_name text,
  variant_label text,
  condition_score smallint,
  condition_label text,
  sale_price numeric(12,2) not null,
  sale_date timestamptz not null,
  source_name text,
  is_valid boolean not null default true,
  invalid_reason text,
  created_at timestamptz not null default now()
);

create index if not exists pricing_recent_sales_variant_idx on public.pricing_recent_sales(variant_id);
create index if not exists pricing_recent_sales_date_idx on public.pricing_recent_sales(sale_date desc);

alter table public.pricing_recent_sales
  add column if not exists condition_score smallint;

update public.pricing_recent_sales prs
set condition_score = case lower(btrim(prs.condition_label))
  when 'gem mint' then 10
  when 'mint' then 9
  when 'near mint' then 8
  when 'very fine' then 7
  when 'fine' then 6
  when 'very good' then 5
  when 'good' then 4
  when 'fair' then 3
  when 'poor' then 2
  when 'very poor' then 1
  else prs.condition_score
end
where prs.condition_score is null
  and prs.condition_label is not null;

update public.pricing_recent_sales prs
set condition_label = cg.label
from public.condition_grades cg
where prs.condition_score = cg.score
  and (prs.condition_label is null or prs.condition_label <> cg.label);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pricing_recent_sales_condition_score_check'
      and conrelid = 'public.pricing_recent_sales'::regclass
  ) then
    alter table public.pricing_recent_sales
      add constraint pricing_recent_sales_condition_score_check
      check (condition_score is null or condition_score between 1 and 10);
  end if;
end $$;

create table if not exists public.pricing_overrides (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.variants(id) on delete cascade,
  variant_label text,
  override_price numeric(12,2) not null,
  reason text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  is_active boolean not null default true
);

create table if not exists public.price_recalculation_jobs (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'queued' check (status in ('queued', 'running', 'completed', 'failed')),
  triggered_by uuid,
  note text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz
);

-- =========================
-- Marketplace tables
-- =========================
create table if not exists public.marketplace_listings (
  id uuid primary key default gen_random_uuid(),
  item_name text,
  variant_label text,
  seller_user_id uuid,
  seller_username text,
  price numeric(12,2) not null,
  condition_score smallint,
  condition_label text,
  status text not null default 'active' check (status in ('active', 'flagged', 'removed')),
  report_count integer not null default 0,
  last_report_reason text,
  last_reported_at timestamptz,
  date_listed timestamptz not null default now(),
  removed_reason text,
  removed_by uuid,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists marketplace_listings_status_idx on public.marketplace_listings(status);
create index if not exists marketplace_listings_date_idx on public.marketplace_listings(date_listed desc);

alter table public.marketplace_listings
  add column if not exists condition_score smallint;

update public.marketplace_listings ml
set condition_score = case lower(btrim(ml.condition_label))
  when 'gem mint' then 10
  when 'mint' then 9
  when 'near mint' then 8
  when 'very fine' then 7
  when 'fine' then 6
  when 'very good' then 5
  when 'good' then 4
  when 'fair' then 3
  when 'poor' then 2
  when 'very poor' then 1
  else ml.condition_score
end
where ml.condition_score is null
  and ml.condition_label is not null;

update public.marketplace_listings ml
set condition_label = cg.label
from public.condition_grades cg
where ml.condition_score = cg.score
  and (ml.condition_label is null or ml.condition_label <> cg.label);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'marketplace_listings_condition_score_check'
      and conrelid = 'public.marketplace_listings'::regclass
  ) then
    alter table public.marketplace_listings
      add constraint marketplace_listings_condition_score_check
      check (condition_score is null or condition_score between 1 and 10);
  end if;
end $$;

create table if not exists public.marketplace_removed_listings (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid,
  listing_label text,
  removed_by text,
  reason text,
  date_removed timestamptz not null default now()
);

create table if not exists public.marketplace_user_reports (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  reports integer not null default 0,
  last_activity timestamptz,
  account_status text not null default 'active' check (account_status in ('active', 'warned', 'suspended', 'banned')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.marketplace_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  updated_at timestamptz not null default now()
);

-- =========================
-- System logs tables
-- =========================
create table if not exists public.admin_activity_logs (
  id uuid primary key default gen_random_uuid(),
  admin_user text,
  action text,
  target_object text,
  metadata jsonb,
  "timestamp" timestamptz not null default now()
);

create table if not exists public.error_logs (
  id uuid primary key default gen_random_uuid(),
  error_type text,
  message text,
  service text,
  "timestamp" timestamptz not null default now()
);

create table if not exists public.authentication_logs (
  id uuid primary key default gen_random_uuid(),
  user_identifier text,
  ip_address text,
  location text,
  login_time timestamptz not null default now(),
  status text
);

create table if not exists public.api_logs (
  id uuid primary key default gen_random_uuid(),
  endpoint text,
  user_or_api_key text,
  response_status integer,
  latency_ms integer,
  "timestamp" timestamptz not null default now()
);

-- Shared updated_at trigger for operations tables.
create or replace function public.set_operations_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists pricing_sources_set_updated_at on public.pricing_sources;
create trigger pricing_sources_set_updated_at
before update on public.pricing_sources
for each row
execute function public.set_operations_updated_at();

drop trigger if exists marketplace_listings_set_updated_at on public.marketplace_listings;
create trigger marketplace_listings_set_updated_at
before update on public.marketplace_listings
for each row
execute function public.set_operations_updated_at();

drop trigger if exists marketplace_user_reports_set_updated_at on public.marketplace_user_reports;
create trigger marketplace_user_reports_set_updated_at
before update on public.marketplace_user_reports
for each row
execute function public.set_operations_updated_at();

drop trigger if exists marketplace_settings_set_updated_at on public.marketplace_settings;
create trigger marketplace_settings_set_updated_at
before update on public.marketplace_settings
for each row
execute function public.set_operations_updated_at();

-- RLS for operations tables.
alter table public.pricing_sources enable row level security;
alter table public.pricing_recent_sales enable row level security;
alter table public.pricing_overrides enable row level security;
alter table public.price_recalculation_jobs enable row level security;
alter table public.marketplace_listings enable row level security;
alter table public.marketplace_removed_listings enable row level security;
alter table public.marketplace_user_reports enable row level security;
alter table public.marketplace_settings enable row level security;
alter table public.admin_activity_logs enable row level security;
alter table public.error_logs enable row level security;
alter table public.authentication_logs enable row level security;
alter table public.api_logs enable row level security;

drop policy if exists "Operations admins manage pricing_sources" on public.pricing_sources;
create policy "Operations admins manage pricing_sources"
on public.pricing_sources
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins manage pricing_recent_sales" on public.pricing_recent_sales;
create policy "Operations admins manage pricing_recent_sales"
on public.pricing_recent_sales
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins manage pricing_overrides" on public.pricing_overrides;
create policy "Operations admins manage pricing_overrides"
on public.pricing_overrides
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins manage price_recalculation_jobs" on public.price_recalculation_jobs;
create policy "Operations admins manage price_recalculation_jobs"
on public.price_recalculation_jobs
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins manage marketplace_listings" on public.marketplace_listings;
create policy "Operations admins manage marketplace_listings"
on public.marketplace_listings
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins manage marketplace_removed_listings" on public.marketplace_removed_listings;
create policy "Operations admins manage marketplace_removed_listings"
on public.marketplace_removed_listings
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins manage marketplace_user_reports" on public.marketplace_user_reports;
create policy "Operations admins manage marketplace_user_reports"
on public.marketplace_user_reports
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins manage marketplace_settings" on public.marketplace_settings;
create policy "Operations admins manage marketplace_settings"
on public.marketplace_settings
for all
to authenticated
using (public.is_current_user_operations_admin())
with check (public.is_current_user_operations_admin());

drop policy if exists "Operations admins read admin_activity_logs" on public.admin_activity_logs;
create policy "Operations admins read admin_activity_logs"
on public.admin_activity_logs
for select
to authenticated
using (public.is_current_user_operations_admin());

drop policy if exists "Operations admins read error_logs" on public.error_logs;
create policy "Operations admins read error_logs"
on public.error_logs
for select
to authenticated
using (public.is_current_user_operations_admin());

drop policy if exists "Operations admins read authentication_logs" on public.authentication_logs;
create policy "Operations admins read authentication_logs"
on public.authentication_logs
for select
to authenticated
using (public.is_current_user_operations_admin());

drop policy if exists "Operations admins read api_logs" on public.api_logs;
create policy "Operations admins read api_logs"
on public.api_logs
for select
to authenticated
using (public.is_current_user_operations_admin());

-- Seed defaults for pricing and marketplace settings.
insert into public.pricing_sources (source_name, is_enabled, last_update)
values
  ('Marketplace Sales', true, now()),
  ('External API', true, now()),
  ('Manual Admin Entry', true, now())
on conflict (source_name)
do update set
  is_enabled = excluded.is_enabled,
  last_update = excluded.last_update,
  updated_at = now();

insert into public.marketplace_settings (setting_key, setting_value)
values
  ('minimum_listing_price', to_jsonb(1.00::numeric)),
  ('commission_percent', to_jsonb(10.00::numeric)),
  ('listing_expiration_days', to_jsonb(30)),
  ('allowed_condition_types', '["10 Gem Mint", "9 Mint", "8 Near Mint", "7 Very Fine", "6 Fine", "5 Very Good", "4 Good", "3 Fair", "2 Poor", "1 Very Poor"]'::jsonb)
on conflict (setting_key)
do update set
  setting_value = excluded.setting_value,
  updated_at = now();

-- Seed rows.
insert into public.retail_users (store_code, username, role, email, auth_user_id, is_active)
values
  ('NYC01', 'HaydenM42', 'manager', 'hayden@collectorshub.com', null, true),
  ('DAL02', 'AveryJ19', 'staff', 'avery@collectorshub.com', null, true)
on conflict (store_code, username_lower)
do update set
  role = excluded.role,
  email = excluded.email,
  is_active = excluded.is_active,
  updated_at = now();

insert into public.server_users (username, role, email, auth_user_id, is_active)
values
  ('cymunix', 'server_admin', 'cymunix@imperial.ca', null, true)
on conflict (username_lower)
do update set
  role = excluded.role,
  email = excluded.email,
  is_active = excluded.is_active,
  updated_at = now();

insert into public.client_users (client_code, username, role, email, auth_user_id, is_active)
values
  ('CLIENT01', 'ClientAdmin1', 'client_admin', 'clientadmin@collectorshub.com', null, true)
on conflict (client_code, username_lower)
do update set
  role = excluded.role,
  email = excluded.email,
  is_active = excluded.is_active,
  updated_at = now();
