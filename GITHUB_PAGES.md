# PharmaSys — GitHub Pages

Cette version est une application HTML/JavaScript autonome. GitHub Pages n'a donc plus besoin de lancer `npm install` ou `npm run build`.

## Déploiement

Le workflow `.github/workflows/deploy.yml` prépare directement le site statique et le publie sur GitHub Pages.

URL :
`https://nurupharma865-svg.github.io/nurupharma/`

## Première configuration Supabase

1. Ouvrir le projet Supabase.
2. Aller dans **SQL Editor**.
3. Ouvrir/coller le contenu de `schema.sql`.
4. Exécuter tout le script.
5. Dans PharmaSys, saisir :
   - l'URL du projet : `https://xxxxx.supabase.co`
   - la clé **anon** (ou publishable key) du projet.
6. Donner un nom à l'espace et cliquer sur **Lier et configurer**.

Si l'application indique que `setup_tenant` n'existe pas, le script `schema.sql` n'a pas encore été exécuté complètement dans Supabase.
