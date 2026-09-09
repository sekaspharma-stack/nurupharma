-- PharmaSys: inventaires tournants dynamiques + journal stock fiable + annulations atomiques

-- 1) Indexes utiles
CREATE INDEX IF NOT EXISTS idx_controles_inventaire_produit_date
  ON controles_inventaire(tenant_id, produit_id, date_controle DESC);
CREATE INDEX IF NOT EXISTS idx_mouvements_stock_tenant_date
  ON mouvements_stock(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ticket_lignes_ticket_statut
  ON ticket_lignes(tenant_id, ticket_id, statut);
CREATE INDEX IF NOT EXISTS idx_historique_ventes_ticket_prefix
  ON historique_ventes(tenant_id, id);

-- 2) Contrôle tournant individuel.
-- Chaque comptage crée un nouvel historique. Aucun produit n'est bloqué par un cycle.
CREATE OR REPLACE FUNCTION enregistrer_controle_tournant(
  p_produit_id bigint,
  p_stock_physique numeric,
  p_cause text DEFAULT NULL,
  p_observation text DEFAULT '',
  p_auteur text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id uuid;
  v_nom text;
  v_stock numeric;
  v_pua numeric;
  v_ecart numeric;
  v_valeur numeric;
  v_id bigint;
  v_inventaire_id bigint;
BEGIN
  v_tenant_id := current_tenant_id();
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  IF p_stock_physique IS NULL OR p_stock_physique < 0 THEN RAISE EXCEPTION 'Stock physique invalide'; END IF;

  SELECT nom, stock, pua INTO v_nom, v_stock, v_pua
  FROM inventaire
  WHERE id = p_produit_id AND tenant_id = v_tenant_id AND actif = true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable'; END IF;

  v_ecart := p_stock_physique - COALESCE(v_stock,0);
  v_valeur := v_ecart * COALESCE(v_pua,0);

  -- Un inventaire de référence non bloquant est conservé pour l'historique.
  SELECT id INTO v_inventaire_id
  FROM inventaires
  WHERE tenant_id = v_tenant_id AND statut = 'EN_COURS'
  ORDER BY date_inventaire DESC
  LIMIT 1;
  IF v_inventaire_id IS NULL THEN
    INSERT INTO inventaires(auteur, statut, tenant_id)
    VALUES(COALESCE(NULLIF(p_auteur,''),'Système'), 'EN_COURS', v_tenant_id)
    RETURNING id INTO v_inventaire_id;
  END IF;

  INSERT INTO controles_inventaire(
    inventaire_id, produit_id, produit_nom, stock_systeme, stock_physique,
    ecart, valeur_ecart, statut, cause, observation, stock_corrige, auteur, tenant_id
  ) VALUES (
    v_inventaire_id, p_produit_id, v_nom, v_stock, p_stock_physique,
    v_ecart, v_valeur,
    CASE WHEN v_ecart = 0 THEN 'CONFORME' ELSE 'A_ANALYSER' END,
    p_cause, COALESCE(p_observation,''), false, COALESCE(NULLIF(p_auteur,''),'Système'), v_tenant_id
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'success', true, 'controle_id', v_id, 'inventaire_id', v_inventaire_id,
    'produit_id', p_produit_id, 'stock_systeme', v_stock,
    'stock_physique', p_stock_physique, 'ecart', v_ecart
  );
END;
$$;
GRANT EXECUTE ON FUNCTION enregistrer_controle_tournant(bigint,numeric,text,text,text) TO anon, authenticated;

-- 3) Traitement atomique d'un contrôle : correction du stock + mouvement dans la même transaction.
CREATE OR REPLACE FUNCTION traiter_controle_tournant(
  p_controle_id bigint,
  p_cause text,
  p_observation text,
  p_statut text,
  p_corriger_stock boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id uuid;
  c controles_inventaire%ROWTYPE;
  v_stock numeric;
BEGIN
  v_tenant_id := current_tenant_id();
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  SELECT * INTO c FROM controles_inventaire
  WHERE id = p_controle_id AND tenant_id = v_tenant_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Contrôle introuvable'; END IF;

  IF c.stock_corrige AND p_corriger_stock THEN
    UPDATE controles_inventaire
      SET cause=p_cause, observation=COALESCE(p_observation,''), statut=COALESCE(p_statut,statut)
      WHERE id=c.id;
    RETURN jsonb_build_object('success',true,'already_corrected',true);
  END IF;

  IF p_corriger_stock THEN
    SELECT stock INTO v_stock FROM inventaire
    WHERE id=c.produit_id AND tenant_id=v_tenant_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable'; END IF;

    UPDATE inventaire SET stock=c.stock_physique
    WHERE id=c.produit_id AND tenant_id=v_tenant_id;

    INSERT INTO mouvements_stock(
      date, assistant, produit_id, produit, type, quantite,
      stock_avant, stock_apres, observation, tenant_id
    ) VALUES (
      to_char(now(),'DD/MM/YYYY HH24:MI:SS'), c.auteur, c.produit_id, c.produit_nom,
      'AJUSTEMENT_INVENTAIRE', abs(c.stock_physique-c.stock_systeme),
      v_stock, c.stock_physique, COALESCE(p_observation,'Correction inventaire'), v_tenant_id
    );
  END IF;

  UPDATE controles_inventaire
  SET cause=p_cause,
      observation=COALESCE(p_observation,''),
      statut=COALESCE(p_statut,statut),
      stock_corrige=stock_corrige OR p_corriger_stock
  WHERE id=c.id;

  RETURN jsonb_build_object('success',true,'stock_corrige',p_corriger_stock,'stock_apres',CASE WHEN p_corriger_stock THEN c.stock_physique ELSE v_stock END);
END;
$$;
GRANT EXECUTE ON FUNCTION traiter_controle_tournant(bigint,text,text,text,boolean) TO anon, authenticated;

-- 4) Réapprovisionnement atomique : stock + journal dans une seule transaction.
CREATE OR REPLACE FUNCTION reapprovisionner_stock(
  p_produit_id bigint,
  p_quantite numeric,
  p_observation text DEFAULT 'Reapprovisionnement',
  p_assistant text DEFAULT 'Système'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id uuid;
  v_nom text;
  v_avant numeric;
  v_apres numeric;
BEGIN
  v_tenant_id := current_tenant_id();
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  IF p_quantite IS NULL OR p_quantite <= 0 THEN RAISE EXCEPTION 'Quantité invalide'; END IF;

  SELECT nom, stock INTO v_nom, v_avant FROM inventaire
  WHERE id=p_produit_id AND tenant_id=v_tenant_id AND actif=true FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable'; END IF;
  v_apres := COALESCE(v_avant,0) + p_quantite;

  UPDATE inventaire SET stock=v_apres WHERE id=p_produit_id AND tenant_id=v_tenant_id;
  INSERT INTO mouvements_stock(date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,observation,tenant_id)
  VALUES(to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(NULLIF(p_assistant,''),'Système'),p_produit_id,v_nom,'REAPPRO',p_quantite,v_avant,v_apres,COALESCE(p_observation,'Reapprovisionnement'),v_tenant_id);

  RETURN jsonb_build_object('success',true,'stock_avant',v_avant,'stock_apres',v_apres);
END;
$$;
GRANT EXECUTE ON FUNCTION reapprovisionner_stock(bigint,numeric,text,text) TO anon, authenticated;

-- 5) Annulation atomique d'une ligne historique.
CREATE OR REPLACE FUNCTION annuler_ligne_ticket(p_historique_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id uuid;
  h historique_ventes%ROWTYPE;
  l ticket_lignes%ROWTYPE;
  t tickets%ROWTYPE;
  v_avant numeric;
  v_apres numeric;
BEGIN
  v_tenant_id := current_tenant_id();
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  SELECT * INTO h FROM historique_ventes
  WHERE id=p_historique_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ligne de vente introuvable'; END IF;
  IF h.statut='ANNULEE' THEN RETURN jsonb_build_object('success',true,'already_cancelled',true); END IF;

  SELECT * INTO t FROM tickets WHERE id=split_part(h.id,'-',1) AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ticket introuvable'; END IF;

  SELECT * INTO l FROM ticket_lignes
  WHERE ticket_id=t.id AND produit_id=h.produit_id AND statut='VALIDE'
  ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ligne de ticket déjà annulée ou introuvable'; END IF;

  SELECT stock INTO v_avant FROM inventaire WHERE id=l.produit_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable'; END IF;
  v_apres := v_avant + l.quantite;
  UPDATE inventaire SET stock=v_apres WHERE id=l.produit_id AND tenant_id=v_tenant_id;

  UPDATE ticket_lignes SET statut='ANNULEE' WHERE id=l.id AND statut='VALIDE';
  UPDATE historique_ventes SET statut='ANNULEE' WHERE id=h.id AND statut='VALIDE';
  UPDATE tickets SET montant_total=GREATEST(0,montant_total-l.total), benefice_total=GREATEST(0,benefice_total-l.profit), nb_articles=GREATEST(0,nb_articles-l.quantite)
  WHERE id=t.id AND tenant_id=v_tenant_id;

  INSERT INTO mouvements_stock(date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,observation,ticket,tenant_id)
  VALUES(to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(h.assistant,'Système'),l.produit_id,l.nom,'ANNULATION',l.quantite,v_avant,v_apres,'Annulation article '||h.id,t.id,v_tenant_id);

  RETURN jsonb_build_object('success',true,'ticket_id',t.id,'ligne_id',l.id,'stock_avant',v_avant,'stock_apres',v_apres);
END;
$$;
GRANT EXECUTE ON FUNCTION annuler_ligne_ticket(text) TO anon, authenticated;

-- 6) Annulation atomique d'un ticket complet. Verrouille le ticket et toutes ses lignes.
CREATE OR REPLACE FUNCTION annuler_ticket(p_ticket_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id uuid;
  t tickets%ROWTYPE;
  l ticket_lignes%ROWTYPE;
  v_avant numeric;
  v_apres numeric;
  v_nb integer := 0;
BEGIN
  v_tenant_id := current_tenant_id();
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  SELECT * INTO t FROM tickets WHERE id=p_ticket_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ticket introuvable'; END IF;
  IF t.statut='ANNULEE' THEN RETURN jsonb_build_object('success',true,'already_cancelled',true,'ticket_id',p_ticket_id); END IF;

  FOR l IN SELECT * FROM ticket_lignes WHERE ticket_id=p_ticket_id AND tenant_id=v_tenant_id AND statut='VALIDE' ORDER BY id FOR UPDATE LOOP
    SELECT stock INTO v_avant FROM inventaire WHERE id=l.produit_id AND tenant_id=v_tenant_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable : %', l.produit_id; END IF;
    v_apres := v_avant + l.quantite;
    UPDATE inventaire SET stock=v_apres WHERE id=l.produit_id AND tenant_id=v_tenant_id;

    UPDATE ticket_lignes SET statut='ANNULEE' WHERE id=l.id AND statut='VALIDE';
    UPDATE historique_ventes SET statut='ANNULEE'
      WHERE tenant_id=v_tenant_id AND id=p_ticket_id||'-'||l.produit_id AND statut='VALIDE';

    INSERT INTO mouvements_stock(date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,observation,ticket,tenant_id)
    VALUES(to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(t.assistant,'Système'),l.produit_id,l.nom,'ANNULATION',l.quantite,v_avant,v_apres,'Annulation ticket complet '||p_ticket_id,p_ticket_id,v_tenant_id);
    v_nb := v_nb + 1;
  END LOOP;

  UPDATE tickets SET statut='ANNULEE' WHERE id=p_ticket_id AND tenant_id=v_tenant_id AND statut='VALIDE';
  RETURN jsonb_build_object('success',true,'ticket_id',p_ticket_id,'lignes_annulees',v_nb);
END;
$$;
GRANT EXECUTE ON FUNCTION annuler_ticket(text) TO anon, authenticated;

-- 7) Annulation atomique par ID de ligne, utilisée par le détail du ticket.
CREATE OR REPLACE FUNCTION annuler_article_ticket(p_ligne_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant_id uuid;
  l ticket_lignes%ROWTYPE;
  t tickets%ROWTYPE;
  v_avant numeric;
  v_apres numeric;
BEGIN
  v_tenant_id := current_tenant_id();
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  SELECT * INTO l FROM ticket_lignes
  WHERE id=p_ligne_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Article du ticket introuvable'; END IF;
  IF l.statut='ANNULEE' THEN RETURN jsonb_build_object('success',true,'already_cancelled',true); END IF;

  SELECT * INTO t FROM tickets WHERE id=l.ticket_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ticket introuvable'; END IF;
  IF t.statut='ANNULEE' THEN RETURN jsonb_build_object('success',true,'already_cancelled',true); END IF;

  SELECT stock INTO v_avant FROM inventaire WHERE id=l.produit_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable'; END IF;
  v_apres := v_avant + l.quantite;
  UPDATE inventaire SET stock=v_apres WHERE id=l.produit_id AND tenant_id=v_tenant_id;

  UPDATE ticket_lignes SET statut='ANNULEE' WHERE id=l.id AND statut='VALIDE';
  UPDATE historique_ventes SET statut='ANNULEE'
    WHERE tenant_id=v_tenant_id AND id=l.ticket_id||'-'||l.produit_id AND statut='VALIDE';
  UPDATE tickets SET
    montant_total=GREATEST(0,montant_total-l.total),
    benefice_total=GREATEST(0,benefice_total-l.profit),
    nb_articles=GREATEST(0,nb_articles-l.quantite),
    statut=CASE WHEN NOT EXISTS (SELECT 1 FROM ticket_lignes WHERE ticket_id=t.id AND tenant_id=v_tenant_id AND statut='VALIDE' AND id<>l.id) THEN 'ANNULEE' ELSE statut END
  WHERE id=t.id AND tenant_id=v_tenant_id;

  INSERT INTO mouvements_stock(date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,observation,ticket,tenant_id)
  VALUES(to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(t.assistant,'Système'),l.produit_id,l.nom,'ANNULATION',l.quantite,v_avant,v_apres,'Annulation article ticket '||t.id,t.id,v_tenant_id);

  RETURN jsonb_build_object('success',true,'ticket_id',t.id,'ligne_id',l.id,'stock_avant',v_avant,'stock_apres',v_apres);
END;
$$;
GRANT EXECUTE ON FUNCTION annuler_article_ticket(bigint) TO anon, authenticated;
