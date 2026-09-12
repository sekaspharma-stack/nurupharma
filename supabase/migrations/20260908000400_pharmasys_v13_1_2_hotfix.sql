-- PharmaSys V13.1.2 HOTFIX
-- Fixes the two production errors reported in console:
-- 1) get_rapport_journalier(): PL/pgSQL variable/SQL alias collision causing 55000
-- 2) annuler_article_ticket(): "Ticket introuvable" for ticket IDs containing '-'
--
-- IMPORTANT: this migration is safe to run after V13.1/V13.1.1.

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
  v_ticket_id text;
  v_suffix text;
BEGIN
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  SELECT * INTO h
  FROM public.historique_ventes AS hv
  WHERE hv.id=p_historique_id AND hv.tenant_id=v_tenant_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ligne de vente introuvable'; END IF;

  IF h.statut='ANNULEE' THEN
    RETURN jsonb_build_object('success',true,'already_cancelled',true,'message','Ligne déjà annulée');
  END IF;

  -- History IDs created by valider_vente are: ticket_id || '-' || produit_id.
  -- NEVER use split_part(..., '-', 1): ticket IDs themselves may contain '-'.
  v_suffix := '-' || h.produit_id::text;
  IF right(h.id, length(v_suffix)) = v_suffix THEN
    v_ticket_id := left(h.id, length(h.id) - length(v_suffix));
  END IF;

  IF COALESCE(v_ticket_id,'') = '' THEN
    RAISE EXCEPTION 'Référence de ticket invalide pour la ligne %', p_historique_id;
  END IF;

  SELECT * INTO t
  FROM public.tickets AS tk
  WHERE tk.id=v_ticket_id AND tk.tenant_id=v_tenant_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ticket introuvable : %', v_ticket_id;
  END IF;

  SELECT * INTO l
  FROM public.ticket_lignes AS tl
  WHERE tl.ticket_id=t.id
    AND tl.produit_id=h.produit_id
    AND tl.statut='VALIDE'
    AND tl.tenant_id=v_tenant_id
  ORDER BY tl.id
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ligne de ticket déjà annulée ou introuvable'; END IF;

  SELECT inv.stock INTO v_avant
  FROM public.inventaire AS inv
  WHERE inv.id=l.produit_id AND inv.tenant_id=v_tenant_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable'; END IF;

  v_apres := COALESCE(v_avant,0) + l.quantite;
  UPDATE public.inventaire AS inv SET stock=v_apres
  WHERE inv.id=l.produit_id AND inv.tenant_id=v_tenant_id;

  UPDATE public.ticket_lignes AS tl
  SET statut='ANNULEE'
  WHERE tl.id=l.id AND tl.tenant_id=v_tenant_id AND tl.statut='VALIDE';

  UPDATE public.historique_ventes AS hv
  SET statut='ANNULEE'
  WHERE hv.id=h.id AND hv.tenant_id=v_tenant_id AND hv.statut='VALIDE';

  UPDATE public.tickets AS tk
  SET montant_total=GREATEST(0,tk.montant_total-l.total),
      benefice_total=GREATEST(0,tk.benefice_total-l.profit),
      nb_articles=GREATEST(0,tk.nb_articles-l.quantite),
      montant_paye=GREATEST(0,tk.montant_paye-CASE WHEN tk.montant_paye>0 THEN LEAST(tk.montant_paye,l.total) ELSE 0 END),
      montant_credit=GREATEST(0,tk.montant_credit-CASE WHEN tk.montant_credit>0 THEN LEAST(tk.montant_credit,l.total) ELSE 0 END),
      statut=CASE WHEN NOT EXISTS (
        SELECT 1 FROM public.ticket_lignes AS tl2
        WHERE tl2.ticket_id=tk.id AND tl2.tenant_id=v_tenant_id AND tl2.statut='VALIDE'
      ) THEN 'ANNULEE' ELSE tk.statut END
  WHERE tk.id=t.id AND tk.tenant_id=v_tenant_id;

  INSERT INTO public.mouvements_stock(
    date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,
    observation,ticket,tenant_id
  ) VALUES (
    to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(h.assistant,'Système'),
    l.produit_id,l.nom,'ANNULATION',l.quantite,v_avant,v_apres,
    'Annulation article '||h.id||' — stock restitué et remboursement calculé',t.id,v_tenant_id
  );

  SELECT COALESCE(SUM(p.montant),0) INTO v_original_total
  FROM public.paiements AS p
  WHERE p.tenant_id=v_tenant_id
    AND p.ticket_id=t.id
    AND p.montant>0
    AND p.nature='ENCAISSEMENT';

  IF v_original_total <= 0 THEN
    v_original_total := GREATEST(0,t.montant_total+l.total);
  END IF;

  v_result := public._pharmasys_rembourser_ligne(
    t.id,l.id,l.total,v_original_total,COALESCE(h.assistant,'Système')
  );

  RETURN jsonb_build_object(
    'success',true,
    'ticket_id',t.id,
    'ligne_id',l.id,
    'stock_avant',v_avant,
    'stock_apres',v_apres,
    'remboursement',COALESCE((v_result->>'remboursement')::numeric,0),
    'message','Article annulé : stock restitué et remboursement enregistré'
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

  SELECT * INTO l
  FROM public.ticket_lignes AS tl
  WHERE tl.id=p_ligne_id AND tl.tenant_id=v_tenant_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Article du ticket introuvable : %', p_ligne_id; END IF;

  IF l.statut='ANNULEE' THEN
    RETURN jsonb_build_object('success',true,'already_cancelled',true,'message','Article déjà annulé');
  END IF;

  -- Same exact convention as valider_vente(). This preserves the complete ticket ID.
  h_id := l.ticket_id || '-' || l.produit_id::text;
  RETURN public.annuler_ligne_ticket(h_id);
END;
$$;
GRANT EXECUTE ON FUNCTION public.annuler_article_ticket(bigint) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_rapport_journalier(p_date date DEFAULT current_date)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tenant_id uuid := current_tenant_id();
  v_ca_brut numeric := 0;
  v_annulations numeric := 0;
  v_ca_net numeric := 0;
  v_benefice numeric := 0;
  v_entrees numeric := 0;
  v_sorties numeric := 0;
  v_remb numeric := 0;
  v_depenses numeric := 0;
  v_reglements numeric := 0;
  v_ouverture numeric := 0;
  v_solde numeric := 0;
  v_ticket_count integer := 0;
  v_cancel_count integer := 0;
  v_result jsonb;
  v_mode_row record;
BEGIN
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  -- Counts and net CA: valid tickets only for the net figure.
  SELECT
    COALESCE(SUM(tk.montant_total) FILTER (WHERE tk.statut='VALIDE'),0),
    COUNT(*) FILTER (WHERE tk.statut='VALIDE'),
    COUNT(*) FILTER (WHERE tk.statut='ANNULEE')
  INTO v_ca_net,v_ticket_count,v_cancel_count
  FROM public.tickets AS tk
  WHERE tk.tenant_id=v_tenant_id
    AND tk.date=p_date;

  -- Cancelled history keeps the original value, so gross = net + cancelled value.
  SELECT COALESCE(SUM(hv.total),0)
  INTO v_annulations
  FROM public.historique_ventes AS hv
  WHERE hv.tenant_id=v_tenant_id
    AND hv.date=p_date
    AND hv.statut='ANNULEE';

  v_ca_brut := v_ca_net + v_annulations;

  SELECT COALESCE(SUM(tk.benefice_total),0)
  INTO v_benefice
  FROM public.tickets AS tk
  WHERE tk.tenant_id=v_tenant_id
    AND tk.date=p_date
    AND tk.statut='VALIDE';

  SELECT
    COALESCE(SUM(CASE WHEN mc.type='ENTREE' THEN mc.montant ELSE 0 END),0),
    COALESCE(SUM(CASE WHEN mc.type='SORTIE' THEN mc.montant ELSE 0 END),0),
    COALESCE(SUM(CASE WHEN mc.type='SORTIE' AND mc.nature='REMBOURSEMENT' THEN mc.montant ELSE 0 END),0),
    COALESCE(SUM(CASE WHEN mc.type='SORTIE' AND mc.nature NOT IN ('REMBOURSEMENT','DEPOT_BANQUE') THEN mc.montant ELSE 0 END),0),
    COALESCE(SUM(CASE WHEN mc.type='ENTREE' AND mc.nature='REGLEMENT_CREDIT' THEN mc.montant ELSE 0 END),0)
  INTO v_entrees,v_sorties,v_remb,v_depenses,v_reglements
  FROM public.mouvements_caisse AS mc
  WHERE mc.tenant_id=v_tenant_id
    AND mc.created_at::date=p_date;

  SELECT COALESCE(SUM(CASE WHEN mc.type='ENTREE' THEN mc.montant ELSE -mc.montant END),0)
  INTO v_ouverture
  FROM public.mouvements_caisse AS mc
  WHERE mc.tenant_id=v_tenant_id
    AND mc.created_at::date < p_date;

  v_solde := v_ouverture + v_entrees - v_sorties;

  v_result := jsonb_build_object(
    'date',p_date,
    'ventes',jsonb_build_object(
      'tickets',v_ticket_count,
      'tickets_annules',v_cancel_count,
      'ca_brut',v_ca_brut,
      'annulations',v_annulations,
      'ca_net',v_ca_net,
      'benefice_net',v_benefice
    ),
    'tresorerie',jsonb_build_object(
      'solde_ouverture',v_ouverture,
      'entrees',v_entrees,
      'sorties',v_sorties,
      'remboursements',v_remb,
      'depenses',v_depenses,
      'reglements_credit',v_reglements,
      'solde_cloture',v_solde
    ),
    'paiements',jsonb_build_object(
      'ESPECES',0,
      'MOBILE_MONEY',0,
      'CARTE',0,
      'CREDIT',0
    )
  );

  FOR v_mode_row IN
    SELECT p.mode AS payment_mode,
           COALESCE(SUM(p.montant),0) AS payment_amount
    FROM public.paiements AS p
    WHERE p.tenant_id=v_tenant_id
      AND p.created_at::date=p_date
      AND p.nature='ENCAISSEMENT'
    GROUP BY p.mode
  LOOP
    v_result := jsonb_set(
      v_result,
      ARRAY['paiements',COALESCE(v_mode_row.payment_mode,'ESPECES')],
      to_jsonb(v_mode_row.payment_amount),
      true
    );
  END LOOP;

  v_result := jsonb_set(
    v_result,
    ARRAY['mouvements'],
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',mc2.id,
          'type',mc2.type,
          'montant',mc2.montant,
          'mode',mc2.mode,
          'motif',mc2.motif,
          'nature',mc2.nature,
          'reference_id',mc2.reference_id,
          'ticket_id',mc2.ticket_id,
          'assistant',mc2.assistant,
          'created_at',mc2.created_at
        ) ORDER BY mc2.created_at DESC
      )
      FROM public.mouvements_caisse AS mc2
      WHERE mc2.tenant_id=v_tenant_id
        AND mc2.created_at::date=p_date
    ),'[]'::jsonb),
    true
  );

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_rapport_journalier(date) TO anon, authenticated;

-- Optional but useful: keep a clear marker that this hotfix has been applied.
CREATE TABLE IF NOT EXISTS public.pharmasys_migrations_meta (
  id text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.pharmasys_migrations_meta(id)
VALUES ('V13.1.2_FINANCE_CAISSE_HOTFIX')
ON CONFLICT (id) DO NOTHING;
