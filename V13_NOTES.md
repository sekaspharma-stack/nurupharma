# PharmaSys V13

Corrections intégrées :
- `valider_vente` V13 avec `v_stock_avant` / `v_stock_apres` pour supprimer l’ambiguïté SQL sur `stock`.
- Contrat RPC 7 arguments conservé, avec `p_paiements`.
- Client Supabase renforcé : `apikey`, `Authorization`, `x-session-id`, `x-tenant-id`.
- `validerPanier()` gère explicitement les erreurs 401 et l’absence de la RPC V13.
- Cache PWA passé en `pharmasys-shell-v13`.

Migration à exécuter dans Supabase :
`supabase/migrations/20260911000100_pharmasys_v13_valider_vente_fix.sql`

Attention : si le site renvoie encore `401 Invalid API key`, la clé publique enregistrée dans PharmaSys ne correspond pas à l’URL Supabase configurée.

## V13.1 — Finance & caisse corrigées

Nouvelle migration : `supabase/migrations/20260908000200_pharmasys_finance_caisse_v13_1.sql`

Corrections :
- Une annulation de ligne ou de ticket restitue le stock **et** inverse la partie financière correspondante.
- Les remboursements respectent les modes de paiement d'origine (espèces, Mobile Money, carte, crédit).
- Les ventes à crédit annulées diminuent la créance sans créer une fausse sortie de caisse.
- Les mouvements de caisse sont catégorisés (`VENTE`, `REMBOURSEMENT`, `REGLEMENT_CREDIT`, `DEPENSE`, etc.) et référencés au ticket/opération.
- Ajout de `get_rapport_journalier(date)` comme source unique du rapport journalier.
- Le bouton Rapport journalier produit maintenant un aperçu et une impression complète.
- Flux & Mouvements affiche séparément les mouvements de stock et les mouvements financiers.
- Les remboursements et soldes sont visibles dans les indicateurs de mouvements.

Ordre d'exécution recommandé dans Supabase :
1. Migrations existantes V13.
2. `20260908000200_pharmasys_finance_caisse_v13_1.sql`.
3. Les migrations ultérieures peuvent être conservées : le trigger de catégorisation protège les écritures de caisse des anciennes RPC.

## V13.1.1 — Correctifs après test réel
- Correction du RPC `get_rapport_journalier` : suppression de la collision entre variable `record m` et alias SQL, cause de `55000 record "m" is not assigned yet`.
- Correction de `annuler_article_ticket` / `annuler_ligne_ticket` pour les identifiants de ticket contenant des tirets (`-`).
- Le remboursement d'une annulation est maintenant confirmé explicitement dans le message utilisateur.
- Le test réseau `/rest/v1/` envoie aussi `Authorization: Bearer <anon key>` afin d'éviter le faux diagnostic `401`.

Migration corrective à exécuter après V13.1 :
`supabase/migrations/20260908000300_pharmasys_v13_1_corrections.sql`
