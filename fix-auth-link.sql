-- Fix: move cymunix into server_users and link to the Supabase Auth user
-- Run this in the Supabase SQL Editor.

-- Step 1: Move user from retail_users into server_users (if present)
with source_user as (
  select
    ru.username,
    case
      when ru.role::text in ('server_admin', 'server_ops', 'support') then ru.role::text::public.server_user_role
      else 'server_admin'::public.server_user_role
    end as role,
    ru.email,
    ru.is_active
  from public.retail_users ru
  where ru.username_lower = 'cymunix'
  limit 1
),
updated as (
  update public.server_users su
  set
    role = src.role,
    email = src.email,
    is_active = src.is_active,
    updated_at = now()
  from source_user src
  where su.username_lower = 'cymunix'
  returning su.id
)
insert into public.server_users (username, role, email, is_active)
select src.username, src.role, src.email, src.is_active
from source_user src
where not exists (select 1 from updated)
  and not exists (
    select 1
    from public.server_users su
    where su.username_lower = 'cymunix'
  );

-- Step 1b: Ensure cymunix exists in server_users even if retail_users source is missing
insert into public.server_users (username, role, email, is_active)
select
  'cymunix',
  'server_admin'::public.server_user_role,
  coalesce(
    (select au.email from auth.users au where au.id = '432c14a3-15bb-42d1-a076-f8d6e0d335c0' limit 1),
    'cymunix@imperial.ca'
  ),
  true
where not exists (
  select 1
  from public.server_users su
  where su.username_lower = 'cymunix'
);

-- Step 2: Remove old retail_users row for cymunix
delete from public.retail_users
where username_lower = 'cymunix';

-- Step 3: Set auth_user_id using the known UUID
update public.server_users
set auth_user_id = '432c14a3-15bb-42d1-a076-f8d6e0d335c0'
where username_lower = 'cymunix'
;

-- Step 4: Confirm the email so Supabase Auth allows sign-in
update auth.users
set email_confirmed_at = coalesce(email_confirmed_at, now())
where id = '432c14a3-15bb-42d1-a076-f8d6e0d335c0';

-- Verify: server_users row should exist and be linked
select
  su.username,
  su.role,
  su.email,
  su.is_active,
  su.auth_user_id,
  au.email_confirmed_at
from public.server_users su
join auth.users au on au.id = su.auth_user_id
where su.username_lower = 'cymunix';
