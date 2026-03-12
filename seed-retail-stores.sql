-- Seed or update retail stores.
-- Run this in Supabase SQL Editor before seeding retail users.

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
