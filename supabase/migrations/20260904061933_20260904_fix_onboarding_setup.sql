/*
# Fix onboarding: allow initial tenant setup without an existing session

## Problem
After the secure RLS migration, creating a new tenant + admin user during
onboarding fails because:
- The `utilisateurs` INSERT policy requires `is_current_admin()` = true
- No session exists yet, so `is_current_admin()` returns false
- The insert is silently blocked by RLS

## Solution
Create a `setup_tenant` SECURITY DEFINER function that:
1. Creates a new tenant (or reuses an existing one)
2. Creates a default admin user for that tenant
3. Returns the tenant ID + admin credentials

This function bypasses RLS (SECURITY DEFINER) and is only meant for
initial onboarding. It is callable by anon (needed before any session exists).

## New/Modified Functions
- `setup_tenant(p_tenant_name text, p_admin_code text)` — creates tenant + admin, returns json
*/

CREATE OR REPLACE FUNCTION setup_tenant(p_tenant_name text DEFAULT 'Mon Espace', p_admin_code text DEFAULT 'admin')
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id uuid;
  v_admin_id bigint;
  v_result json;
BEGIN
  -- Create or reuse tenant
  SELECT id INTO v_tenant_id FROM tenants WHERE nom = p_tenant_name LIMIT 1;
  IF v_tenant_id IS NULL THEN
    INSERT INTO tenants (nom) VALUES (p_tenant_name) RETURNING id INTO v_tenant_id;
  END IF;

  -- Check if an admin already exists for this tenant
  SELECT id INTO v_admin_id FROM utilisateurs WHERE tenant_id = v_tenant_id AND role = 'admin' LIMIT 1;
  IF v_admin_id IS NULL THEN
    -- Let the database sequence generate the bigint ID.
    INSERT INTO utilisateurs (nom, code, role, actif, tenant_id)
    VALUES ('Administrateur', p_admin_code, 'admin', true, v_tenant_id)
    RETURNING id INTO v_admin_id;
  END IF;

  SELECT json_build_object(
    'success', true,
    'tenant_id', v_tenant_id,
    'tenant_name', p_tenant_name,
    'admin_id', v_admin_id,
    'admin_code', p_admin_code
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION setup_tenant(text, text) TO anon, authenticated;
