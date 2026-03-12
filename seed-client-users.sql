-- Seed or update client users mapped to Supabase Auth emails.
-- Run this in Supabase SQL Editor after creating auth users.

insert into public.client_users (client_code, username, role, email, auth_user_id, is_active)
values
  ('CLIENT01', 'ClientAdmin1', 'client_admin', 'clientadmin@collectorshub.com', null, true)
on conflict (client_code, username_lower)
do update set
  role = excluded.role,
  email = excluded.email,
  is_active = excluded.is_active,
  updated_at = now();
