-- ============================================================
-- PharmaSys runtime fixes: IDs, atomic sales, pharmacy settings,
-- storage bucket and tenant-safe constraints.
-- ============================================================

-- 1) Replace invalid UUID->bigint defaults with real bigint sequences.
CREATE SEQUENCE IF NOT EXISTS ticket_lignes_id_seq;
ALTER TABLE ticket_lignes ALTER COLUMN id SET DEFAULT nextval('ticket_lignes_id_seq');
ALTER SEQUENCE ticket_lignes_id_seq OWNED BY ticket_lignes.id;
SELECT setval('ticket_lignes_id_seq', COALESCE((SELECT MAX(id) FROM ticket_lignes), 0) + 1, false);

CREATE SEQUENCE IF NOT EXISTS mouvements_stock_id_seq;
ALTER TABLE mouvements_stock ALTER COLUMN id SET DEFAULT nextval('mouvements_stock_id_seq');
ALTER SEQUENCE mouvements_stock_id_seq OWNED BY mouvements_stock.id;
SELECT setval('mouvements_stock_id_seq', COALESCE((SELECT MAX(id) FROM mouvements_stock), 0) + 1, false);

CREATE SEQUENCE IF NOT EXISTS inventaires_id_seq;
ALTER TABLE inventaires ALTER COLUMN id SET DEFAULT nextval('inventaires_id_seq');
ALTER SEQUENCE inventaires_id_seq OWNED BY inventaires.id;
SELECT setval('inventaires_id_seq', COALESCE((SELECT MAX(id) FROM inventaires), 0) + 1, false);

CREATE SEQUENCE IF NOT EXISTS controles_inventaire_id_seq;
ALTER TABLE controles_inventaire ALTER COLUMN id SET DEFAULT nextval('controles_inventaire_id_seq');
ALTER SEQUENCE controles_inventaire_id_seq OWNED BY controles_inventaire.id;
SELECT setval('controles_inventaire_id_seq', COALESCE((SELECT MAX(id) FROM controles_inventaire), 0) + 1, false);

-- 2) Pharmacy settings: bigint-safe ID + exactly one row per tenant.
ALTER TABLE parametres_pharmacie ALTER COLUMN id TYPE bigint;
CREATE SEQUENCE IF NOT EXISTS parametres_pharmacie_id_seq;
ALTER TABLE parametres_pharmacie ALTER COLUMN id SET DEFAULT nextval('parametres_pharmacie_id_seq');
ALTER SEQUENCE parametres_pharmacie_id_seq OWNED BY parametres_pharmacie.id;
SELECT setval('parametres_pharmacie_id_seq', COALESCE((SELECT MAX(id) FROM parametres_pharmacie), 0) + 1, false);
CREATE UNIQUE INDEX IF NOT EXISTS uq_parametres_pharmacie_tenant ON parametres_pharmacie(tenant_id);

-- 3) Inventaire/user IDs: prevent future Date.now() integer overflows by using DB sequences.
CREATE SEQUENCE IF NOT EXISTS inventaire_id_seq;
ALTER TABLE inventaire ALTER COLUMN id SET DEFAULT nextval('inventaire_id_seq');
ALTER SEQUENCE inventaire_id_seq OWNED BY inventaire.id;
SELECT setval('inventaire_id_seq', COALESCE((SELECT MAX(id) FROM inventaire), 0) + 1, false);

CREATE SEQUENCE IF NOT EXISTS utilisateurs_id_seq;
ALTER TABLE utilisateurs ALTER COLUMN id SET DEFAULT nextval('utilisateurs_id_seq');
ALTER SEQUENCE utilisateurs_id_seq OWNED BY utilisateurs.id;
SELECT setval('utilisateurs_id_seq', COALESCE((SELECT MAX(id) FROM utilisateurs), 0) + 1, false);

