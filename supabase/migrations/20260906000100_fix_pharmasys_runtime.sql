-- ============================================================
-- PharmaSys runtime fixes: IDs, atomic sales, pharmacy settings,
-- storage bucket and tenant-safe constraints.
-- ============================================================

-- 1) Repair numeric IDs only when the column is NOT already an identity column.
-- The base schema of current PharmaSys uses GENERATED ... AS IDENTITY.
-- PostgreSQL rejects ALTER COLUMN ... SET DEFAULT on such columns (SQLSTATE 42601).
-- Therefore existing identity columns are left untouched; legacy installations
-- that still have a plain bigint column receive a sequence-backed default.
DO $$
DECLARE
  r record;
  v_identity text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('ticket_lignes','id','ticket_lignes_id_seq'),
    ('mouvements_stock','id','mouvements_stock_id_seq'),
    ('inventaires','id','inventaires_id_seq'),
    ('controles_inventaire','id','controles_inventaire_id_seq')
  ) AS x(tbl,col,seq) LOOP
    SELECT a.attidentity INTO v_identity
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname='public' AND c.relname=r.tbl AND a.attname=r.col AND a.attnum>0 AND NOT a.attisdropped;

    IF coalesce(v_identity,'') = '' THEN
      EXECUTE format('CREATE SEQUENCE IF NOT EXISTS public.%I', r.seq);
      EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DEFAULT nextval(''public.%I''::regclass)', r.tbl, r.col, r.seq);
      EXECUTE format('ALTER SEQUENCE public.%I OWNED BY public.%I.%I', r.seq, r.tbl, r.col);
      EXECUTE format('SELECT setval(''public.%I'', COALESCE((SELECT MAX(%I) FROM public.%I), 0) + 1, false)', r.seq, r.col, r.tbl);
    END IF;
  END LOOP;
END $$;

-- 2) Pharmacy settings: bigint-safe ID + exactly one row per tenant.
ALTER TABLE public.parametres_pharmacie ALTER COLUMN id TYPE bigint;
DO $$
DECLARE v_identity text;
BEGIN
  SELECT a.attidentity INTO v_identity
  FROM pg_attribute a
  JOIN pg_class c ON c.oid=a.attrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='parametres_pharmacie' AND a.attname='id' AND a.attnum>0 AND NOT a.attisdropped;
  IF coalesce(v_identity,'') = '' THEN
    EXECUTE 'CREATE SEQUENCE IF NOT EXISTS public.parametres_pharmacie_id_seq';
    EXECUTE 'ALTER TABLE public.parametres_pharmacie ALTER COLUMN id SET DEFAULT nextval(''public.parametres_pharmacie_id_seq''::regclass)';
    EXECUTE 'ALTER SEQUENCE public.parametres_pharmacie_id_seq OWNED BY public.parametres_pharmacie.id';
    EXECUTE 'SELECT setval(''public.parametres_pharmacie_id_seq'', COALESCE((SELECT MAX(id) FROM public.parametres_pharmacie), 0) + 1, false)';
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_parametres_pharmacie_tenant ON public.parametres_pharmacie(tenant_id);

-- 3) Inventaire/user IDs: use DB sequences only for legacy non-identity columns.
DO $$
DECLARE
  r record;
  v_identity text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('inventaire','id','inventaire_id_seq'),
    ('utilisateurs','id','utilisateurs_id_seq')
  ) AS x(tbl,col,seq) LOOP
    SELECT a.attidentity INTO v_identity
    FROM pg_attribute a
    JOIN pg_class c ON c.oid=a.attrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname=r.tbl AND a.attname=r.col AND a.attnum>0 AND NOT a.attisdropped;
    IF coalesce(v_identity,'') = '' THEN
      EXECUTE format('CREATE SEQUENCE IF NOT EXISTS public.%I', r.seq);
      EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DEFAULT nextval(''public.%I''::regclass)', r.tbl, r.col, r.seq);
      EXECUTE format('ALTER SEQUENCE public.%I OWNED BY public.%I.%I', r.seq, r.tbl, r.col);
      EXECUTE format('SELECT setval(''public.%I'', COALESCE((SELECT MAX(%I) FROM public.%I), 0) + 1, false)', r.seq, r.col, r.tbl);
    END IF;
  END LOOP;
END $$;

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
