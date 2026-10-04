-- PharmaSys: dépenses assistants + suivi consolidé des crédits
-- Les assistants passent par des RPC SECURITY DEFINER qui récupèrent leur
-- identité depuis la session serveur. Ils ne peuvent pas déclarer une dépense
-- au nom d'un autre utilisateur.

ALTER TABLE public.mouvements_caisse
  ADD COLUMN IF NOT EXISTS assistant_id bigint;

CREATE INDEX IF NOT EXISTS idx_mouvements_caisse_tenant_assistant_date
  ON public.mouvements_caisse(tenant_id, assistant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_mouvements_caisse_tenant_depense_date
  ON public.mouvements_caisse(tenant_id, nature, created_at DESC)
  WHERE nature='DEPENSE';

-- Fonction dédiée aux dépenses saisies par l'assistant.
CREATE OR REPLACE FUNCTION public.enregistrer_depense_assistant(
  p_montant numeric,
  p_mode text DEFAULT 'ESPECES',
  p_motif text DEFAULT '',
  p_observation text DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tenant_id uuid := current_tenant_id();
  v_user_id bigint := current_user_id();
  v_role text := current_user_role();
  v_nom text;
  v_id bigint;
  v_mode text := COALESCE(NULLIF(p_mode,''),'ESPECES');
  v_motif text := COALESCE(NULLIF(trim(p_motif),''),'Dépense assistant');
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'Session invalide ou expirée';
  END IF;

  IF v_role NOT IN ('assistant','admin','Administrateur') THEN
    RAISE EXCEPTION 'Rôle non autorisé à enregistrer une dépense';
  END IF;

  IF p_montant IS NULL OR p_montant <= 0 THEN
    RAISE EXCEPTION 'Montant de dépense invalide';
  END IF;

  IF v_mode NOT IN ('ESPECES','MOBILE_MONEY','CARTE') THEN
    RAISE EXCEPTION 'Mode de paiement de dépense invalide';
  END IF;

  SELECT nom INTO v_nom
  FROM public.utilisateurs
  WHERE id=v_user_id AND tenant_id=v_tenant_id AND actif=true;

  IF v_nom IS NULL THEN
    RAISE EXCEPTION 'Utilisateur actif introuvable';
  END IF;

  INSERT INTO public.mouvements_caisse(
    type,montant,mode,motif,assistant,assistant_id,tenant_id,
    nature,reference_id,observation
  ) VALUES (
    'SORTIE',p_montant,v_mode,v_motif,v_nom,v_user_id,v_tenant_id,
    'DEPENSE',NULL,COALESCE(p_observation,'')
  ) RETURNING id INTO v_id;

  UPDATE public.mouvements_caisse
  SET reference_id='DEP-'||v_id::text
  WHERE id=v_id;

  RETURN jsonb_build_object(
    'success',true,
    'id',v_id,
    'assistant_id',v_user_id,
    'assistant',v_nom,
    'montant',p_montant,
    'nature','DEPENSE'
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.enregistrer_depense_assistant(numeric,text,text,text) TO anon, authenticated;

-- Solde réel des crédits, indépendant de la période sélectionnée dans le dashboard.
-- Une vente à crédit augmente la dette; un règlement de crédit la diminue.
CREATE OR REPLACE FUNCTION public.get_credit_balances()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tenant_id uuid := current_tenant_id();
  v_result jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Session invalide ou expirée';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.solde DESC),'[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      c.id AS client_id,
      c.nom AS client_nom,
      c.telephone,
      GREATEST(
        0,
        COALESCE((
          SELECT SUM(t.montant_credit)
          FROM public.tickets t
          WHERE t.tenant_id=v_tenant_id
            AND t.client_id=c.id
            AND t.statut='VALIDE'
            AND t.montant_credit>0
        ),0)
        -
        COALESCE((
          SELECT SUM(p.montant)
          FROM public.paiements p
          WHERE p.tenant_id=v_tenant_id
            AND p.client_id=c.id
            AND p.nature='REGLEMENT_CREDIT'
            AND p.montant>0
        ),0)
      ) AS solde
    FROM public.clients c
    WHERE c.tenant_id=v_tenant_id
      AND c.actif=true
  ) x
  WHERE x.solde>0;

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_credit_balances() TO anon, authenticated;

-- Étendre le moteur hors-ligne à la déclaration de dépense.
CREATE OR REPLACE FUNCTION public.executer_operation_offline(
  p_operation_id text,
  p_operation_type text,
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  t uuid:=current_tenant_id();
  r jsonb;
BEGIN
  IF t IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  IF EXISTS(SELECT 1 FROM operations_sync WHERE operation_id=p_operation_id AND tenant_id=t) THEN
    SELECT result INTO r FROM operations_sync WHERE operation_id=p_operation_id AND tenant_id=t;
    RETURN COALESCE(r,jsonb_build_object('success',true,'already_processed',true));
  END IF;

  IF p_operation_id IS NULL OR length(trim(p_operation_id))<8 THEN
    RAISE EXCEPTION 'Identifiant d''opération invalide';
  END IF;

  CASE p_operation_type
    WHEN 'VENTE' THEN
      r:=valider_vente(
        p_payload->'ticket'->>'id',
        (p_payload->'ticket'->>'date')::date,
        COALESCE(p_payload->'ticket'->>'heure',''),
        COALESCE(p_payload->'ticket'->>'assistant','Système'),
        NULLIF(p_payload->'ticket'->>'assistant_id','')::bigint,
        COALESCE(p_payload->'lignes','[]'::jsonb),
        COALESCE(p_payload->'ticket'->'paiements',p_payload->'paiements','[]'::jsonb)
      );
    WHEN 'REAPPRO' THEN
      r:=reapprovisionner_stock((p_payload->>'p_produit_id')::bigint,(p_payload->>'p_quantite')::numeric,COALESCE(p_payload->>'p_observation','Reapprovisionnement'),COALESCE(p_payload->>'p_assistant','Système'));
    WHEN 'CONTROLE' THEN
      r:=enregistrer_controle_tournant((p_payload->>'p_produit_id')::bigint,(p_payload->>'p_stock_physique')::numeric,p_payload->>'p_cause',COALESCE(p_payload->>'p_observation','Contrôle tournant'),COALESCE(p_payload->>'p_auteur','Système'));
    WHEN 'ANALYSE_CONTROLE' THEN
      r:=traiter_controle_tournant((p_payload->>'p_controle_id')::bigint,p_payload->>'p_cause',COALESCE(p_payload->>'p_observation',''),COALESCE(p_payload->>'p_statut','A_SUIVRE'),COALESCE((p_payload->>'p_corriger_stock')::boolean,false));
    WHEN 'CAISSE' THEN
      r:=enregistrer_mouvement_caisse(p_payload->>'p_type',(p_payload->>'p_montant')::numeric,p_payload->>'p_mode',p_payload->>'p_motif',p_payload->>'p_assistant');
    WHEN 'DEPENSE_ASSISTANT' THEN
      r:=enregistrer_depense_assistant((p_payload->>'p_montant')::numeric,COALESCE(p_payload->>'p_mode','ESPECES'),COALESCE(p_payload->>'p_motif','Dépense assistant'),COALESCE(p_payload->>'p_observation',''));
    WHEN 'PAIEMENT_CREDIT' THEN
      r:=enregistrer_paiement_credit((p_payload->>'p_client_id')::bigint,(p_payload->>'p_montant')::numeric,p_payload->>'p_mode',p_payload->>'p_observation',p_payload->>'p_assistant');
    WHEN 'ANNULER_LIGNE_HISTORIQUE' THEN
      r:=annuler_ligne_ticket(p_payload->>'p_historique_id');
    WHEN 'ANNULER_ARTICLE' THEN
      r:=annuler_article_ticket((p_payload->>'p_ligne_id')::bigint);
    WHEN 'ANNULER_TICKET' THEN
      r:=annuler_ticket(p_payload->>'p_ticket_id');
    ELSE
      RAISE EXCEPTION 'Type d''opération hors-ligne inconnu : %',p_operation_type;
  END CASE;

  INSERT INTO operations_sync(operation_id,tenant_id,operation_type,payload,result)
  VALUES(p_operation_id,t,p_operation_type,p_payload,r);
  RETURN r;
END;
$$;
GRANT EXECUTE ON FUNCTION public.executer_operation_offline(text,text,jsonb) TO anon, authenticated;

-- Empêcher un assistant de créer directement une écriture de caisse au nom d'un autre utilisateur.
DROP POLICY IF EXISTS caisse_insert ON public.mouvements_caisse;
CREATE POLICY caisse_insert ON public.mouvements_caisse
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id=current_tenant_id() AND is_current_admin());

-- Les paiements passent par les fonctions transactionnelles; les insertions
-- directes sont réservées à l'administration.
DROP POLICY IF EXISTS paiements_insert ON public.paiements;
CREATE POLICY paiements_insert ON public.paiements
  FOR INSERT TO anon, authenticated
  WITH CHECK (tenant_id=current_tenant_id() AND is_current_admin());

-- Contrôle serveur de l'identité du vendeur sur les tickets.
CREATE OR REPLACE FUNCTION public.trg_pharmasys_ticket_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public AS $$
DECLARE
  v_role text := current_user_role();
  v_user_id bigint := current_user_id();
  v_nom text;
BEGIN
  IF v_role='assistant' THEN
    IF NEW.assistant_id IS DISTINCT FROM v_user_id THEN
      RAISE EXCEPTION 'Un assistant ne peut enregistrer une vente qu''à son propre nom';
    END IF;
    SELECT nom INTO v_nom FROM public.utilisateurs WHERE id=v_user_id AND tenant_id=current_tenant_id() AND actif=true;
    IF v_nom IS NULL OR NEW.assistant IS DISTINCT FROM v_nom THEN
      RAISE EXCEPTION 'Identité du vendeur invalide';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pharmasys_ticket_identity ON public.tickets;
CREATE TRIGGER trg_pharmasys_ticket_identity
BEFORE INSERT ON public.tickets
FOR EACH ROW EXECUTE FUNCTION public.trg_pharmasys_ticket_identity();