-- 4) Storage bucket for pharmacy logos.
INSERT INTO storage.buckets (id, name, public)
VALUES ('logos', 'logos', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS logos_public_read ON storage.objects;
CREATE POLICY logos_public_read ON storage.objects FOR SELECT TO public
USING (bucket_id = 'logos');
DROP POLICY IF EXISTS logos_upload ON storage.objects;
CREATE POLICY logos_upload ON storage.objects FOR INSERT TO anon, authenticated
WITH CHECK (bucket_id = 'logos');
DROP POLICY IF EXISTS logos_update ON storage.objects;
CREATE POLICY logos_update ON storage.objects FOR UPDATE TO anon, authenticated
USING (bucket_id = 'logos') WITH CHECK (bucket_id = 'logos');
DROP POLICY IF EXISTS logos_delete ON storage.objects;
CREATE POLICY logos_delete ON storage.objects FOR DELETE TO anon, authenticated
USING (bucket_id = 'logos');

-- 5) Atomic sale RPC. One request performs ticket + lines + history + movement + stock.
CREATE OR REPLACE FUNCTION valider_vente(
    p_ticket_id text,
    p_date date,
    p_heure text,
    p_assistant text,
    p_assistant_id bigint,
    p_lignes jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id uuid;
    v_ligne jsonb;
    v_produit_id bigint;
    v_quantite numeric;
    v_stock numeric;
    v_pua numeric;
    v_pvu numeric;
    v_nom text;
    v_total numeric;
    v_profit numeric;
    v_nb_articles numeric := 0;
    v_montant numeric := 0;
    v_benefice numeric := 0;
BEGIN
    v_tenant_id := current_tenant_id();
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
    IF coalesce(trim(p_ticket_id), '') = '' THEN RAISE EXCEPTION 'Numéro de ticket invalide'; END IF;
    IF p_lignes IS NULL OR jsonb_typeof(p_lignes) <> 'array' OR jsonb_array_length(p_lignes) = 0 THEN
        RAISE EXCEPTION 'Le panier est vide';
    END IF;

    IF EXISTS (SELECT 1 FROM tickets WHERE id = p_ticket_id AND tenant_id = v_tenant_id) THEN
        RAISE EXCEPTION 'Ce ticket existe déjà';
    END IF;

    -- First pass: lock and validate all products before changing anything.
    FOR v_ligne IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
        v_produit_id := (v_ligne->>'produit_id')::bigint;
        v_quantite := (v_ligne->>'quantite')::numeric;
        IF v_quantite IS NULL OR v_quantite <= 0 THEN RAISE EXCEPTION 'Quantité invalide pour le produit %', v_produit_id; END IF;
        SELECT nom, stock, pua, pvu INTO v_nom, v_stock, v_pua, v_pvu
        FROM inventaire
        WHERE id = v_produit_id AND tenant_id = v_tenant_id AND actif = true
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable : %', v_produit_id; END IF;
        IF coalesce(v_stock,0) < v_quantite THEN RAISE EXCEPTION 'Stock insuffisant pour %. Disponible: %, demandé: %', v_nom, v_stock, v_quantite; END IF;
        v_nb_articles := v_nb_articles + v_quantite;
        v_total := v_quantite * coalesce(v_pvu,0);
        v_profit := v_quantite * (coalesce(v_pvu,0) - coalesce(v_pua,0));
        v_montant := v_montant + v_total;
        v_benefice := v_benefice + v_profit;
    END LOOP;

    INSERT INTO tickets(id,date,heure,assistant,assistant_id,nb_articles,montant_total,benefice_total,statut,tenant_id)
    VALUES(p_ticket_id,p_date,p_heure,p_assistant,p_assistant_id,v_nb_articles,v_montant,v_benefice,'VALIDE',v_tenant_id);

    FOR v_ligne IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
        v_produit_id := (v_ligne->>'produit_id')::bigint;
        v_quantite := (v_ligne->>'quantite')::numeric;
        SELECT nom, stock, pua, pvu INTO v_nom, v_stock, v_pua, v_pvu
        FROM inventaire WHERE id=v_produit_id AND tenant_id=v_tenant_id FOR UPDATE;
        v_total := v_quantite * coalesce(v_pvu,0);
        v_profit := v_quantite * (coalesce(v_pvu,0)-coalesce(v_pua,0));

        UPDATE inventaire SET stock = v_stock - v_quantite WHERE id=v_produit_id AND tenant_id=v_tenant_id;

        INSERT INTO ticket_lignes(ticket_id,produit_id,nom,quantite,pua,pvu,total,profit,statut,tenant_id)
        VALUES(p_ticket_id,v_produit_id,v_nom,v_quantite,v_pua,v_pvu,v_total,v_profit,'VALIDE',v_tenant_id);

        INSERT INTO historique_ventes(id,date,heure,assistant,assistant_id,produit_id,nom,quantite,pua,pvu,total,profit,statut,tenant_id)
        VALUES(p_ticket_id || '-' || v_produit_id,p_date,p_heure,p_assistant,p_assistant_id,v_produit_id,v_nom,v_quantite,v_pua,v_pvu,v_total,v_profit,'VALIDE',v_tenant_id);

        INSERT INTO mouvements_stock(date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,observation,ticket,tenant_id)
        VALUES(to_char(now(),'DD/MM/YYYY HH24:MI:SS'),p_assistant,v_produit_id,v_nom,'VENTE',v_quantite,v_stock,v_stock-v_quantite,'Vente ' || p_ticket_id,p_ticket_id,v_tenant_id);
    END LOOP;

    RETURN jsonb_build_object('success',true,'ticket_id',p_ticket_id,'nb_articles',v_nb_articles,'montant_total',v_montant,'benefice_total',v_benefice);
END;
$$;

GRANT EXECUTE ON FUNCTION valider_vente(text,date,text,text,bigint,jsonb) TO anon, authenticated;
