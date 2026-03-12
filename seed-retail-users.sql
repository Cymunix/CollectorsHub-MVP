-- Seed or update store users mapped to Supabase Auth emails.
-- Run this in Supabase SQL Editor after creating auth users.

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
