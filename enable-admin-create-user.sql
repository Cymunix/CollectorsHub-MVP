-- Enable admin-driven retail user creation across one or more stores.
-- Run this in Supabase SQL Editor.

drop index if exists public.retail_users_email_unique;
create index if not exists retail_users_email_idx
  on public.retail_users (email);

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
