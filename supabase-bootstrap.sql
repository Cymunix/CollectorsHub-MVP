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

create policy "Allow read active catalog_subcategories" on public.catalog_subcategories
  for select using (is_active = true);

create index if not exists catalog_subcategories_category_id_idx on public.catalog_subcategories(category_id);

-- Catalog Items table
create table if not exists public.catalog_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category_id uuid not null references public.catalog_categories(id),
  subcategory_id uuid references public.catalog_subcategories(id),
  brand_or_publisher text,
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

create policy "Allow read active catalog_items" on public.catalog_items
  for select using (is_active = true);

create index if not exists catalog_items_category_id_idx on public.catalog_items(category_id);
create index if not exists catalog_items_subcategory_id_idx on public.catalog_items(subcategory_id);
create index if not exists catalog_items_name_idx on public.catalog_items(lower(name));
create index if not exists catalog_items_created_by_idx on public.catalog_items(created_by);

-- Variants table
create table if not exists public.variants (
  id uuid primary key default gen_random_uuid(),
  catalog_item_id uuid not null references public.catalog_items(id) on delete cascade,
  platform_or_format text,
  edition text,
  region text,
  packaging text,
  upc text,
  release_date date,
  attributes jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.variants enable row level security;

create policy "Allow read active variants" on public.variants
  for select using (is_active = true);

create index if not exists variants_catalog_item_idx on public.variants(catalog_item_id);
create index if not exists variants_upc_idx on public.variants(upc);

-- Trigger for catalog_items updated_at
drop trigger if exists catalog_items_set_updated_at on public.catalog_items;
create trigger catalog_items_set_updated_at
before update on public.catalog_items
for each row
execute function public.set_catalog_items_updated_at();

-- Recreate trigger function with variations support
create or replace function public.set_catalog_items_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Trigger for variants updated_at
drop trigger if exists variants_set_updated_at on public.variants;
create trigger variants_set_updated_at
before update on public.variants
for each row
execute function public.set_variants_updated_at();

create or replace function public.set_variants_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

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
  p_brand_or_publisher text default null,
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

  -- Check if user is server_admin
  v_is_admin := exists (
    select 1
    from public.server_users su
    where su.auth_user_id = v_uid
      and su.is_active = true
      and su.role = 'server_admin'
  );

  if not v_is_admin then
    raise exception 'Only server admins can create catalog items';
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

  -- Create catalog item
  insert into public.catalog_items (
    name,
    category_id,
    subcategory_id,
    brand_or_publisher,
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
    case when btrim(p_brand_or_publisher) = '' then null else btrim(p_brand_or_publisher) end,
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

revoke all on function public.admin_create_catalog_item(text, uuid, uuid, text, integer, text, text, text) from public;
grant execute on function public.admin_create_catalog_item(text, uuid, uuid, text, integer, text, text, text) to authenticated;

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
        'brand_or_publisher', ci.brand_or_publisher,
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

select 'Catalog management system initialized.' as status;
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
