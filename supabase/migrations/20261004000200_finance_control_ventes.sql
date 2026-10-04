-- ============================================================
-- PharmaSys - Finance periodique + controle physique des ventes
-- Performance-first: agrégations côté serveur et chargements ciblés.
-- ============================================================

ALTER TABLE public.mouvements_stock ADD COLUMN IF NOT EXISTS assistant_id bigint;
ALTER TABLE public.controles_inventaire ADD COLUMN IF NOT EXISTS assistant_id bigint;
ALTER TABLE public.controles_inventaire ADD COLUMN IF NOT EXISTS vente_date date;
ALTER TABLE public.controles_inventaire ADD COLUMN IF NOT EXISTS quantite_vendue numeric DEFAULT 0;
ALTER TABLE public.controles_inventaire ADD COLUMN IF NOT EXISTS stock_attendu numeric DEFAULT 0;
ALTER TABLE public.controles_inventaire ADD COLUMN IF NOT EXISTS source text DEFAULT 'INVENTAIRE';
ALTER TABLE public.mouvements_caisse ADD COLUMN IF NOT EXISTS assistant_id bigint;

CREATE INDEX IF NOT EXISTS idx_mouvements_stock_tenant_date
ON public.mouvements_stock(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mouvements_stock_tenant_assistant
ON public.mouvements_stock(tenant_id, assistant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mouvements_stock_tenant_type_date
ON public.mouvements_stock(tenant_id, type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_controles_vente_tenant_date
ON public.controles_inventaire(tenant_id, vente_date, assistant_id);

-- ============================================================
-- Finance: une seule RPC pour les KPI d'une période.
-- Elle ne télécharge pas tout l'historique au navigateur.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_finance_period_summary(
  p_date_debut date,
  p_date_fin date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_tenant uuid := current_tenant_id();
  v_result jsonb;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  IF p_date_debut IS NULL OR p_date_fin IS NULL OR p_date_debut > p_date_fin THEN
    RAISE EXCEPTION 'Période financière invalide';
  END IF;
  IF NOT is_current_admin() THEN RAISE EXCEPTION 'Accès réservé à l’administration'; END IF;

  WITH sales AS (
    SELECT t.id,t.assistant_id,t.assistant,t.montant_total,t.benefice_total,t.montant_credit,t.date
    FROM public.tickets t
    WHERE t.tenant_id=v_tenant AND t.statut='VALIDE'
      AND t.date BETWEEN p_date_debut AND p_date_fin
  ),
  exp AS (
    SELECT mc.id,mc.assistant_id,mc.assistant,mc.montant,mc.motif,mc.created_at
    FROM public.mouvements_caisse mc
    WHERE mc.tenant_id=v_tenant AND mc.type='SORTIE' AND mc.nature='DEPENSE'
      AND mc.created_at >= p_date_debut::timestamptz
      AND mc.created_at < (p_date_fin + 1)::timestamptz
  ),
  pay AS (
    SELECT COALESCE(SUM(p.montant) FILTER (WHERE p.nature='REGLEMENT_CREDIT'),0) AS reglements
    FROM public.paiements p
    WHERE p.tenant_id=v_tenant
      AND p.created_at >= p_date_debut::timestamptz
      AND p.created_at < (p_date_fin + 1)::timestamptz
  ),
  credit_sales AS (
    SELECT t.client_id,COALESCE(SUM(t.montant_credit),0) montant
    FROM public.tickets t
    WHERE t.tenant_id=v_tenant AND t.statut='VALIDE' AND t.montant_credit>0 AND t.client_id IS NOT NULL
    GROUP BY t.client_id
  ),
  credit_payments AS (
    SELECT p.client_id,COALESCE(SUM(p.montant),0) montant
    FROM public.paiements p
    WHERE p.tenant_id=v_tenant AND p.nature='REGLEMENT_CREDIT' AND p.montant>0 AND p.client_id IS NOT NULL
    GROUP BY p.client_id
  ),
  balances AS (
    SELECT c.id AS client_id,c.nom AS client_nom,c.telephone,
      GREATEST(0,COALESCE(cs.montant,0)-COALESCE(cp.montant,0)) AS solde
    FROM public.clients c
    LEFT JOIN credit_sales cs ON cs.client_id=c.id
    LEFT JOIN credit_payments cp ON cp.client_id=c.id
    WHERE c.tenant_id=v_tenant AND c.actif=true
  ),
  assistant_sales AS (
    SELECT s.assistant_id,COALESCE(s.assistant,'Système') assistant,COALESCE(SUM(s.montant_total),0) ventes,COALESCE(SUM(s.montant_credit),0) dettes
    FROM sales s GROUP BY s.assistant_id,COALESCE(s.assistant,'Système')
  ),
  assistant_exp AS (
    SELECT e.assistant_id,COALESCE(e.assistant,'Système') assistant,COALESCE(SUM(e.montant),0) depenses
    FROM exp e GROUP BY e.assistant_id,COALESCE(e.assistant,'Système')
  ),
  assistant_rows AS (
    SELECT COALESCE(a.assistant_id,b.assistant_id) assistant_id,COALESCE(a.assistant,b.assistant,'Système') assistant,
           COALESCE(a.ventes,0) ventes,COALESCE(a.dettes,0) dettes,COALESCE(b.depenses,0) depenses
    FROM assistant_sales a FULL OUTER JOIN assistant_exp b ON b.assistant_id=a.assistant_id
  ),
  cash AS (
    SELECT COALESCE(SUM(m.montant) FILTER (WHERE m.type='ENTREE'),0) entrees,
           COALESCE(SUM(m.montant) FILTER (WHERE m.type='SORTIE'),0) sorties
    FROM public.mouvements_caisse m
    WHERE m.tenant_id=v_tenant AND m.created_at >= p_date_debut::timestamptz AND m.created_at < (p_date_fin+1)::timestamptz
  )
  SELECT jsonb_build_object(
    'date_debut',p_date_debut,
    'date_fin',p_date_fin,
    'ventes_totales',COALESCE((SELECT SUM(montant_total) FROM sales),0),
    'marge_brute',COALESCE((SELECT SUM(benefice_total) FROM sales),0),
    'dettes_creees',COALESCE((SELECT SUM(montant_credit) FROM sales),0),
    'depenses',COALESCE((SELECT SUM(montant) FROM exp),0),
    'tickets',COALESCE((SELECT COUNT(*) FROM sales),0),
    'reglements_credits',COALESCE((SELECT reglements FROM pay),0),
    'dette_restante',COALESCE((SELECT SUM(solde) FROM balances),0),
    'net_encaisse_ajuste',COALESCE((SELECT SUM(montant_total) FROM sales),0)
      - COALESCE((SELECT SUM(montant_credit) FROM sales),0)
      - COALESCE((SELECT SUM(montant) FROM exp),0),
    'caisse_entrees',COALESCE((SELECT entrees FROM cash),0),
    'caisse_sorties',COALESCE((SELECT sorties FROM cash),0),
    'caisse_solde',COALESCE((SELECT entrees-sorties FROM cash),0),
    'assistants',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'assistant_id',assistant_id,'assistant',assistant,'ventes',ventes,'dettes',dettes,'depenses',depenses,
        'net',ventes-dettes-depenses) ORDER BY ventes DESC,assistant
      ) FROM assistant_rows),'[]'::jsonb),
    'depenses_detail',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',id,'assistant',assistant,'montant',montant,'motif',motif,'date',to_char(created_at,'DD/MM/YYYY HH24:MI')
      ) ORDER BY created_at DESC) FROM exp),'[]'::jsonb),
    'credit_clients',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'client_id',b.client_id,'client_nom',b.client_nom,'telephone',b.telephone,'solde',b.solde,
        'assistants',COALESCE((SELECT string_agg(DISTINCT COALESCE(t.assistant,'Système'),', ') FROM public.tickets t WHERE t.tenant_id=v_tenant AND t.client_id=b.client_id AND t.statut='VALIDE' AND t.montant_credit>0),'')
      ) ORDER BY b.solde DESC) FROM balances b WHERE b.solde>0),'[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_finance_period_summary(date,date) TO anon, authenticated;

