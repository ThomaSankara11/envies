# Envies — notes pour Claude (mémoire entre les sessions) 

## But
Appli de liste d'envies perso d'Ilian, inspirée de Wantd (iOS seulement). Cible : MÊME COMPTE sur iPhone et PC
(navigateur), puis amis (abonnements, feed, cadeaux réservés en secret). Tout GRATUIT. Nom provisoire « Envies ».
Ilian a demandé une interface qui ne copie PAS Wantd → 3 interfaces au choix, il tranchera.

## Interface retenue (v3 = VERSION FINALE, 11 nov. 2026)
Ilian a choisi de garder la direction artistique de l'app d'origine : fond noir, titres en italique (serif),
grille façon Pinterest (colonnes remplies de gauche à droite en JS, 2/3/4/5 colonnes selon la largeur),
onglets de listes soulignés, « Trier / Filtrer » en texte, loupe qui ouvre la recherche, bouton + blanc carré,
barre flottante Feed / Amis / Envies. Nom et icône restent les nôtres (« Envies »), pas ceux de Wantd.
Les 3 interfaces de test (Vitrine / Liste / Atelier) ont été retirées ; copie de sauvegarde hors projet.

## Architecture
- 1 fichier `index.html` (vanilla) + manifest (avec share_target Android) + icônes. Hébergement prévu : GitHub Pages.
- Stores interchangeables : makeLocalStore (localStorage) / makeSupaStore (Supabase, activé si URL + clé publishable).
- `supabase-schema.sql` : profiles, lists, wishes, follows, reservations + RLS + trigger profil + RPC handle_available.
  - CONFIDENTIALITÉ : mes envies visibles seulement par ceux que JE suis (policy wishes_read : owner follows viewer).
    Donc « suivre » = demander, « suivre en retour » = accepter. Listes privées jamais visibles.
  - Réservations invisibles pour le propriétaire ; visibles seulement sur les envies que l'on peut voir.
  - Contraintes : url http(s) seulement, image http(s)/data:image < 400 Ko, longueurs max.
  - Trigger : pseudo pris/invalide → pseudo unique auto (l'appli prévient « tu es @x »).
- Lecture des liens : relais CFG.META_RELAY (worker-meta.js, Cloudflare) → microlink (titre+image, pas de prix,
  ~50 requêtes/jour sans clé) → saisie manuelle.
- Ajout rapide : Ctrl+V n'importe où, glisser-déposer d'un lien, `?add=URL` (favori PC « bookmarklet » dans le Menu,
  raccourci iOS, partage Android). Un texte partagé contenant un lien est accepté (extractUrl).
- `.github/workflows/supabase-reveil.yml` : facultatif, ping tous les 3 jours pour éviter la pause Supabase.

## Problèmes anticipés et corrigés (v2)
- Lien piégé `javascript:` (XSS) → safeHref/safeImg partout + contrainte SQL.
- Prix « 1 299,90 », « 1.299,90 », « CHF 49.- » → parsePrice.
- Mémoire pleine (photos pellicule en local) → message clair. Photos réduites à 560 px / JPEG 0,72.
- Clé secrète collée par erreur → refusée (keyProblem). URL Supabase nettoyée (/rest/v1 retiré).
- Projet Supabase en pause / hors ligne / tables manquantes / e-mail non confirmé → messages compréhensibles (friendlyErr).
- Retour sur l'appli après 15 s → données rechargées (synchro iPhone ↔ PC).
- Doublon de lien → avertissement. Double clic → boutons bloqués pendant l'envoi.
- BUG trouvé par les tests : après déconnexion, les réservations restaient en mémoire (le propriétaire aurait pu voir
  son cadeau) → S.resv vidé à la déconnexion et sur ses propres envies, jamais affiché sur ses envies.
- BUG : classe `.sel` partagée entre menus et carte sélectionnée → renommée `.picked`.

## Testé (bac à sable, sans réseau réel)
- Les 3 interfaces sur iPhone 13 simulé + PC 1366 px : exemples, ajout par lien, prix, recherche (focus gardé), fiche,
  exaucée, listes, rechargement, panneau Atelier, raccourcis, Ctrl+V, glisser-déposer, ?add=, anti-piège, mémoire pleine.
- Mode compte avec FAUX Supabase (règles reproduites) dans les 3 interfaces : inscription (pseudo pris), migration
  (exemples exclus), suivre, « en attente de retour », rien de visible tant que l'autre ne suit pas, feed, liste privée
  masquée, réservation secrète, connexion du propriétaire sans voir la réservation.
## PAS testé
- Vrai Supabase (PostgREST, embeds `profiles!follows_followee_id_fkey`, vraies RLS, mail de confirmation), vrai relais,
  microlink réel, collage iOS, installation écran d'accueil, bookmarklet réel.

## Étapes (Ilian valide chaque étape)
1. ✅ v1. 2. ✅ v2 (3 interfaces, correctifs). ✅ v3 = style d'origine + correctifs → zip « envies-VERSION-FINALE.zip ».
3. Supabase : créer le projet, exécuter le .sql, Auth → URL Configuration → Site URL = adresse GitHub Pages
   (sinon le lien de confirmation renvoie vers localhost) ; ou désactiver « Confirm email » au début.
4. Mettre URL + clé publishable dans CFG ; publier sur GitHub Pages. 5. Relais Cloudflare (ALLOWED_ORIGINS).
6. Test réel avec un ami. Plus tard : retirer les 2 interfaces non choisies, multi-listes, photo de profil, notifications.
