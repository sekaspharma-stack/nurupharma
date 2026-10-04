-- PharmaSys V10: reset sécurisé de l'historique financier/commercial.
CREATE OR REPLACE FUNCTION public.reinitialiser_historique_systeme()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  t uuid := current_tenant_id();
  r text := current_user_role();
BEGIN
  IF t IS NULL THEN RAISE EXCEPTION 'Session invalide ou expirée'; END IF;
  IF lower(coalesce(r,'')) NOT IN ('admin','administrateur') THEN
    RAISE EXCEPTION 'Autorisation administrateur requise';
  END IF;

  -- Préserve intégralement inventaire/stock, utilisateurs, clients et paramètres pharmacie.
  -- Supprime les historiques commerciaux, financiers et le journal de mouvements devenu incohérent.
  DELETE FROM notifications WHERE tenant_id=t;
  DELETE FROM operations_sync WHERE tenant_id=t;
  DELETE FROM paiements WHERE tenant_id=t;
  DELETE FROM mouvements_caisse WHERE tenant_id=t;
  DELETE FROM mouvements_stock WHERE tenant_id=t;
  DELETE FROM historique_ventes WHERE tenant_id=t;
  DELETE FROM ticket_lignes WHERE tenant_id=t;
  DELETE FROM tickets WHERE tenant_id=t;

  RETURN jsonb_build_object(
    'success',true,
    'tenant_id',t,
    'message','Historique commercial et financier supprimé; médicaments, stock, clients, utilisateurs et paramètres conservés'
  );
END; $$;
GRANT EXECUTE ON FUNCTION public.reinitialiser_historique_systeme() TO anon, authenticated;
