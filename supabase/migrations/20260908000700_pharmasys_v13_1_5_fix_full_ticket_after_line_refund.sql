-- PharmaSys V13.1.5
-- Fix: full ticket cancellation after one or more line cancellations.
-- The full-ticket refund must only refund the REMAINING amount.
-- paiements.montant stays positive; cash reversal is represented by SORTIE.

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
  v_ref text := p_ticket_id || ':T';
  pay record;
  v_original numeric;
  v_refunded numeric;
  v_remaining numeric;
BEGIN
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;

  SELECT * INTO t
  FROM public.tickets
  WHERE id=p_ticket_id AND tenant_id=v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Ticket introuvable'; END IF;
  IF t.statut='ANNULEE' THEN
    RETURN jsonb_build_object('success',true,'already_cancelled',true,'ticket_id',p_ticket_id);
  END IF;

  -- Cancel only the lines still VALID. Lines already cancelled must never be
  -- refunded again and must not be counted in the remaining ticket amount.
  FOR l IN
    SELECT * FROM public.ticket_lignes
    WHERE ticket_id=p_ticket_id
      AND tenant_id=v_tenant_id
      AND statut='VALIDE'
    ORDER BY id
    FOR UPDATE
  LOOP
    SELECT stock INTO v_avant
    FROM public.inventaire
    WHERE id=l.produit_id AND tenant_id=v_tenant_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable : %',l.produit_id; END IF;

    v_apres := COALESCE(v_avant,0) + l.quantite;
    UPDATE public.inventaire SET stock=v_apres
    WHERE id=l.produit_id AND tenant_id=v_tenant_id;

    UPDATE public.ticket_lignes SET statut='ANNULEE'
    WHERE id=l.id AND tenant_id=v_tenant_id;

    UPDATE public.historique_ventes
    SET statut='ANNULEE'
    WHERE tenant_id=v_tenant_id
      AND id=p_ticket_id||'-'||l.produit_id
      AND statut='VALIDE';

    INSERT INTO public.mouvements_stock(
      date,assistant,produit_id,produit,type,quantite,stock_avant,stock_apres,
      observation,ticket,tenant_id
    ) VALUES (
      to_char(now(),'DD/MM/YYYY HH24:MI:SS'),COALESCE(t.assistant,'Système'),
      l.produit_id,l.nom,'ANNULATION',l.quantite,v_avant,v_apres,
      'Annulation ticket complet '||p_ticket_id,p_ticket_id,v_tenant_id
    );

    v_total := v_total + COALESCE(l.total,0);
    v_count := v_count + 1;
  END LOOP;

  -- Determine how much was originally paid and how much has ALREADY been
  -- refunded by previous line cancellations.
  SELECT COALESCE(SUM(p.montant),0) INTO v_original
  FROM public.paiements p
  WHERE p.tenant_id=v_tenant_id
    AND p.ticket_id=p_ticket_id
    AND p.montant>0
    AND p.nature='ENCAISSEMENT';

  SELECT COALESCE(SUM(p.montant),0) INTO v_refunded
  FROM public.paiements p
  WHERE p.tenant_id=v_tenant_id
    AND p.ticket_id=p_ticket_id
    AND p.montant>0
    AND p.nature='REMBOURSEMENT';

  v_remaining := GREATEST(0, v_original - v_refunded);

  UPDATE public.tickets
  SET montant_total=0, benefice_total=0, nb_articles=0,
      montant_paye=0, montant_credit=0, statut='ANNULEE'
  WHERE id=p_ticket_id AND tenant_id=v_tenant_id;

  -- Idempotent: do not create another complete-ticket reversal if it already exists.
  -- More importantly, when line refunds already exist, only the remaining amount
  -- is refunded here.
  IF v_remaining > 0 AND NOT public._pharmasys_remboursement_deja_cree(v_tenant_id,v_ref) THEN
    FOR pay IN
      SELECT
        p.id,
        p.montant,
        p.mode,
        p.client_id,
        GREATEST(
          0,
          p.montant - COALESCE((
            SELECT SUM(r.montant)
            FROM public.paiements r
            WHERE r.tenant_id=v_tenant_id
              AND r.ticket_id=p_ticket_id
              AND r.nature='REMBOURSEMENT'
              AND r.mode=p.mode
              AND r.montant>0
          ),0)
        ) AS restant_mode
      FROM public.paiements p
      WHERE p.tenant_id=v_tenant_id
        AND p.ticket_id=p_ticket_id
        AND p.montant>0
        AND p.nature='ENCAISSEMENT'
      ORDER BY p.id
    LOOP
      -- In normal cases v_remaining equals the sum of restant_mode. The LEAST
      -- protects against rounding/mixed-payment edge cases.
      IF pay.restant_mode > 0 AND v_remaining > 0 THEN
        DECLARE
          v_remboursement numeric := LEAST(pay.restant_mode, v_remaining);
        BEGIN
          INSERT INTO public.paiements(
            ticket_id,client_id,montant,mode,observation,assistant,tenant_id,nature,reference_id
          ) VALUES (
            p_ticket_id,pay.client_id,v_remboursement,pay.mode,
            'Remboursement annulation ticket complet',COALESCE(t.assistant,'Système'),
            v_tenant_id,'REMBOURSEMENT',v_ref
          );

          IF pay.mode <> 'CREDIT' THEN
            INSERT INTO public.mouvements_caisse(
              type,montant,mode,motif,ticket_id,client_id,assistant,tenant_id,
              nature,reference_id,observation
            ) VALUES (
              'SORTIE',v_remboursement,pay.mode,
              'Remboursement ticket '||p_ticket_id,p_ticket_id,pay.client_id,
              COALESCE(t.assistant,'Système'),v_tenant_id,'REMBOURSEMENT',v_ref,
              'Inverse du paiement #'||pay.id||' — solde restant après annulations de lignes'
            );
          END IF;

          v_remaining := v_remaining - v_remboursement;
        END;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'success',true,
    'ticket_id',p_ticket_id,
    'lignes_annulees',v_count,
    'remboursement',GREATEST(0,v_original-v_refunded),
    'remboursement_deja_effectue',v_refunded,
    'remboursement_total_original',v_original
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.annuler_ticket(text) TO anon, authenticated;
