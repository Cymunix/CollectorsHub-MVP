-- Create or update server user cymunix as server_admin

-- Step 1: Create the server user row
insert into public.server_users (username, role, email, is_active)
values ('cymunix', 'server_admin', 'cymunix@imperial.ca', true)
on conflict (username_lower)
do update set
  role = excluded.role,
  email = excluded.email,
  is_active = excluded.is_active,
  updated_at = now();

-- Step 2: Link to the Supabase auth user
update public.server_users
set auth_user_id = (
  select id from auth.users where email = 'cymunix@imperial.ca' limit 1
)
where username_lower = 'cymunix';

-- Verify: should show auth_user_id populated if the auth user exists
select su.username, su.role, su.email, su.is_active, su.auth_user_id
from public.server_users su
where su.username_lower = 'cymunix';
