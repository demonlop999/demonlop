# Scripts associés aux jeux

Les scripts personnalisés sont facultatifs et sont exécutés **en root** à l'ouverture détectée du jeu.

1. Créez `game-scripts/<identifiant>.sh` dans le module.
2. Vérifiez intégralement le contenu. Un script root peut lire ou modifier le système et peut lui-même envoyer des données sur le réseau.
3. Dans la WebUI, cochez l'autorisation séparée des scripts root et enregistrez-la, puis indiquez `<identifiant>` dans le profil.
4. Retirez cette autorisation dans la WebUI ou le consentement global pour désactiver l'exécution.

Seuls les fichiers directs non-symboliques dont le nom contient des lettres, chiffres, tirets et traits de soulignement sont exécutés. L'argument `$1` est le nom du paquet du jeu. Le module ne télécharge aucun script utilisateur. Les scripts doivent terminer rapidement; un script bloqué retarde la détection des profils suivants.

Exemple inoffensif à adapter et à enregistrer sous `game-scripts/mon-script.sh` :

```sh
#!/system/bin/sh
echo "Profil de jeu activé pour: $1"
```
