-- Seed or update server users mapped to Supabase Auth emails.
-- Run this in Supabase SQL Editor after creating auth users.

insert into public.server_users (username, role, email, auth_user_id, is_active)
values
  ('cymunix', 'server_admin', 'cymunix@imperial.ca', null, true)
on conflict (username_lower)
do update set
  role = excluded.role,
  email = excluded.email,
  is_active = excluded.is_active,
  updated_at = now();
