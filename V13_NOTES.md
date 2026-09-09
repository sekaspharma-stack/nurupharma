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
