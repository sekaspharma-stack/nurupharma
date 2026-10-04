-- PharmaSys V13.1 - Finance, caisse, remboursements et rapport journalier
-- Objectif : rendre les opérations commerciales et financières cohérentes.
-- Une annulation restitue le stock ET inverse exactement la partie encaissée.

ALTER TABLE public.mouvements_caisse
  ADD COLUMN IF NOT EXISTS nature text NOT NULL DEFAULT 'MANUEL',
  ADD COLUMN IF NOT EXISTS reference_id text,
  ADD COLUMN IF NOT EXISTS observation text DEFAULT '';

ALTER TABLE public.paiements
  ADD COLUMN IF NOT EXISTS nature text NOT NULL DEFAULT 'ENCAISSEMENT',
  ADD COLUMN IF NOT EXISTS reference_id text;

CREATE INDEX IF NOT EXISTS idx_mouvements_caisse_tenant_nature_date
  ON public.mouvements_caisse(tenant_id, nature, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mouvements_caisse_ticket
  ON public.mouvements_caisse(tenant_id, ticket_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_paiements_ticket_nature
  ON public.paiements(tenant_id, ticket_id, nature, created_at DESC);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pharmasys_remboursement_deja_cree(
  p_tenant_id uuid,
  p_reference_id text
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.mouvements_caisse
    WHERE tenant_id=p_tenant_id
      AND nature='REMBOURSEMENT'
      AND reference_id=p_reference_id
  );
$$;

-- ---------------------------------------------------------------------------
-- Annulation d'une ligne : stock + remboursement proportionnel aux paiements
-- réels du ticket. Le crédit est diminué par une écriture négative de paiement,
-- sans mouvement de caisse puisqu'il n'avait pas été encaissé.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pharmasys_rembourser_ligne(
  p_ticket_id text,
  p_ligne_id bigint,
  p_ligne_total numeric,
  p_ticket_total_original numeric,
  p_assistant text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  t uuid := current_tenant_id();
  pay record;
  v_ratio numeric;
  v_ref text := p_ticket_id || ':L:' || p_ligne_id::text;
  v_refund numeric;
  v_total_refund numeric := 0;
BEGIN
  IF t IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  IF p_ticket_total_original <= 0 OR p_ligne_total <= 0 THEN
    RETURN jsonb_build_object('success',true,'remboursement',0);
  END IF;
  IF public._pharmasys_remboursement_deja_cree(t,v_ref) THEN
    RETURN jsonb_build_object('success',true,'already_refunded',true,'reference_id',v_ref);
  END IF;

  v_ratio := LEAST(1, p_ligne_total / p_ticket_total_original);

  FOR pay IN
    SELECT id, montant, mode, client_id
    FROM public.paiements
    WHERE tenant_id=t AND ticket_id=p_ticket_id AND montant > 0
      AND nature='ENCAISSEMENT'
    ORDER BY id
  LOOP
    v_refund := round(pay.montant * v_ratio, 2);
    IF v_refund <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.paiements(
      ticket_id, client_id, montant, mode, observation, assistant,
      tenant_id, nature, reference_id
    ) VALUES (
      p_ticket_id, pay.client_id, -v_refund, pay.mode,
      'Remboursement annulation ligne #'||p_ligne_id,
      COALESCE(p_assistant,'Système'), t, 'REMBOURSEMENT', v_ref
    );

    IF pay.mode <> 'CREDIT' THEN
      INSERT INTO public.mouvements_caisse(
        type,montant,mode,motif,ticket_id,client_id,assistant,tenant_id,
        nature,reference_id,observation
      ) VALUES (
        'SORTIE',v_refund,pay.mode,
        'Remboursement annulation ligne #'||p_ligne_id,
        p_ticket_id,pay.client_id,COALESCE(p_assistant,'Système'),t,
        'REMBOURSEMENT',v_ref,'Inverse du paiement #'||pay.id
      );
    END IF;
    v_total_refund := v_total_refund + v_refund;
  END LOOP;

  RETURN jsonb_build_object(
    'success',true,'reference_id',v_ref,'remboursement',v_total_refund
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Remplace les annulations existantes en ajoutant l'inversion financière.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.annuler_ligne_ticket(p_historique_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tenant_id uuid := current_tenant_id();
  h public.historique_ventes%ROWTYPE;
  l public.ticket_lignes%ROWTYPE;
  t public.tickets%ROWTYPE;
  v_avant numeric;
  v_apres numeric;
  v_original_total numeric;
  v_result jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  SELECT * INTO h FROM public.historique_ventes
    WHERE id=p_historique_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ligne de vente introuvable'; END IF;
  IF h.statut='ANNULEE' THEN
    RETURN jsonb_build_object('success',true,'already_cancelled',true);
  END IF;

  SELECT * INTO t FROM public.tickets
    WHERE id=split_part(h.id,'-',1) AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ticket introuvable'; END IF;

  SELECT * INTO l FROM public.ticket_lignes
    WHERE ticket_id=t.id AND produit_id=h.produit_id AND statut='VALIDE'
    ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ligne de ticket déjà annulée ou introuvable'; END IF;

  SELECT stock INTO v_avant FROM public.inventaire
    WHERE id=l.produit_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable'; END IF;
  v_apres := COALESCE(v_avant,0) + l.quantite;
  UPDATE public.inventaire SET stock=v_apres WHERE id=l.produit_id AND tenant_id=v_tenant_id;

  UPDATE public.ticket_lignes SET statut='ANNULEE' WHERE id=l.id AND statut='VALIDE';
  UPDATE public.historique_ventes SET statut='ANNULEE' WHERE id=h.id AND statut='VALIDE';
  UPDATE public.tickets SET
    montant_total=GREATEST(0,montant_total-l.total),
    benefice_total=GREATEST(0,benefice_total-l.profit),
    nb_articles=GREATEST(0,nb_articles-l.quantite),
    montant_paye=GREATEST(0,montant_paye-l.total),
    montant_credit=GREATEST(0,montant_credit-CASE WHEN montant_credit>0 THEN LEAST(montant_credit,l.total) ELSE 0 END),
    statut=CASE WHEN NOT EXISTS (
      SELECT 1 FROM public.ticket_lignes WHERE ticket_id=t.id AND tenant_id=v_tenant_id AND statut='VALIDE'
    ) THEN 'ANNULEE' ELSE statut END
  WHERE id=t.id AND tenant_id=v_tenant_id;

  INSERT INTO public.mouvements_stock(
    date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,
    observation,ticket,tenant_id
  ) VALUES (
    to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(h.assistant,'Système'),
    l.produit_id,l.nom,'ANNULATION',l.quantite,v_avant,v_apres,
    'Annulation article '||h.id,t.id,v_tenant_id
  );

  SELECT COALESCE(SUM(montant),0) INTO v_original_total
    FROM public.paiements
    WHERE tenant_id=v_tenant_id AND ticket_id=t.id
      AND montant>0 AND nature='ENCAISSEMENT';
  IF v_original_total <= 0 THEN v_original_total := GREATEST(0,t.montant_total+l.total); END IF;

  v_result := public._pharmasys_rembourser_ligne(
    t.id,l.id,l.total,v_original_total,COALESCE(h.assistant,'Système')
  );

  RETURN jsonb_build_object(
    'success',true,'ticket_id',t.id,'ligne_id',l.id,
    'stock_avant',v_avant,'stock_apres',v_apres,
    'remboursement',COALESCE((v_result->>'remboursement')::numeric,0)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.annuler_ligne_ticket(text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.annuler_article_ticket(p_ligne_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tenant_id uuid := current_tenant_id();
  l public.ticket_lignes%ROWTYPE;
  h_id text;
BEGIN
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  SELECT * INTO l FROM public.ticket_lignes
    WHERE id=p_ligne_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Article du ticket introuvable'; END IF;
  IF l.statut='ANNULEE' THEN RETURN jsonb_build_object('success',true,'already_cancelled',true); END IF;
  h_id := l.ticket_id || '-' || l.produit_id;
  RETURN public.annuler_ligne_ticket(h_id);
END;
$$;
GRANT EXECUTE ON FUNCTION public.annuler_article_ticket(bigint) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.annuler_ticket(p_ticket_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tenant_id uuid := current_tenant_id();
  t public.tickets%ROWTYPE;
  l public.ticket_lignes%ROWTYPE;
  v_avant numeric;
  v_apres numeric;
  v_total numeric := 0;
  v_count integer := 0;
  v_original_total numeric;
  v_ref text := p_ticket_id || ':T';
  pay record;
BEGIN
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  SELECT * INTO t FROM public.tickets WHERE id=p_ticket_id AND tenant_id=v_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ticket introuvable'; END IF;
  IF t.statut='ANNULEE' THEN RETURN jsonb_build_object('success',true,'already_cancelled',true,'ticket_id',p_ticket_id); END IF;

  v_original_total := COALESCE(t.montant_total,0);

  FOR l IN SELECT * FROM public.ticket_lignes
    WHERE ticket_id=p_ticket_id AND tenant_id=v_tenant_id AND statut='VALIDE'
    ORDER BY id FOR UPDATE
  LOOP
    SELECT stock INTO v_avant FROM public.inventaire
      WHERE id=l.produit_id AND tenant_id=v_tenant_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable : %',l.produit_id; END IF;
    v_apres := COALESCE(v_avant,0)+l.quantite;
    UPDATE public.inventaire SET stock=v_apres WHERE id=l.produit_id AND tenant_id=v_tenant_id;
    UPDATE public.ticket_lignes SET statut='ANNULEE' WHERE id=l.id;
    UPDATE public.historique_ventes SET statut='ANNULEE'
      WHERE tenant_id=v_tenant_id AND id=p_ticket_id||'-'||l.produit_id AND statut='VALIDE';
    INSERT INTO public.mouvements_stock(
      date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,observation,ticket,tenant_id
    ) VALUES(
      to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(t.assistant,'Système'),l.produit_id,l.nom,
      'ANNULATION',l.quantite,v_avant,v_apres,'Annulation ticket complet '||p_ticket_id,p_ticket_id,v_tenant_id
    );
    v_total := v_total+l.total;
    v_count := v_count+1;
  END LOOP;

  UPDATE public.tickets SET montant_total=0, benefice_total=0, nb_articles=0,
    montant_paye=0, montant_credit=0, statut='ANNULEE'
    WHERE id=p_ticket_id AND tenant_id=v_tenant_id;

  -- Une seule inversion financière par ticket, répartie sur les modes de paiement originaux.
  IF NOT public._pharmasys_remboursement_deja_cree(v_tenant_id,v_ref) THEN
    FOR pay IN SELECT id,montant,mode,client_id FROM public.paiements
      WHERE tenant_id=v_tenant_id AND ticket_id=p_ticket_id
        AND montant>0 AND nature='ENCAISSEMENT' ORDER BY id
    LOOP
      INSERT INTO public.paiements(
        ticket_id,client_id,montant,mode,observation,assistant,tenant_id,nature,reference_id
      ) VALUES(
        p_ticket_id,pay.client_id,-pay.montant,pay.mode,
        'Remboursement annulation ticket complet',COALESCE(t.assistant,'Système'),v_tenant_id,
        'REMBOURSEMENT',v_ref
      );
      IF pay.mode <> 'CREDIT' THEN
        INSERT INTO public.mouvements_caisse(
          type,montant,mode,motif,ticket_id,client_id,assistant,tenant_id,nature,reference_id,observation
        ) VALUES(
          'SORTIE',pay.montant,pay.mode,'Remboursement ticket '||p_ticket_id,
          p_ticket_id,pay.client_id,COALESCE(t.assistant,'Système'),v_tenant_id,
          'REMBOURSEMENT',v_ref,'Inverse du paiement #'||pay.id
        );
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success',true,'ticket_id',p_ticket_id,
    'lignes_annulees',v_count,'remboursement',v_total);
END;
$$;
GRANT EXECUTE ON FUNCTION public.annuler_ticket(text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Nouvelle fonction de mouvement de caisse : catégorisation stricte.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enregistrer_mouvement_caisse(
  p_type text,p_montant numeric,p_mode text,p_motif text,p_assistant text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE t uuid:=current_tenant_id();
BEGIN
  IF t IS NULL THEN RAISE EXCEPTION 'Session invalide'; END IF;
  IF p_type NOT IN ('ENTREE','SORTIE') OR p_montant<=0 THEN RAISE EXCEPTION 'Mouvement de caisse invalide'; END IF;
  INSERT INTO public.mouvements_caisse(
    type,montant,mode,motif,assistant,tenant_id,nature,reference_id,observation
  ) VALUES(
    p_type,p_montant,COALESCE(NULLIF(p_mode,''),'ESPECES'),COALESCE(p_motif,''),
    COALESCE(NULLIF(p_assistant,''),'Système'),t,
    CASE WHEN p_type='ENTREE' THEN 'ENTREE_MANUELLE' ELSE 'SORTIE_MANUELLE' END,
    NULL,COALESCE(p_motif,'')
  );
  RETURN jsonb_build_object('success',true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.enregistrer_mouvement_caisse(text,numeric,text,text,text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Rapport journalier : source unique pour trésorerie et caisse.
-- Les ventes annulées sont exclues du CA net et les remboursements sont des
-- sorties financières distinctes. Les crédits ne sont pas des encaissements.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_rapport_journalier(p_date date DEFAULT current_date)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  t uuid:=current_tenant_id();
  v_ca_brut numeric:=0; v_annulations numeric:=0; v_ca_net numeric:=0;
  v_benefice numeric:=0; v_entrees numeric:=0; v_sorties numeric:=0;
  v_remb numeric:=0; v_depenses numeric:=0; v_reglements numeric:=0;
  v_ouverture numeric:=0; v_solde numeric:=0;
  r record; m record;
  v_ticket_count integer:=0; v_cancel_count integer:=0;
  v_result jsonb;
BEGIN
  IF t IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  SELECT COALESCE(SUM(montant_total),0), COUNT(*) FILTER(WHERE statut='VALIDE'),
         COUNT(*) FILTER(WHERE statut='ANNULEE')
    INTO v_ca_net,v_ticket_count,v_cancel_count
    FROM public.tickets
    WHERE tenant_id=t AND date=p_date AND statut='VALIDE';

  SELECT COALESCE(SUM(total),0), COALESCE(SUM(profit),0)
    INTO v_annulations,v_benefice
    FROM public.historique_ventes
    WHERE tenant_id=t AND date=p_date AND statut='ANNULEE';

  v_ca_brut := v_ca_net + v_annulations;
  v_benefice := COALESCE((SELECT SUM(benefice_total) FROM public.tickets WHERE tenant_id=t AND date=p_date AND statut='VALIDE'),0);

  SELECT COALESCE(SUM(CASE WHEN type='ENTREE' THEN montant ELSE 0 END),0),
         COALESCE(SUM(CASE WHEN type='SORTIE' THEN montant ELSE 0 END),0),
         COALESCE(SUM(CASE WHEN type='SORTIE' AND nature='REMBOURSEMENT' THEN montant ELSE 0 END),0),
         COALESCE(SUM(CASE WHEN type='SORTIE' AND nature NOT IN ('REMBOURSEMENT','DEPOT_BANQUE') THEN montant ELSE 0 END),0),
         COALESCE(SUM(CASE WHEN type='ENTREE' AND nature='REGLEMENT_CREDIT' THEN montant ELSE 0 END),0)
    INTO v_entrees,v_sorties,v_remb,v_depenses,v_reglements
    FROM public.mouvements_caisse
    WHERE tenant_id=t AND created_at::date=p_date;

  SELECT COALESCE(SUM(CASE WHEN type='ENTREE' THEN montant ELSE -montant END),0)
    INTO v_ouverture
    FROM public.mouvements_caisse
    WHERE tenant_id=t AND created_at::date < p_date;
  v_solde := v_ouverture + v_entrees - v_sorties;

  v_result := jsonb_build_object(
    'date',p_date,
    'ventes',jsonb_build_object(
      'tickets',v_ticket_count,'tickets_annules',v_cancel_count,
      'ca_brut',v_ca_brut,'annulations',v_annulations,'ca_net',v_ca_net,
      'benefice_net',v_benefice
    ),
    'tresorerie',jsonb_build_object(
      'solde_ouverture',v_ouverture,'entrees',v_entrees,'sorties',v_sorties,
      'remboursements',v_remb,'depenses',v_depenses,'reglements_credit',v_reglements,
      'solde_cloture',v_solde
    ),
    'paiements',jsonb_build_object(
      'ESPECES',0,'MOBILE_MONEY',0,'CARTE',0,'CREDIT',0
    )
  );

  FOR r IN SELECT p.mode,
      COALESCE(SUM(CASE WHEN p.nature='ENCAISSEMENT' THEN p.montant ELSE 0 END),0) AS montant
    FROM public.paiements p
    WHERE p.tenant_id=t AND p.created_at::date=p_date
    GROUP BY p.mode LOOP
    v_result := jsonb_set(v_result,ARRAY['paiements',r.mode],to_jsonb(r.montant),true);
  END LOOP;

  v_result := jsonb_set(v_result,ARRAY['mouvements'],COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id',m.id,'type',m.type,'montant',m.montant,'mode',m.mode,'motif',m.motif,
      'nature',m.nature,'reference_id',m.reference_id,'ticket_id',m.ticket_id,
      'assistant',m.assistant,'created_at',m.created_at
    ) ORDER BY m.created_at DESC)
    FROM public.mouvements_caisse m
    WHERE m.tenant_id=t AND m.created_at::date=p_date
  ),'[]'::jsonb),true);

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_rapport_journalier(date) TO anon, authenticated;

-- Règlement de crédit catégorisé correctement.
CREATE OR REPLACE FUNCTION public.enregistrer_paiement_credit(
  p_client_id bigint,p_montant numeric,p_mode text,p_observation text,p_assistant text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE t uuid:=current_tenant_id();
BEGIN
  IF t IS NULL THEN RAISE EXCEPTION 'Session invalide'; END IF;
  IF p_montant<=0 OR NOT EXISTS(SELECT 1 FROM public.clients WHERE id=p_client_id AND tenant_id=t AND actif=true)
    THEN RAISE EXCEPTION 'Client ou montant invalide'; END IF;
  INSERT INTO public.paiements(client_id,montant,mode,observation,assistant,tenant_id,nature)
    VALUES(p_client_id,p_montant,COALESCE(NULLIF(p_mode,''),'ESPECES'),COALESCE(p_observation,'Règlement crédit'),COALESCE(NULLIF(p_assistant,''),'Système'),t,'REGLEMENT_CREDIT');
  INSERT INTO public.mouvements_caisse(type,montant,mode,motif,client_id,assistant,tenant_id,nature,observation)
    VALUES('ENTREE',p_montant,COALESCE(NULLIF(p_mode,''),'ESPECES'),'Règlement crédit',p_client_id,COALESCE(NULLIF(p_assistant,''),'Système'),t,'REGLEMENT_CREDIT',COALESCE(p_observation,''));
  RETURN jsonb_build_object('success',true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.enregistrer_paiement_credit(bigint,numeric,text,text,text) TO anon, authenticated;

-- Marquer les anciennes écritures comme vente/règlement lorsqu'elles n'ont pas
-- encore de nature, sans toucher aux montants historiques.
UPDATE public.mouvements_caisse SET nature='VENTE'
WHERE nature='MANUEL' AND ticket_id IS NOT NULL AND motif ILIKE 'Vente %';
UPDATE public.mouvements_caisse SET nature='REGLEMENT_CREDIT'
WHERE nature='MANUEL' AND motif ILIKE 'Règlement crédit%';
UPDATE public.paiements SET nature='ENCAISSEMENT'
WHERE nature='ENCAISSEMENT' OR nature IS NULL;

-- Toute entrée de caisse issue d'un ticket est automatiquement catégorisée VENTE,
-- y compris si l'ancienne RPC n'envoie pas encore la colonne nature.
CREATE OR REPLACE FUNCTION public.trg_pharmasys_caisse_nature()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF COALESCE(NEW.nature,'MANUEL')='MANUEL' AND NEW.ticket_id IS NOT NULL THEN
    NEW.nature := CASE WHEN NEW.type='ENTREE' THEN 'VENTE' ELSE 'SORTIE_TICKET' END;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_pharmasys_caisse_nature ON public.mouvements_caisse;
CREATE TRIGGER trg_pharmasys_caisse_nature
BEFORE INSERT ON public.mouvements_caisse
FOR EACH ROW EXECUTE FUNCTION public.trg_pharmasys_caisse_nature();

UPDATE public.mouvements_caisse
SET nature='VENTE'
WHERE ticket_id IS NOT NULL AND type='ENTREE' AND (nature IS NULL OR nature='MANUEL');
