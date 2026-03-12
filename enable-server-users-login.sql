-- Allow server_users to sign in from the same login flow as retail_users.
-- Run this in Supabase SQL Editor.

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

revoke all on function public.retail_login_user(text, text) from public;
grant execute on function public.retail_login_user(text, text) to anon, authenticated;
