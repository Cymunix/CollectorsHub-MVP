-- Fix: "Authentication failed: Database error querying schema"
-- Run this in Supabase SQL Editor.
--
-- What it does:
-- 1) Normalizes email case in app user tables.
-- 2) Backfills auth_user_id links from auth.users by email.
-- 3) Ensures auth.identities has an email identity for each password user.
-- 4) Confirms email for linked app users to avoid login block.
-- 5) Prints diagnostics to validate repair.

begin;

-- 1) Normalize emails in app tables.
update public.retail_users
set email = lower(btrim(email))
where email is not null
  and email <> lower(btrim(email));

update public.server_users
set email = lower(btrim(email))
where email is not null
  and email <> lower(btrim(email));

update public.client_users
set email = lower(btrim(email))
where email is not null
  and email <> lower(btrim(email));

-- 2) Backfill auth_user_id links by email.
update public.retail_users ru
set auth_user_id = au.id
from auth.users au
where ru.auth_user_id is null
  and lower(btrim(ru.email)) = lower(btrim(au.email));

update public.server_users su
set auth_user_id = au.id
from auth.users au
where su.auth_user_id is null
  and lower(btrim(su.email)) = lower(btrim(au.email));

update public.client_users cu
set auth_user_id = au.id
from auth.users au
where cu.auth_user_id is null
  and lower(btrim(cu.email)) = lower(btrim(au.email));

-- 3) Ensure each password-based auth user has an email identity row.
do $$
begin
  begin
    insert into auth.identities (
      id,
      user_id,
      identity_data,
      provider,
      provider_id,
      last_sign_in_at,
      created_at,
      updated_at
    )
    select
      gen_random_uuid(),
      au.id,
      jsonb_build_object(
        'sub', au.id::text,
        'email', lower(btrim(au.email))
      ),
      'email',
      lower(btrim(au.email)),
      now(),
      now(),
      now()
    from auth.users au
    where au.email is not null
      and au.encrypted_password is not null
      and not exists (
        select 1
        from auth.identities ai
        where ai.user_id = au.id
          and ai.provider = 'email'
      );
  exception
    when undefined_table or undefined_column then
      raise notice 'Skipped identity backfill: auth.identities schema differs from expected columns.';
  end;
end $$;

-- 4) Confirm email for linked app users.
update auth.users au
set email_confirmed_at = coalesce(au.email_confirmed_at, now())
where au.id in (
  select auth_user_id from public.retail_users where auth_user_id is not null
  union
  select auth_user_id from public.server_users where auth_user_id is not null
  union
  select auth_user_id from public.client_users where auth_user_id is not null
);

commit;

-- 5) Diagnostics
-- 5a) App users that still are not linked to auth.users.
select 'retail_unlinked' as check_name, count(*) as count
from public.retail_users
where auth_user_id is null
union all
select 'server_unlinked' as check_name, count(*) as count
from public.server_users
where auth_user_id is null
union all
select 'client_unlinked' as check_name, count(*) as count
from public.client_users
where auth_user_id is null;

-- 5b) Password users missing email identity rows.
select count(*) as password_users_missing_email_identity
from auth.users au
where au.encrypted_password is not null
  and au.email is not null
  and not exists (
    select 1
    from auth.identities ai
    where ai.user_id = au.id
      and ai.provider = 'email'
  );

-- 5c) Show duplicate app-user emails that can cause ambiguous logins.
select 'retail' as table_name, lower(btrim(email)) as email, count(*) as users
from public.retail_users
where email is not null
group by lower(btrim(email))
having count(*) > 1
union all
select 'server' as table_name, lower(btrim(email)) as email, count(*) as users
from public.server_users
where email is not null
group by lower(btrim(email))
having count(*) > 1
union all
select 'client' as table_name, lower(btrim(email)) as email, count(*) as users
from public.client_users
where email is not null
group by lower(btrim(email))
having count(*) > 1;
