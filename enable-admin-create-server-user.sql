-- ============================================================
-- enable-admin-create-server-user.sql
-- Adds the admin_create_server_user RPC for creating server_users
-- Run in Supabase SQL Editor (as service_role or superuser)
-- ============================================================

-- Drop old version if it exists
DROP FUNCTION IF EXISTS admin_create_server_user(text, text, text, boolean);

CREATE OR REPLACE FUNCTION admin_create_server_user(
  p_username   text,
  p_email      text,
  p_role       text DEFAULT 'server_ops',
  p_is_active  boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_id   uuid;
  v_caller_role text;
  v_auth_user_id uuid;
  v_instance_id  uuid;
  v_auth_created boolean := false;
  v_temp_password text;
  v_existing_id  uuid;
  v_result       jsonb;
BEGIN
  -- Verify the caller is an active server_admin
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT role INTO v_caller_role
  FROM server_users
  WHERE auth_user_id = v_caller_id AND is_active = true
  LIMIT 1;

  IF v_caller_role IS DISTINCT FROM 'server_admin' THEN
    RAISE EXCEPTION 'Permission denied: server_admin role required';
  END IF;

  -- Validate role value
  IF p_role NOT IN ('server_admin', 'server_ops', 'support') THEN
    RAISE EXCEPTION 'Invalid role: must be server_admin, server_ops, or support';
  END IF;

  -- Validate inputs
  IF trim(p_username) = '' OR trim(p_email) = '' THEN
    RAISE EXCEPTION 'Username and email are required';
  END IF;

  -- Look up auth user by email
  SELECT id INTO v_auth_user_id
  FROM auth.users
  WHERE lower(email) = lower(trim(p_email))
  LIMIT 1;

  -- If auth account does not exist yet, create one with a temporary password.
  IF v_auth_user_id IS NULL THEN
    SELECT au.instance_id INTO v_instance_id
    FROM auth.users au
    LIMIT 1;

    IF v_instance_id IS NULL THEN
      v_instance_id := '00000000-0000-0000-0000-000000000000'::uuid;
    END IF;

    v_temp_password := 'Tmp!' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);

    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at
    )
    VALUES (
      v_instance_id,
      gen_random_uuid(),
      'authenticated',
      'authenticated',
      lower(trim(p_email)),
      crypt(v_temp_password, gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb,
      now(),
      now()
    )
    RETURNING id INTO v_auth_user_id;

    v_auth_created := true;
  END IF;

  BEGIN
    INSERT INTO auth.identities (
      id,
      user_id,
      identity_data,
      provider,
      provider_id,
      last_sign_in_at,
      created_at,
      updated_at
    )
    VALUES (
      gen_random_uuid(),
      v_auth_user_id,
      jsonb_build_object(
        'sub', v_auth_user_id::text,
        'email', lower(trim(p_email))
      ),
      'email',
      lower(trim(p_email)),
      now(),
      now(),
      now()
    )
    ON CONFLICT DO NOTHING;
  EXCEPTION
    WHEN undefined_table OR undefined_column THEN
      RAISE EXCEPTION 'auth.identities schema is unavailable for email/password login setup';
  END;

  -- Check if username already exists
  SELECT id INTO v_existing_id
  FROM server_users
  WHERE lower(trim(p_username)) = username_lower
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    -- Update the existing server user row
    UPDATE server_users
    SET
      email       = lower(trim(p_email)),
      role        = p_role::server_user_role,
      is_active   = p_is_active,
      auth_user_id = COALESCE(v_auth_user_id, auth_user_id)
    WHERE id = v_existing_id;
  ELSE
    -- Insert new server user row (username_lower is GENERATED ALWAYS, do not list it)
    INSERT INTO server_users (username, email, role, is_active, auth_user_id)
    VALUES (
      trim(p_username),
      lower(trim(p_email)),
      p_role::server_user_role,
      p_is_active,
      v_auth_user_id
    );
  END IF;

  v_result := jsonb_build_object(
    'success', true,
    'auth_user_linked', v_auth_user_id IS NOT NULL,
    'auth_user_created', v_auth_created,
    'temporary_password', CASE WHEN v_auth_created THEN v_temp_password ELSE NULL END
  );

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_create_server_user(text, text, text, boolean) TO authenticated;

SELECT 'admin_create_server_user RPC ready.' AS status;
