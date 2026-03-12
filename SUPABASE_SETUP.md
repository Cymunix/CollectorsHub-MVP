# CollectorsHub Retail: Supabase Setup

## 1) Configure project keys
1. Open `supabase-config.js`.
2. Replace:
   - `url` with your Supabase project URL
   - `anonKey` with your Supabase anon public key
3. Set `postLoginRedirectPath` to your app destination after login.

## 2) Create DB objects
1. In Supabase, open SQL Editor.
2. Run all SQL from `supabase-schema.sql`.

## 3) Create auth users
For each store employee, create a Supabase Auth user with email + password.
- You can do this from Supabase Dashboard (Authentication -> Users).

## 4) Create retail stores
Insert rows into `public.retail_stores`.

Run this SQL:
```sql
insert into public.retail_stores (store_code, store_name, timezone, is_active)
values
  ('NYC01', 'CollectorsHub New York', 'America/New_York', true);
```

Or run the prepared store seed script:
1. Open `seed-retail-stores.sql`
2. Edit stores
3. Run it in SQL Editor

## 5) Map Store Code + Username to Auth email + role
Insert rows into `public.retail_users`.

Run this SQL:
```sql
insert into public.retail_users (store_code, username, role, email, auth_user_id, is_active)
val6es
  ('NYC01', 'HaydenM42', 'manager', 'hayden@collectorshub.com', '00000000-0000-0000-0000-000000000000', true);
```

Or run the prepared user seed script:
1. Open `seed-retail-users.sql`
2. Edit rows for your stores and users
3. Run it in SQL Editor

Notes:
- Username matching is case-insensitive in login.
- Store Code matching is case-insensitive in login.
- Username format enforced on UI: FirstName + MiddleInitial + two digits.
- Valid roles: `owner`, `manager`, `staff`, `server_admin` (Server Admin).

## 5) Test login flow
1. Open `index.html` in your browser.
2. Enter Store Code, Username, Password.
3. On success, user is signed in and redirected to `postLoginRedirectPath`.

## Optional hardening
- Restrict allowed origins in your deployment layer.
- Move login lookup to a Supabase Edge Function if you want request-level abuse protection/rate limiting.
