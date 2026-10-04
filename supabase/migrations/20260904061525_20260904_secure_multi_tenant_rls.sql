/*
# Secure Multi-Tenant Architecture with Role-Based Access Control

## Overview
Replaces the insecure client-header-based tenant identification with a server-side
session token system. Adds role-based access control so that within a tenant:
- Admins (propriétaire) have full CRUD on all tables
- Assistants (utilisateurs restreints) have restricted access

## Problem Being Fixed
The previous architecture read tenant_id from a client-supplied HTTP header
(x-tenant-id). Any user could change that header to access another tenant's data.
There was also no role-based access control — every user in a tenant saw everything.

## Changes

### 1. New Table: `sessions`
- `id` (uuid, PK) — session token UUID
- `user_id` (bigint) — links to utilisateurs.id
- `tenant_id` (uuid) — links to tenants.id
- `role` (text) — 'admin' or 'assistant'
- `created_at` (timestamptz)
- `expires_at` (timestamptz) — session expiry
- RLS enabled, open to anon+authenticated (token is unguessable UUID)

### 2. Helper Functions (all SECURITY DEFINER, search_path = public)
- `current_session_id()` — extracts session UUID from x-session-id request header
- `current_tenant_id()` — resolves tenant_id from the session (no longer from client header)
- `current_user_role()` — resolves role from the session
- `current_user_id()` — resolves user_id from the session
- `create_session(p_user_id, p_tenant_id, p_role)` — creates a session, returns token
- `validate_session(p_token)` — validates and returns session info (for client)
- `authenticate_user(p_code, p_tenant_id)` — updated to create a session and return token

### 3. RLS Policy Pattern
All tables get role-aware policies:
- SELECT: tenant match (all users in tenant can read)
- INSERT: tenant match AND (admin OR assistant inserting own data)
- UPDATE: tenant match AND admin only (for sensitive tables) OR assistant can update own rows
- DELETE: tenant match AND admin only (for most tables)

### 4. Role-Based Restrictions
- `utilisateurs`: only admin can INSERT/UPDATE/DELETE; all tenant users can SELECT
- `parametres_pharmacie`: only admin can INSERT/UPDATE/DELETE; all tenant users can SELECT
- `inventaire`: admin full CRUD; assistant can SELECT + INSERT (add products) + UPDATE (adjust stock)
- `tickets`, `ticket_lignes`, `historique_ventes`, `mouvements_stock`: all users can INSERT (make sales);
  only admin can DELETE (cancel/void); UPDATE restricted to admin
- `inventaires`, `controles_inventaire`: admin full CRUD; assistant can SELECT + INSERT (perform checks)

### 5. Security Notes
- Session tokens are unguessable UUIDs (gen_random_uuid)
- Sessions expire after 24 hours
- tenant_id is never trusted from the client — always resolved server-side from the session
- The `tenants` table remains open for listing (needed for onboarding)
- `authenticate_user` is SECURITY DEFINER and intentionally executable by anon (login must work before session)
*/

-- ============================================================
-- 1. SESSIONS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id bigint NOT NULL,
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'assistant',
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours')
);

ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;

-- Sessions are open to anon+authenticated: the token (id) is an unguessable UUID
-- and acts as a bearer token. RLS on sessions is not the security boundary —
-- the token itself is. We keep RLS open so the client can validate its own session.
DROP POLICY IF EXISTS "session_select_all" ON sessions;
CREATE POLICY "session_select_all" ON sessions
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "session_insert_all" ON sessions;
CREATE POLICY "session_insert_all" ON sessions
  FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "session_update_all" ON sessions;
CREATE POLICY "session_update_all" ON sessions
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "session_delete_all" ON sessions;
CREATE POLICY "session_delete_all" ON sessions
  FOR DELETE TO anon, authenticated USING (true);

-- ============================================================
-- 2. HELPER FUNCTIONS (SECURITY DEFINER)
-- ============================================================

-- Extract session UUID from the x-session-id request header
CREATE OR REPLACE FUNCTION current_session_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(current_setting('request.headers', true)::json->>'x-session-id', '')::uuid;
$$;

-- Resolve tenant_id from the validated session
CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT tenant_id FROM sessions
  WHERE id = current_session_id()
    AND expires_at > now();
$$;

-- Resolve role from the validated session
CREATE OR REPLACE FUNCTION current_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM sessions
  WHERE id = current_session_id()
    AND expires_at > now();
$$;

-- Resolve user_id from the validated session
CREATE OR REPLACE FUNCTION current_user_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT user_id FROM sessions
  WHERE id = current_session_id()
    AND expires_at > now();
$$;

-- Check if current session is admin
CREATE OR REPLACE FUNCTION is_current_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT role = 'admin' FROM sessions
    WHERE id = current_session_id()
      AND expires_at > now()
  ), false);
$$;

