-- ============================================================
-- MULTI-TENANT ARCHITECTURE MIGRATION
-- ============================================================

-- 1. Create tenants table
CREATE TABLE IF NOT EXISTS tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nom text NOT NULL DEFAULT 'Mon Espace',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 2. Add tenant_id column to every existing table
ALTER TABLE inventaire ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE utilisateurs ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE ticket_lignes ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE historique_ventes ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE mouvements_stock ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE inventaires ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE controles_inventaire ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
ALTER TABLE parametres_pharmacie ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;

-- 3. Create indexes on tenant_id for performance
CREATE INDEX IF NOT EXISTS idx_inventaire_tenant ON inventaire(tenant_id);
CREATE INDEX IF NOT EXISTS idx_utilisateurs_tenant ON utilisateurs(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tickets_tenant ON tickets(tenant_id);
CREATE INDEX IF NOT EXISTS idx_ticket_lignes_tenant ON ticket_lignes(tenant_id);
CREATE INDEX IF NOT EXISTS idx_historique_ventes_tenant ON historique_ventes(tenant_id);
CREATE INDEX IF NOT EXISTS idx_mouvements_stock_tenant ON mouvements_stock(tenant_id);
CREATE INDEX IF NOT EXISTS idx_inventaires_tenant ON inventaires(tenant_id);
CREATE INDEX IF NOT EXISTS idx_controles_inventaire_tenant ON controles_inventaire(tenant_id);
CREATE INDEX IF NOT EXISTS idx_parametres_pharmacie_tenant ON parametres_pharmacie(tenant_id);

-- 4. Create a default tenant for existing data
INSERT INTO tenants (id, nom)
SELECT '00000000-0000-0000-0000-000000000001', 'Sekas Pharma'
WHERE NOT EXISTS (SELECT 1 FROM tenants WHERE id = '00000000-0000-0000-0000-000000000001');

-- 5. Backfill existing rows with the default tenant_id
UPDATE inventaire SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE utilisateurs SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE tickets SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE ticket_lignes SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE historique_ventes SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE mouvements_stock SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE inventaires SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE controles_inventaire SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;
UPDATE parametres_pharmacie SET tenant_id = '00000000-0000-0000-0000-000000000001' WHERE tenant_id IS NULL;

-- 6. Make tenant_id NOT NULL now that all rows have a value
ALTER TABLE inventaire ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE utilisateurs ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE tickets ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE ticket_lignes ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE historique_ventes ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE mouvements_stock ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE inventaires ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE controles_inventaire ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE parametres_pharmacie ALTER COLUMN tenant_id SET NOT NULL;

-- ============================================================
-- 7. DROP ALL OLD OPEN RLS POLICIES (USING (true))
-- ============================================================

DROP POLICY IF EXISTS anon_select_inventaire ON inventaire;
DROP POLICY IF EXISTS anon_insert_inventaire ON inventaire;
DROP POLICY IF EXISTS anon_update_inventaire ON inventaire;
DROP POLICY IF EXISTS anon_delete_inventaire ON inventaire;

DROP POLICY IF EXISTS anon_select_utilisateurs ON utilisateurs;
DROP POLICY IF EXISTS anon_insert_utilisateurs ON utilisateurs;
DROP POLICY IF EXISTS anon_update_utilisateurs ON utilisateurs;
DROP POLICY IF EXISTS anon_delete_utilisateurs ON utilisateurs;

DROP POLICY IF EXISTS anon_select_tickets ON tickets;
DROP POLICY IF EXISTS anon_insert_tickets ON tickets;
DROP POLICY IF EXISTS anon_update_tickets ON tickets;
DROP POLICY IF EXISTS anon_delete_tickets ON tickets;

DROP POLICY IF EXISTS anon_select_ticket_lignes ON ticket_lignes;
DROP POLICY IF EXISTS anon_insert_ticket_lignes ON ticket_lignes;
DROP POLICY IF EXISTS anon_update_ticket_lignes ON ticket_lignes;
DROP POLICY IF EXISTS anon_delete_ticket_lignes ON ticket_lignes;

DROP POLICY IF EXISTS anon_select_historique_ventes ON historique_ventes;
DROP POLICY IF EXISTS anon_insert_historique_ventes ON historique_ventes;
DROP POLICY IF EXISTS anon_update_historique_ventes ON historique_ventes;
DROP POLICY IF EXISTS anon_delete_historique_ventes ON historique_ventes;

DROP POLICY IF EXISTS anon_select_mouvements ON mouvements_stock;
DROP POLICY IF EXISTS anon_insert_mouvements ON mouvements_stock;
DROP POLICY IF EXISTS anon_update_mouvements ON mouvements_stock;
DROP POLICY IF EXISTS anon_delete_mouvements ON mouvements_stock;

DROP POLICY IF EXISTS anon_select_inventaires ON inventaires;
DROP POLICY IF EXISTS anon_insert_inventaires ON inventaires;
DROP POLICY IF EXISTS anon_update_inventaires ON inventaires;
DROP POLICY IF EXISTS anon_delete_inventaires ON inventaires;

DROP POLICY IF EXISTS anon_select_controles ON controles_inventaire;
DROP POLICY IF EXISTS anon_insert_controles ON controles_inventaire;
DROP POLICY IF EXISTS anon_update_controles ON controles_inventaire;
DROP POLICY IF EXISTS anon_delete_controles ON controles_inventaire;

DROP POLICY IF EXISTS anon_select_parametres ON parametres_pharmacie;
DROP POLICY IF EXISTS anon_insert_parametres ON parametres_pharmacie;
DROP POLICY IF EXISTS anon_update_parametres ON parametres_pharmacie;
DROP POLICY IF EXISTS anon_delete_parametres ON parametres_pharmacie;

-- ============================================================
-- 8. HELPER FUNCTION: get current tenant_id from request headers
-- The client sends tenant_id via the apikey header's JWT claims
-- or via a custom header. We use a request header approach:
-- the app stores tenant_id in localStorage and sends it via
-- the supabase client's headers config.
-- ============================================================

CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(current_setting('request.tenant_id', true), '')::uuid;
$$;

-- ============================================================
-- 9. NEW TENANT-SCOPED RLS POLICIES
-- Every policy checks that the row's tenant_id matches the
-- tenant_id sent in the request header.
-- ============================================================

-- We use a helper macro approach: create policies for each table
-- that check tenant_id = current_tenant_id()

-- inventaire
CREATE POLICY tenant_select_inventaire ON inventaire
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_inventaire ON inventaire
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_inventaire ON inventaire
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_inventaire ON inventaire
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- utilisateurs
CREATE POLICY tenant_select_utilisateurs ON utilisateurs
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_utilisateurs ON utilisateurs
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_utilisateurs ON utilisateurs
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_utilisateurs ON utilisateurs
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- tickets
CREATE POLICY tenant_select_tickets ON tickets
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_tickets ON tickets
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_tickets ON tickets
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_tickets ON tickets
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- ticket_lignes
CREATE POLICY tenant_select_ticket_lignes ON ticket_lignes
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_ticket_lignes ON ticket_lignes
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_ticket_lignes ON ticket_lignes
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_ticket_lignes ON ticket_lignes
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- historique_ventes
CREATE POLICY tenant_select_historique_ventes ON historique_ventes
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_historique_ventes ON historique_ventes
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_historique_ventes ON historique_ventes
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_historique_ventes ON historique_ventes
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- mouvements_stock
CREATE POLICY tenant_select_mouvements ON mouvements_stock
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_mouvements ON mouvements_stock
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_mouvements ON mouvements_stock
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_mouvements ON mouvements_stock
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- inventaires
CREATE POLICY tenant_select_inventaires ON inventaires
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_inventaires ON inventaires
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_inventaires ON inventaires
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_inventaires ON inventaires
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- controles_inventaire
CREATE POLICY tenant_select_controles ON controles_inventaire
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_controles ON controles_inventaire
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_controles ON controles_inventaire
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_controles ON controles_inventaire
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- parametres_pharmacie
CREATE POLICY tenant_select_parametres ON parametres_pharmacie
  FOR SELECT TO anon, authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_insert_parametres ON parametres_pharmacie
  FOR INSERT TO anon, authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_update_parametres ON parametres_pharmacie
  FOR UPDATE TO anon, authenticated
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_delete_parametres ON parametres_pharmacie
  FOR DELETE TO anon, authenticated USING (tenant_id = current_tenant_id());

-- ============================================================
-- 10. TENANTS TABLE RLS - accessible to all (tenant listing)
-- ============================================================
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenants_select_all ON tenants
  FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY tenants_insert_all ON tenants
  FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY tenants_update_all ON tenants
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
CREATE POLICY tenants_delete_all ON tenants
  FOR DELETE TO anon, authenticated USING (true);

-- ============================================================
-- 11. SECURITY DEFINER LOGIN FUNCTION
-- Validates code against the correct tenant, returns user + tenant_id
-- ============================================================
CREATE OR REPLACE FUNCTION authenticate_user(p_code text, p_tenant_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user record;
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
    SELECT json_build_object(
      'success', true,
      'user', json_build_object(
        'id', v_user.id,
        'nom', v_user.nom,
        'code', v_user.code,
        'role', v_user.role,
        'actif', v_user.actif,
        'tenant_id', v_user.tenant_id
      )
    ) INTO v_result;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION authenticate_user(text, uuid) TO anon, authenticated;

-- 12. Grant necessary privileges on tenants table
GRANT SELECT, INSERT, UPDATE, DELETE ON tenants TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated;
