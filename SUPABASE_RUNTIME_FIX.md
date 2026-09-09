# PharmaSys – correctifs runtime

La migration `supabase/migrations/20260906000100_fix_pharmasys_runtime.sql` corrige les IDs bigint, crée le bucket `logos`, et ajoute la RPC transactionnelle `valider_vente`.

Appliquer les migrations Supabase avant de publier le frontend. La clé utilisée dans Configuration initiale doit être la clé anon/publishable du même projet Supabase que l’URL.

## V8 — Finances & intelligence

La migration `20260908000100_finance_intelligence_v8.sql` ajoute :
- modes de paiement et paiements mixtes ;
- clients et crédits ;
- mouvements de caisse ;
- KPI financiers (CA, marge, panier moyen, stock immobilisé, crédits) ;
- Tops ventes/rentabilité/dormants/catégories et matrice ventes × marge ;
- alertes péremption et ruptures ;
- réapprovisionnement intelligent et prévision indicative ;
- détection d'anomalies de ventes et de stock ;
- briefing quotidien ;
- validation de vente avec paiement dans une transaction PostgreSQL.

Appliquer cette migration après les migrations précédentes et avant l'utilisation des nouvelles fonctions Finance.
