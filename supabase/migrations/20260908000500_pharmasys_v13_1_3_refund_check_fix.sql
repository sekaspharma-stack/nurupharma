-- PharmaSys V13.1.3 - Fix paiements check constraint during refunds
-- IMPORTANT: refund amounts in paiements stay POSITIVE because paiements.montant
-- has a non-negative CHECK constraint. The financial outflow is represented by
-- mouvements_caisse.type='SORTIE'.

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
    WHERE tenant_id=t
      AND ticket_id=p_ticket_id
      AND montant > 0
      AND nature='ENCAISSEMENT'
    ORDER BY id
  LOOP
    v_refund := round(pay.montant * v_ratio, 2);
    IF v_refund <= 0 THEN CONTINUE; END IF;

    -- paiements.montant must remain >= 0. A refund is identified by nature
    -- and its cash effect is recorded as SORTIE below.
    INSERT INTO public.paiements(
      ticket_id, client_id, montant, mode, observation, assistant,
      tenant_id, nature, reference_id
    ) VALUES (
      p_ticket_id, pay.client_id, v_refund, pay.mode,
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

GRANT EXECUTE ON FUNCTION public._pharmasys_rembourser_ligne(text,bigint,numeric,numeric,text) TO anon, authenticated;

-- Ensure the report/payment views do not treat refund rows as new sales.
-- Existing report already filters nature='ENCAISSEMENT'; this index improves lookup.
CREATE INDEX IF NOT EXISTS idx_paiements_ticket_nature_positive
  ON public.paiements(tenant_id,ticket_id,nature,id)
  WHERE montant > 0;