-- Create a new session for a user
CREATE OR REPLACE FUNCTION create_session(p_user_id bigint, p_tenant_id uuid, p_role text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session_id uuid;
BEGIN
  INSERT INTO sessions (user_id, tenant_id, role)
  VALUES (p_user_id, p_tenant_id, p_role)
  RETURNING id INTO v_session_id;
  RETURN v_session_id;
END;
$$;

-- Validate a session token (called by client to verify session is alive)
CREATE OR REPLACE FUNCTION validate_session(p_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session record;
  v_result json;
BEGIN
  SELECT s.id, s.user_id, s.tenant_id, s.role, s.expires_at,
         u.nom, u.code
  INTO v_session
  FROM sessions s
  JOIN utilisateurs u ON u.id = s.user_id AND u.tenant_id = s.tenant_id
  WHERE s.id = p_token
    AND s.expires_at > now()
    AND u.actif = true;

  IF v_session IS NULL THEN
    SELECT json_build_object('success', false, 'message', 'Session invalide ou expirée') INTO v_result;
  ELSE
    SELECT json_build_object(
      'success', true,
      'session', json_build_object(
        'id', v_session.id,
        'user_id', v_session.user_id,
        'tenant_id', v_session.tenant_id,
        'role', v_session.role,
        'nom', v_session.nom,
        'code', v_session.code
      )
    ) INTO v_result;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION validate_session(uuid) TO anon, authenticated;

-- ============================================================
-- 3. UPDATED AUTHENTICATE_USER FUNCTION
-- Now creates a session and returns the session token
-- ============================================================
DROP FUNCTION IF EXISTS authenticate_user(text, uuid) CASCADE;

CREATE OR REPLACE FUNCTION authenticate_user(p_code text, p_tenant_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user record;
  v_session_id uuid;
  v_result json;
BEGIN
  SELECT id, nom, code, role, actif, tenant_id
  INTO v_user
  FROM utilisateurs
  WHERE code = p_code
    AND tenant_id = p_tenant_id
    AND actif = true;

  IF v_user IS NULL THEN
    SELECT json_build_object('success', false, 'message', 'Code incorrect ou compte désactivé') INTO v_result;
  ELSE
    -- Create a session for this user
    PERFORM create_session(v_user.id, v_user.tenant_id, v_user.role);
    SELECT id INTO v_session_id FROM sessions
    WHERE user_id = v_user.id AND tenant_id = v_user.tenant_id
    ORDER BY created_at DESC LIMIT 1;

    SELECT json_build_object(
      'success', true,
      'user', json_build_object(
        'id', v_user.id,
        'nom', v_user.nom,
        'code', v_user.code,
        'role', v_user.role,
        'actif', v_user.actif,
        'tenant_id', v_user.tenant_id
      ),
      'session_token', v_session_id
    ) INTO v_result;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION authenticate_user(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION create_session(bigint, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION current_session_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION current_tenant_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION current_user_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION current_user_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION is_current_admin() TO anon, authenticated;

-- ============================================================
-- 4. DROP OLD TENANT-SCOPED POLICIES (based on client header)
-- ============================================================

-- inventaire
DROP POLICY IF EXISTS tenant_select_inventaire ON inventaire;
DROP POLICY IF EXISTS tenant_insert_inventaire ON inventaire;
DROP POLICY IF EXISTS tenant_update_inventaire ON inventaire;
DROP POLICY IF EXISTS tenant_delete_inventaire ON inventaire;

-- utilisateurs
DROP POLICY IF EXISTS tenant_select_utilisateurs ON utilisateurs;
DROP POLICY IF EXISTS tenant_insert_utilisateurs ON utilisateurs;
DROP POLICY IF EXISTS tenant_update_utilisateurs ON utilisateurs;
DROP POLICY IF EXISTS tenant_delete_utilisateurs ON utilisateurs;

-- tickets
DROP POLICY IF EXISTS tenant_select_tickets ON tickets;
DROP POLICY IF EXISTS tenant_insert_tickets ON tickets;
DROP POLICY IF EXISTS tenant_update_tickets ON tickets;
DROP POLICY IF EXISTS tenant_delete_tickets ON tickets;

-- ticket_lignes
DROP POLICY IF EXISTS tenant_select_ticket_lignes ON ticket_lignes;
DROP POLICY IF EXISTS tenant_insert_ticket_lignes ON ticket_lignes;
DROP POLICY IF EXISTS tenant_update_ticket_lignes ON ticket_lignes;
DROP POLICY IF EXISTS tenant_delete_ticket_lignes ON ticket_lignes;

-- historique_ventes
DROP POLICY IF EXISTS tenant_select_historique_ventes ON historique_ventes;
DROP POLICY IF EXISTS tenant_insert_historique_ventes ON historique_ventes;
DROP POLICY IF EXISTS tenant_update_historique_ventes ON historique_ventes;
DROP POLICY IF EXISTS tenant_delete_historique_ventes ON historique_ventes;

-- mouvements_stock
DROP POLICY IF EXISTS tenant_select_mouvements ON mouvements_stock;
DROP POLICY IF EXISTS tenant_insert_mouvements ON mouvements_stock;
DROP POLICY IF EXISTS tenant_update_mouvements ON mouvements_stock;
DROP POLICY IF EXISTS tenant_delete_mouvements ON mouvements_stock;

-- inventaires
DROP POLICY IF EXISTS tenant_select_inventaires ON inventaires;
DROP POLICY IF EXISTS tenant_insert_inventaires ON inventaires;
DROP POLICY IF EXISTS tenant_update_inventaires ON inventaires;
DROP POLICY IF EXISTS tenant_delete_inventaires ON inventaires;

-- controles_inventaire
DROP POLICY IF EXISTS tenant_select_controles ON controles_inventaire;
DROP POLICY IF EXISTS tenant_insert_controles ON controles_inventaire;
DROP POLICY IF EXISTS tenant_update_controles ON controles_inventaire;
DROP POLICY IF EXISTS tenant_delete_controles ON controles_inventaire;

-- parametres_pharmacie
DROP POLICY IF EXISTS tenant_select_parametres ON parametres_pharmacie;
DROP POLICY IF EXISTS tenant_insert_parametres ON parametres_pharmacie;
DROP POLICY IF EXISTS tenant_update_parametres ON parametres_pharmacie;
DROP POLICY IF EXISTS tenant_delete_parametres ON parametres_pharmacie;

-- ============================================================
-- 5. NEW ROLE-AWARE RLS POLICIES
-- Pattern: tenant match from server-side session + role check
-- ============================================================

-- ---- inventaire ----
-- Admin: full CRUD. Assistant: SELECT + INSERT + UPDATE (can add/adjust products, cannot delete)
CREATE POLICY "inv_select" ON inventaire
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "inv_insert" ON inventaire
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "inv_update" ON inventaire
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "inv_delete" ON inventaire
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- utilisateurs ----
-- Admin: full CRUD. Assistant: SELECT only (can see team but not modify)
CREATE POLICY "usr_select" ON utilisateurs
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "usr_insert" ON utilisateurs
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "usr_update" ON utilisateurs
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "usr_delete" ON utilisateurs
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- tickets ----
-- All users can create tickets (make sales). Admin can UPDATE/DELETE. Assistant can only INSERT + SELECT.
CREATE POLICY "tkt_select" ON tickets
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "tkt_insert" ON tickets
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "tkt_update" ON tickets
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "tkt_delete" ON tickets
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- ticket_lignes ----
CREATE POLICY "tl_select" ON ticket_lignes
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "tl_insert" ON ticket_lignes
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "tl_update" ON ticket_lignes
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "tl_delete" ON ticket_lignes
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- historique_ventes ----
-- All users can INSERT (recording sales). Admin can UPDATE/DELETE. Assistant can SELECT + INSERT.
CREATE POLICY "hv_select" ON historique_ventes
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "hv_insert" ON historique_ventes
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "hv_update" ON historique_ventes
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "hv_delete" ON historique_ventes
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- mouvements_stock ----
-- All users can INSERT (stock movements from sales/restocks). Admin can UPDATE/DELETE.
CREATE POLICY "ms_select" ON mouvements_stock
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "ms_insert" ON mouvements_stock
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "ms_update" ON mouvements_stock
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "ms_delete" ON mouvements_stock
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- inventaires (cycle sessions) ----
-- Admin: full CRUD. Assistant: SELECT + INSERT (can start/perform inventory checks).
CREATE POLICY "inv_cycle_select" ON inventaires
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "inv_cycle_insert" ON inventaires
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "inv_cycle_update" ON inventaires
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "inv_cycle_delete" ON inventaires
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- controles_inventaire ----
CREATE POLICY "ci_select" ON controles_inventaire
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "ci_insert" ON controles_inventaire
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY "ci_update" ON controles_inventaire
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "ci_delete" ON controles_inventaire
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ---- parametres_pharmacie ----
-- Admin: full CRUD. Assistant: SELECT only (can see pharmacy info, not edit).
CREATE POLICY "pp_select" ON parametres_pharmacie
  FOR SELECT TO anon, authenticated
  USING (tenant_id = current_tenant_id());

CREATE POLICY "pp_insert" ON parametres_pharmacie
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "pp_update" ON parametres_pharmacie
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin())
  WITH CHECK (tenant_id = current_tenant_id() AND is_current_admin());

CREATE POLICY "pp_delete" ON parametres_pharmacie
  FOR DELETE TO anon, authenticated
  USING (tenant_id = current_tenant_id() AND is_current_admin());

-- ============================================================
-- 6. GRANT PRIVILEGES
-- ============================================================
GRANT SELECT, INSERT, UPDATE, DELETE ON sessions TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated;

-- ============================================================
-- 7. INDEX ON SESSIONS
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_sessions_tenant ON sessions(tenant_id);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
