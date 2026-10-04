-- PharmaSys V13.1.4 - Fix full-ticket cancellation refunds.
-- paiements.montant must stay positive; the cash effect is a SORTIE.

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
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Session invalide ou expirée';
  END IF;

  SELECT * INTO t
  FROM public.tickets
  WHERE id = p_ticket_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Ticket introuvable'; END IF;
  IF t.statut = 'ANNULEE' THEN
    RETURN jsonb_build_object('success',true,'already_cancelled',true,'ticket_id',p_ticket_id);
  END IF;

  FOR l IN
    SELECT * FROM public.ticket_lignes
    WHERE ticket_id=p_ticket_id AND tenant_id=v_tenant_id AND statut='VALIDE'
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

    UPDATE public.ticket_lignes SET statut='ANNULEE' WHERE id=l.id;

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

  UPDATE public.tickets
  SET montant_total=0, benefice_total=0, nb_articles=0,
      montant_paye=0, montant_credit=0, statut='ANNULEE'
  WHERE id=p_ticket_id AND tenant_id=v_tenant_id;

  -- Idempotent: one financial reversal reference per ticket.
  IF NOT public._pharmasys_remboursement_deja_cree(v_tenant_id,v_ref) THEN
    FOR pay IN
      SELECT id,montant,mode,client_id
      FROM public.paiements
      WHERE tenant_id=v_tenant_id
        AND ticket_id=p_ticket_id
        AND montant > 0
        AND nature='ENCAISSEMENT'
      ORDER BY id
    LOOP
      -- IMPORTANT: paiements.montant remains positive because of its CHECK constraint.
      INSERT INTO public.paiements(
        ticket_id,client_id,montant,mode,observation,assistant,tenant_id,nature,reference_id
      ) VALUES (
        p_ticket_id,pay.client_id,ABS(pay.montant),pay.mode,
        'Remboursement annulation ticket complet',COALESCE(t.assistant,'Système'),
        v_tenant_id,'REMBOURSEMENT',v_ref
      );

      IF pay.mode <> 'CREDIT' THEN
        INSERT INTO public.mouvements_caisse(
          type,montant,mode,motif,ticket_id,client_id,assistant,tenant_id,
          nature,reference_id,observation
        ) VALUES (
          'SORTIE',ABS(pay.montant),pay.mode,
          'Remboursement ticket '||p_ticket_id,p_ticket_id,pay.client_id,
          COALESCE(t.assistant,'Système'),v_tenant_id,'REMBOURSEMENT',v_ref,
          'Inverse du paiement #'||pay.id
        );
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'success',true,
    'ticket_id',p_ticket_id,
    'lignes_annulees',v_count,
    'remboursement',v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.annuler_ticket(text) TO anon, authenticated;
