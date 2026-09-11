-- PharmaSys V13.3.3
-- 1) Répare les séquences IDENTITY désynchronisées après import/restauration.
--    Évite notamment: duplicate key mouvements_stock_pkey.
-- 2) Aucun changement de données métier: on aligne uniquement les séquences
--    sur le MAX(id) existant afin que la prochaine insertion obtienne un ID libre.

DO $$
DECLARE
  r record;
  v_seq text;
  v_max bigint;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('mouvements_stock'),
      ('ticket_lignes'),
      ('paiements'),
      ('mouvements_caisse'),
      ('inventaires'),
      ('controles_inventaire'),
      ('parametres_pharmacie')
    ) AS x(tbl)
  LOOP
    v_seq := pg_get_serial_sequence('public.' || r.tbl, 'id');
    IF v_seq IS NOT NULL THEN
      EXECUTE format('SELECT MAX(id) FROM public.%I', r.tbl) INTO v_max;
      IF COALESCE(v_max, 0) > 0 THEN
        PERFORM setval(v_seq::regclass, v_max, true);
      ELSE
        PERFORM setval(v_seq::regclass, 1, false);
      END IF;
    END IF;
  END LOOP;
END $$;

-- Index utiles au filtrage journalier/hebdomadaire/mensuel.
CREATE INDEX IF NOT EXISTS idx_mouvements_stock_tenant_created
  ON public.mouvements_stock(tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_mouvements_caisse_tenant_created
  ON public.mouvements_caisse(tenant_id, created_at DESC);
