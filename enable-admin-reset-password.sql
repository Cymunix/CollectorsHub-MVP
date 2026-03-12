-- ============================================================
-- enable-admin-reset-password.sql
-- Adds the admin_reset_user_password RPC
-- Callable by: server_admin (any user), server_ops (except server_admin targets)
-- support cannot reset passwords
-- Run in Supabase SQL Editor
-- ============================================================

DROP FUNCTION IF EXISTS admin_reset_user_password(text, text);

CREATE OR REPLACE FUNCTION admin_reset_user_password(
  p_username     text,
  p_new_password text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_id      uuid;
  v_caller_role    text;
  v_target_auth_id uuid;
  v_target_role    text;
  v_found_in       text;
BEGIN
  -- Must be authenticated
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Caller must be server_admin or server_ops
  SELECT role INTO v_caller_role
  FROM server_users
  WHERE auth_user_id = v_caller_id AND is_active = true
  LIMIT 1;

  IF v_caller_role NOT IN ('server_admin', 'server_ops') THEN
    RAISE EXCEPTION 'Permission denied: server_admin or server_ops role required';
  END IF;

  -- Enforce minimum password length
  IF length(trim(p_new_password)) < 8 THEN
    RAISE EXCEPTION 'Password must be at least 8 characters';
  END IF;

  IF trim(p_username) = '' THEN
    RAISE EXCEPTION 'Username is required';
  END IF;

  -- Search retail_users
  SELECT DISTINCT auth_user_id INTO v_target_auth_id
  FROM retail_users
  WHERE username_lower = lower(trim(p_username))
    AND is_active = true
    AND auth_user_id IS NOT NULL
  LIMIT 1;

  IF v_target_auth_id IS NOT NULL THEN
    v_found_in := 'retail';
  END IF;

  -- Search server_users
  IF v_target_auth_id IS NULL THEN
    SELECT auth_user_id, role INTO v_target_auth_id, v_target_role
    FROM server_users
    WHERE username_lower = lower(trim(p_username))
      AND is_active = true
    LIMIT 1;

    IF v_target_auth_id IS NOT NULL THEN
      v_found_in := 'server';

      -- server_ops cannot reset a server_admin password
      IF v_caller_role = 'server_ops' AND v_target_role = 'server_admin' THEN
        RAISE EXCEPTION 'Permission denied: server_ops cannot reset a server_admin password';
      END IF;
    END IF;
  END IF;

  -- Search client_users
  IF v_target_auth_id IS NULL THEN
    SELECT auth_user_id INTO v_target_auth_id
    FROM client_users
    WHERE username_lower = lower(trim(p_username))
      AND is_active = true
      AND auth_user_id IS NOT NULL
    LIMIT 1;

    IF v_target_auth_id IS NOT NULL THEN
      v_found_in := 'client';
    END IF;
  END IF;

  IF v_target_auth_id IS NULL THEN
    RAISE EXCEPTION 'User "%" not found or has no linked auth account', trim(p_username);
  END IF;

  -- Update the password in Supabase auth
  UPDATE auth.users
  SET encrypted_password = crypt(p_new_password, gen_salt('bf'))
  WHERE id = v_target_auth_id;

  RETURN jsonb_build_object(
    'success',    true,
    'user_type',  v_found_in
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_reset_user_password(text, text) TO authenticated;

SELECT 'admin_reset_user_password RPC ready.' AS status;
