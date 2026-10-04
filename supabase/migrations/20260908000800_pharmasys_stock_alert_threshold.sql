-- ============================================================
-- PharmaSys V13 - Seuil dynamique d'alerte de stock
-- ============================================================
-- Un seuil est conservé par tenant dans parametres_pharmacie.
-- Valeur historique par défaut : 2 unités.

ALTER TABLE public.parametres_pharmacie
  ADD COLUMN IF NOT EXISTS seuil_stock_critique numeric NOT NULL DEFAULT 2;

UPDATE public.parametres_pharmacie
SET seuil_stock_critique = 2
WHERE seuil_stock_critique IS NULL OR seuil_stock_critique < 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.parametres_pharmacie'::regclass
      AND conname = 'parametres_pharmacie_seuil_stock_critique_check'
  ) THEN
    ALTER TABLE public.parametres_pharmacie
      ADD CONSTRAINT parametres_pharmacie_seuil_stock_critique_check
      CHECK (seuil_stock_critique >= 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_parametres_pharmacie_tenant
  ON public.parametres_pharmacie(tenant_id);
