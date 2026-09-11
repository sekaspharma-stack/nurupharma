# PharmaSys V12 — diagnostic des erreurs V11

## 404 manifest/sw
V12 place manifest.webmanifest, sw.js, favicon.svg et les icônes à la racine du site ET configure explicitement GitHub Pages pour publier le dossier `site/`. Après push sur `main`, vérifier que le workflow Pages est terminé avec succès.

Tester ensuite :
- https://nurupharma865-svg.github.io/nurupharma/manifest.webmanifest
- https://nurupharma865-svg.github.io/nurupharma/sw.js
- https://nurupharma865-svg.github.io/nurupharma/icon-192.png

Ces trois URL doivent répondre HTTP 200.

## 401 Supabase
Une réponse HTTP 401 sur `/rest/v1/` signifie que l'URL Supabase et la clé anon/publishable utilisées par le navigateur ne sont pas compatibles, ou que la clé est invalide. V12 transforme cette erreur en message explicite et arrête la boucle de synchronisation pour éviter le spam de requêtes.

La clé doit être celle du même projet que l'URL `https://gttgmzzmjvlmywqewaem.supabase.co`. Ne jamais mettre une clé provenant d'un autre projet.

## 400 executer_operation_offline
Une fois le 401 corrigé, si un 400 persiste, le message de session/tenant sera affiché explicitement. Il faut alors vérifier que la session PharmaSys est valide et que la migration V9 est appliquée dans ce même projet Supabase.
