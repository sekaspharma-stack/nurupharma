-- ============================================================
-- PharmaSys V13 - Correction chirurgicale de valider_vente
-- Corrige l'ambiguïté de la variable stock et conserve le
-- contrat 7 arguments utilisé par PharmaSys V8/V9/V12.
-- ============================================================

DROP FUNCTION IF EXISTS public.valider_vente(text, date, text, text, bigint, jsonb);
DROP FUNCTION IF EXISTS public.valider_vente(text, date, text, text, bigint, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.valider_vente(
    p_ticket_id text,
    p_date date,
    p_heure text,
    p_assistant text,
    p_assistant_id bigint,
    p_lignes jsonb,
    p_paiements jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id uuid := current_tenant_id();
    v_ligne jsonb;
    v_pay jsonb;
    v_produit_id bigint;
    v_quantite numeric;
    v_stock_avant numeric;
    v_stock_apres numeric;
    v_pua numeric;
    v_pvu numeric;
    v_nom text;
    v_total numeric := 0;
    v_profit numeric := 0;
    v_nb_articles numeric := 0;
    v_paytotal numeric := 0;
    v_mode_paiement text := 'ESPECES';
    v_client_id bigint := NULL;
    v_credit numeric := 0;
    v_payments jsonb := COALESCE(p_paiements, '[]'::jsonb);
BEGIN
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Session invalide ou expirée';
    END IF;

    IF COALESCE(trim(p_ticket_id), '') = '' THEN
        RAISE EXCEPTION 'Numéro de ticket invalide';
    END IF;

    IF p_lignes IS NULL
       OR jsonb_typeof(p_lignes) <> 'array'
       OR jsonb_array_length(p_lignes) = 0 THEN
        RAISE EXCEPTION 'Le panier est vide';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.tickets AS t
        WHERE t.id = p_ticket_id
          AND t.tenant_id = v_tenant_id
    ) THEN
        RAISE EXCEPTION 'Ce ticket existe déjà';
    END IF;

    -- 1) Verrouiller et contrôler tous les produits avant toute écriture.
    -- Le nom v_stock_avant évite toute ambiguïté avec la colonne inventaire.stock.
    FOR v_ligne IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
        v_produit_id := NULLIF(v_ligne->>'produit_id', '')::bigint;
        v_quantite := NULLIF(v_ligne->>'quantite', '')::numeric;

        IF v_produit_id IS NULL THEN
            RAISE EXCEPTION 'Produit invalide dans le panier';
        END IF;
        IF v_quantite IS NULL OR v_quantite <= 0 THEN
            RAISE EXCEPTION 'Quantité invalide pour le produit %', v_produit_id;
        END IF;

        SELECT p.nom, p.stock, p.pua, p.pvu
        INTO v_nom, v_stock_avant, v_pua, v_pvu
        FROM public.inventaire AS p
        WHERE p.id = v_produit_id
          AND p.tenant_id = v_tenant_id
          AND p.actif = true
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Produit introuvable : %', v_produit_id;
        END IF;

        IF COALESCE(v_stock_avant, 0) < v_quantite THEN
            RAISE EXCEPTION 'Stock insuffisant pour %. Disponible: %, demandé: %',
                v_nom, v_stock_avant, v_quantite;
        END IF;

        v_nb_articles := v_nb_articles + v_quantite;
        v_total := v_total + (v_quantite * COALESCE(v_pvu, 0));
        v_profit := v_profit + (v_quantite * (COALESCE(v_pvu, 0) - COALESCE(v_pua, 0)));
    END LOOP;

    -- 2) Contrôler les paiements contre le total réel de la vente.
    v_paytotal := 0;
    FOR v_pay IN SELECT * FROM jsonb_array_elements(v_payments) LOOP
        IF NULLIF(v_pay->>'montant', '')::numeric IS NULL
           OR (v_pay->>'montant')::numeric <= 0 THEN
            RAISE EXCEPTION 'Montant de paiement invalide';
        END IF;
        v_paytotal := v_paytotal + (v_pay->>'montant')::numeric;
    END LOOP;

    -- Le tableau par défaut est reconstruit ici avec le total calculé.
    IF jsonb_array_length(COALESCE(p_paiements, '[]'::jsonb)) = 0 THEN
        v_payments := jsonb_build_array(
            jsonb_build_object('mode', 'ESPECES', 'montant', v_total)
        );
        v_paytotal := v_total;
    END IF;

    IF ABS(v_paytotal - v_total) > 0.01 THEN
        RAISE EXCEPTION 'Les paiements (%,) ne correspondent pas au total (%)', v_paytotal, v_total;
    END IF;

    FOR v_pay IN SELECT * FROM jsonb_array_elements(v_payments) LOOP
        IF COALESCE(v_pay->>'mode', 'ESPECES') = 'CREDIT' THEN
            IF NULLIF(v_pay->>'client_id', '')::bigint IS NULL THEN
                RAISE EXCEPTION 'Un client est obligatoire pour un crédit';
            END IF;

            IF v_client_id IS NULL THEN
                v_client_id := NULLIF(v_pay->>'client_id', '')::bigint;
            ELSIF v_client_id <> NULLIF(v_pay->>'client_id', '')::bigint THEN
                RAISE EXCEPTION 'Un seul client peut porter le crédit d’une vente';
            END IF;

            IF NOT EXISTS (
                SELECT 1
                FROM public.clients AS c
                WHERE c.id = v_client_id
                  AND c.tenant_id = v_tenant_id
                  AND c.actif = true
            ) THEN
                RAISE EXCEPTION 'Client crédit introuvable';
            END IF;

            v_credit := v_credit + (v_pay->>'montant')::numeric;
        END IF;
    END LOOP;

    IF jsonb_array_length(v_payments) > 1 THEN
        v_mode_paiement := 'MIXTE';
    ELSE
        v_mode_paiement := COALESCE(v_payments->0->>'mode', 'ESPECES');
    END IF;

    -- 3) Créer le ticket.
    INSERT INTO public.tickets(
        id, date, heure, assistant, assistant_id, nb_articles,
        montant_total, benefice_total, statut, mode_paiement,
        client_id, montant_paye, montant_credit, tenant_id
    )
    VALUES (
        p_ticket_id, p_date, p_heure, p_assistant, p_assistant_id, v_nb_articles,
        v_total, v_profit, 'VALIDE', v_mode_paiement,
        v_client_id, v_total - v_credit, v_credit, v_tenant_id
    );

    -- 4) Décrémenter le stock et écrire tous les journaux.
    FOR v_ligne IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
        v_produit_id := (v_ligne->>'produit_id')::bigint;
        v_quantite := (v_ligne->>'quantite')::numeric;

        SELECT p.nom, p.stock, p.pua, p.pvu
        INTO v_nom, v_stock_avant, v_pua, v_pvu
        FROM public.inventaire AS p
        WHERE p.id = v_produit_id
          AND p.tenant_id = v_tenant_id
        FOR UPDATE;

        v_stock_apres := v_stock_avant - v_quantite;

        UPDATE public.inventaire AS p
        SET stock = v_stock_apres
        WHERE p.id = v_produit_id
          AND p.tenant_id = v_tenant_id;

        INSERT INTO public.ticket_lignes(
            ticket_id, produit_id, nom, quantite, pua, pvu,
            total, profit, statut, tenant_id
        )
        VALUES (
            p_ticket_id, v_produit_id, v_nom, v_quantite, v_pua, v_pvu,
            v_quantite * COALESCE(v_pvu, 0),
            v_quantite * (COALESCE(v_pvu, 0) - COALESCE(v_pua, 0)),
            'VALIDE', v_tenant_id
        );

        INSERT INTO public.historique_ventes(
            id, date, heure, assistant, assistant_id, produit_id, nom,
            quantite, pua, pvu, total, profit, statut, tenant_id
        )
        VALUES (
            p_ticket_id || '-' || v_produit_id,
            p_date, p_heure, p_assistant, p_assistant_id, v_produit_id, v_nom,
            v_quantite, v_pua, v_pvu,
            v_quantite * COALESCE(v_pvu, 0),
            v_quantite * (COALESCE(v_pvu, 0) - COALESCE(v_pua, 0)),
            'VALIDE', v_tenant_id
        );

        INSERT INTO public.mouvements_stock(
            date, assistant, produit_id, produit, type, quantite,
            stock_avant, stock_apres, observation, ticket, tenant_id
        )
        VALUES (
            to_char(now(), 'DD/MM/YYYY HH24:MI:SS'),
            p_assistant, v_produit_id, v_nom, 'VENTE', v_quantite,
            v_stock_avant, v_stock_apres,
            'Vente ' || p_ticket_id, p_ticket_id, v_tenant_id
        );
    END LOOP;

    -- 5) Enregistrer les paiements et la caisse.
    FOR v_pay IN SELECT * FROM jsonb_array_elements(v_payments) LOOP
        INSERT INTO public.paiements(
            ticket_id, client_id, montant, mode, observation, assistant, tenant_id
        )
        VALUES (
            p_ticket_id,
            NULLIF(v_pay->>'client_id', '')::bigint,
            (v_pay->>'montant')::numeric,
            COALESCE(v_pay->>'mode', 'ESPECES'),
            'Paiement vente',
            p_assistant,
            v_tenant_id
        );

        IF COALESCE(v_pay->>'mode', 'ESPECES') <> 'CREDIT' THEN
            INSERT INTO public.mouvements_caisse(
                type, montant, mode, motif, ticket_id, client_id, assistant, tenant_id
            )
            VALUES (
                'ENTREE',
                (v_pay->>'montant')::numeric,
                COALESCE(v_pay->>'mode', 'ESPECES'),
                'Vente ' || p_ticket_id,
                p_ticket_id,
                NULLIF(v_pay->>'client_id', '')::bigint,
                p_assistant,
                v_tenant_id
            );
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'ticket_id', p_ticket_id,
        'nb_articles', v_nb_articles,
        'montant_total', v_total,
        'benefice_total', v_profit,
        'credit', v_credit,
        'mode_paiement', v_mode_paiement
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.valider_vente(text, date, text, text, bigint, jsonb, jsonb)
TO anon, authenticated;