-- ============================================================
-- Contrôle physique des ventes: mouvements séquentiels de la veille.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_sales_control_day(p_date date)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_tenant uuid:=current_tenant_id(); v_result jsonb;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  IF NOT is_current_admin() THEN RAISE EXCEPTION 'Accès réservé à l’administration'; END IF;

  WITH rows AS (
    SELECT ms.id,ms.created_at,ms.assistant_id,ms.assistant,ms.produit_id,ms.produit,ms.quantite,ms.stock_avant,ms.stock_apres,ms.ticket
    FROM public.mouvements_stock ms
    WHERE ms.tenant_id=v_tenant AND ms.type='VENTE'
      AND ms.created_at >= p_date::timestamptz
      AND ms.created_at < (p_date+1)::timestamptz
    ORDER BY ms.created_at ASC,ms.id ASC
  )
  SELECT jsonb_build_object(
    'date',p_date,
    'tickets',COALESCE((SELECT COUNT(DISTINCT ticket) FROM rows),0),
    'articles',COALESCE((SELECT SUM(quantite) FROM rows),0),
    'ca',COALESCE((SELECT SUM(t.montant_total) FROM public.tickets t WHERE t.tenant_id=v_tenant AND t.date=p_date AND t.statut='VALIDE'),0),
    'assistants_count',COALESCE((SELECT COUNT(DISTINCT COALESCE(assistant_id::text,assistant)) FROM rows),0),
    'movements',COALESCE((SELECT jsonb_agg(to_jsonb(rows) ORDER BY created_at,id) FROM rows),'[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_sales_control_day(date) TO anon, authenticated;

-- Enregistrement sécurisé d'un pointage lié au mouvement de vente.
CREATE OR REPLACE FUNCTION public.enregistrer_controle_vente(
  p_mouvement_id bigint,
  p_produit_id bigint,
  p_vente_date date,
  p_assistant_id bigint,
  p_assistant text,
  p_produit_nom text,
  p_quantite_vendue numeric,
  p_stock_attendu numeric,
  p_stock_physique numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_tenant uuid:=current_tenant_id(); v_id bigint; v_ecart numeric; v_real_assistant_id bigint; v_real_assistant text; v_real_product_id bigint; v_real_product text; v_real_stock numeric; v_real_qty numeric; v_real_date date;
BEGIN
  IF v_tenant IS NULL OR NOT is_current_admin() THEN RAISE EXCEPTION 'Accès réservé à l’administration'; END IF;
  SELECT ms.assistant_id,ms.assistant,ms.produit_id,ms.produit,ms.stock_apres,ms.quantite,ms.created_at::date
    INTO v_real_assistant_id,v_real_assistant,v_real_product_id,v_real_product,v_real_stock,v_real_qty,v_real_date
  FROM public.mouvements_stock ms
  WHERE ms.id=p_mouvement_id AND ms.tenant_id=v_tenant AND ms.type='VENTE';
  IF v_real_product_id IS NULL THEN RAISE EXCEPTION 'Mouvement de vente introuvable'; END IF;
  IF v_real_assistant_id IS NULL AND v_real_assistant IS NOT NULL THEN
    SELECT u.id INTO v_real_assistant_id FROM public.utilisateurs u
    WHERE u.tenant_id=v_tenant AND u.actif=true AND lower(trim(u.nom))=lower(trim(v_real_assistant))
    ORDER BY u.id LIMIT 1;
  END IF;
  IF p_stock_physique IS NULL OR p_stock_physique<0 THEN RAISE EXCEPTION 'Pointage invalide'; END IF;
  v_ecart:=p_stock_physique-v_real_stock;
  INSERT INTO public.controles_inventaire(
    produit_id,produit_nom,stock_systeme,stock_physique,ecart,valeur_ecart,statut,cause,observation,stock_corrige,auteur,date_controle,tenant_id,
    assistant_id,vente_date,quantite_vendue,stock_attendu,source
  ) VALUES (
    v_real_product_id,COALESCE(v_real_product,p_produit_nom,''),v_real_stock,p_stock_physique,v_ecart,0,
    CASE WHEN v_ecart=0 THEN 'CONFORME' ELSE 'A_ANALYSER' END,NULL,
    'Pointage vente du '||COALESCE(v_real_date,p_vente_date)::text||' · Assistant: '||COALESCE(v_real_assistant,p_assistant,'Système'),false,
    COALESCE(v_real_assistant,p_assistant,'Administration'),now(),v_tenant,v_real_assistant_id,COALESCE(v_real_date,p_vente_date),COALESCE(v_real_qty,p_quantite_vendue),v_real_stock,'VENTE'
  ) RETURNING id INTO v_id;
  RETURN jsonb_build_object('success',true,'id',v_id,'ecart',v_ecart);
END;
$$;
GRANT EXECUTE ON FUNCTION public.enregistrer_controle_vente(bigint,bigint,date,bigint,text,text,numeric,numeric,numeric) TO anon, authenticated;

-- ============================================================
-- Mettre à jour valider_vente pour tracer assistant_id dans le stock
-- et les entrées de caisse. Contrat inchangé: 7 arguments.
-- ============================================================
DROP FUNCTION IF EXISTS public.valider_vente(text,date,text,text,bigint,jsonb);
DROP FUNCTION IF EXISTS public.valider_vente(text,date,text,text,bigint,jsonb,jsonb);

CREATE OR REPLACE FUNCTION public.valider_vente(
    p_ticket_id text,p_date date,p_heure text,p_assistant text,p_assistant_id bigint,p_lignes jsonb,p_paiements jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_tenant_id uuid:=current_tenant_id(); v_ligne jsonb; v_pay jsonb; v_produit_id bigint; v_quantite numeric;
    v_stock_avant numeric; v_stock_apres numeric; v_pua numeric; v_pvu numeric; v_nom text;
    v_total numeric:=0; v_profit numeric:=0; v_nb_articles numeric:=0; v_paytotal numeric:=0; v_mode_paiement text:='ESPECES';
    v_client_id bigint:=NULL; v_credit numeric:=0; v_payments jsonb:=COALESCE(p_paiements,'[]'::jsonb);
BEGIN
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
    IF COALESCE(trim(p_ticket_id),'')='' THEN RAISE EXCEPTION 'Numéro de ticket invalide'; END IF;
    IF p_lignes IS NULL OR jsonb_typeof(p_lignes)<>'array' OR jsonb_array_length(p_lignes)=0 THEN RAISE EXCEPTION 'Le panier est vide'; END IF;
    IF EXISTS(SELECT 1 FROM public.tickets t WHERE t.id=p_ticket_id AND t.tenant_id=v_tenant_id) THEN RAISE EXCEPTION 'Ce ticket existe déjà'; END IF;

    FOR v_ligne IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
      v_produit_id:=NULLIF(v_ligne->>'produit_id','')::bigint; v_quantite:=NULLIF(v_ligne->>'quantite','')::numeric;
      IF v_produit_id IS NULL OR v_quantite IS NULL OR v_quantite<=0 THEN RAISE EXCEPTION 'Produit ou quantité invalide'; END IF;
      SELECT p.nom,p.stock,p.pua,p.pvu INTO v_nom,v_stock_avant,v_pua,v_pvu FROM public.inventaire p WHERE p.id=v_produit_id AND p.tenant_id=v_tenant_id AND p.actif=true FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Produit introuvable : %',v_produit_id; END IF;
      IF COALESCE(v_stock_avant,0)<v_quantite THEN RAISE EXCEPTION 'Stock insuffisant pour %. Disponible: %, demandé: %',v_nom,v_stock_avant,v_quantite; END IF;
      v_nb_articles:=v_nb_articles+v_quantite; v_total:=v_total+v_quantite*COALESCE(v_pvu,0); v_profit:=v_profit+v_quantite*(COALESCE(v_pvu,0)-COALESCE(v_pua,0));
    END LOOP;

    FOR v_pay IN SELECT * FROM jsonb_array_elements(v_payments) LOOP
      IF NULLIF(v_pay->>'montant','')::numeric IS NULL OR (v_pay->>'montant')::numeric<=0 THEN RAISE EXCEPTION 'Montant de paiement invalide'; END IF;
      v_paytotal:=v_paytotal+(v_pay->>'montant')::numeric;
    END LOOP;
    IF jsonb_array_length(COALESCE(p_paiements,'[]'::jsonb))=0 THEN v_payments:=jsonb_build_array(jsonb_build_object('mode','ESPECES','montant',v_total)); v_paytotal:=v_total; END IF;
    IF ABS(v_paytotal-v_total)>0.01 THEN RAISE EXCEPTION 'Les paiements (%,) ne correspondent pas au total (%)',v_paytotal,v_total; END IF;

    FOR v_pay IN SELECT * FROM jsonb_array_elements(v_payments) LOOP
      IF COALESCE(v_pay->>'mode','ESPECES')='CREDIT' THEN
        IF NULLIF(v_pay->>'client_id','')::bigint IS NULL THEN RAISE EXCEPTION 'Un client est obligatoire pour un crédit'; END IF;
        IF v_client_id IS NULL THEN v_client_id:=NULLIF(v_pay->>'client_id','')::bigint; ELSIF v_client_id<>NULLIF(v_pay->>'client_id','')::bigint THEN RAISE EXCEPTION 'Un seul client peut porter le crédit d’une vente'; END IF;
        IF NOT EXISTS(SELECT 1 FROM public.clients c WHERE c.id=v_client_id AND c.tenant_id=v_tenant_id AND c.actif=true) THEN RAISE EXCEPTION 'Client crédit introuvable'; END IF;
        v_credit:=v_credit+(v_pay->>'montant')::numeric;
      END IF;
    END LOOP;
    IF jsonb_array_length(v_payments)>1 THEN v_mode_paiement:='MIXTE'; ELSE v_mode_paiement:=COALESCE(v_payments->0->>'mode','ESPECES'); END IF;

    INSERT INTO public.tickets(id,date,heure,assistant,assistant_id,nb_articles,montant_total,benefice_total,statut,mode_paiement,client_id,montant_paye,montant_credit,tenant_id)
    VALUES(p_ticket_id,p_date,p_heure,p_assistant,p_assistant_id,v_nb_articles,v_total,v_profit,'VALIDE',v_mode_paiement,v_client_id,v_total-v_credit,v_credit,v_tenant_id);

    FOR v_ligne IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
      v_produit_id:=(v_ligne->>'produit_id')::bigint; v_quantite:=(v_ligne->>'quantite')::numeric;
      SELECT p.nom,p.stock,p.pua,p.pvu INTO v_nom,v_stock_avant,v_pua,v_pvu FROM public.inventaire p WHERE p.id=v_produit_id AND p.tenant_id=v_tenant_id FOR UPDATE;
      v_stock_apres:=v_stock_avant-v_quantite;
      UPDATE public.inventaire p SET stock=v_stock_apres WHERE p.id=v_produit_id AND p.tenant_id=v_tenant_id;
      INSERT INTO public.ticket_lignes(ticket_id,produit_id,nom,quantite,pua,pvu,total,profit,statut,tenant_id) VALUES(p_ticket_id,v_produit_id,v_nom,v_quantite,v_pua,v_pvu,v_quantite*COALESCE(v_pvu,0),v_quantite*(COALESCE(v_pvu,0)-COALESCE(v_pua,0)),'VALIDE',v_tenant_id);
      INSERT INTO public.historique_ventes(id,date,heure,assistant,assistant_id,produit_id,nom,quantite,pua,pvu,total,profit,statut,tenant_id) VALUES(p_ticket_id||'-'||v_produit_id,p_date,p_heure,p_assistant,p_assistant_id,v_produit_id,v_nom,v_quantite,v_pua,v_pvu,v_quantite*COALESCE(v_pvu,0),v_quantite*(COALESCE(v_pvu,0)-COALESCE(v_pua,0)),'VALIDE',v_tenant_id);
      INSERT INTO public.mouvements_stock(date,assistant,assistant_id,produit_id,produit,type,quantite,stock_avant,stock_apres,observation,ticket,tenant_id) VALUES(to_char(now(),'DD/MM/YYYY HH24:MI:SS'),p_assistant,p_assistant_id,v_produit_id,v_nom,'VENTE',v_quantite,v_stock_avant,v_stock_apres,'Vente '||p_ticket_id,p_ticket_id,v_tenant_id);
    END LOOP;

    FOR v_pay IN SELECT * FROM jsonb_array_elements(v_payments) LOOP
      INSERT INTO public.paiements(ticket_id,client_id,montant,mode,observation,assistant,tenant_id) VALUES(p_ticket_id,NULLIF(v_pay->>'client_id','')::bigint,(v_pay->>'montant')::numeric,COALESCE(v_pay->>'mode','ESPECES'),'Paiement vente',p_assistant,v_tenant_id);
      IF COALESCE(v_pay->>'mode','ESPECES')<>'CREDIT' THEN
        INSERT INTO public.mouvements_caisse(type,montant,mode,motif,ticket_id,client_id,assistant,assistant_id,tenant_id) VALUES('ENTREE',(v_pay->>'montant')::numeric,COALESCE(v_pay->>'mode','ESPECES'),'Vente '||p_ticket_id,p_ticket_id,NULLIF(v_pay->>'client_id','')::bigint,p_assistant,p_assistant_id,v_tenant_id);
      END IF;
    END LOOP;
    RETURN jsonb_build_object('success',true,'ticket_id',p_ticket_id,'nb_articles',v_nb_articles,'montant_total',v_total,'benefice_total',v_profit,'montant_credit',v_credit,'client_id',v_client_id);
END;
$$;
GRANT EXECUTE ON FUNCTION public.valider_vente(text,date,text,text,bigint,jsonb,jsonb) TO anon, authenticated;

-- RLS: le contrôle de vente est strictement administrateur via RPC SECURITY DEFINER.
