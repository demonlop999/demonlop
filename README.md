# Ultra Gaming Mode 3.3.1

Application Android et module Magisk créés par **BarouTech**. L'application reprend le tableau de bord Liquid Glass; le module Magisk fournit les commandes root CPU/GPU et le suivi thermique local.

## Installation sur le téléphone

1. Téléchargez le paquet prêt à flasher : [UltraGamingMode-v3.3.1.zip](./UltraGamingMode-v3.3.1.zip). Pour le reconstruire depuis les sources, lancez `.\build-module.ps1` (prérequis : JDK 17+, Gradle 8.9+ et Android SDK API 35).
2. Flashez le ZIP dans Magisk et redémarrez.
3. Au démarrage, le service Magisk installe ou met à jour l'APK embarqué à l'aide de `pm install -r`. L'application **Ultra Gaming Mode** apparaît ensuite dans le lanceur Android. Android n'autorise pas l'auto-lancement de l'écran après installation; ouvrez l'application depuis le lanceur.
4. Au premier lancement, autorisez l'accès superutilisateur dans Magisk. L'écran de risques et de confidentialité apparaît ensuite; acceptez séparément les deux cases pour accéder au tableau de bord.

Le ZIP inclut l'entrée d'installation `META-INF/com/google/android/update-binary` requise par Magisk ainsi que `app/UltraGamingMode.apk`. Si l'installation de l'APK au redémarrage échoue, consultez `/data/adb/ultra-gaming-mode/app-install.log`.

## Module requis

L'application vérifie au lancement que `/data/adb/modules/ultra_gaming_mode` existe et que le module n'a pas de marqueur `disable` ou `remove`. Si le module est désactivé ou supprimé, elle affiche une explication et une action **Réessayer**. L'APK reste volontairement installé quand le module est retiré pour que l'utilisateur voie l'explication; réactivez ou reflashez le module, redémarrez et relancez l'application.

La demande superutilisateur est gérée par Magisk. Les commandes transmises par l'application sont limitées au script `control.sh` du module; l'application refuse les commandes hors de sa syntaxe autorisée. Les profils CPU/GPU sont enregistrés dans le module et les limites matérielles ainsi que les protections thermiques du noyau restent prioritaires.

## Profils et fréquences

- **Origine** restaure les gouverneurs et limites de fréquence capturés au premier démarrage du module.
- **Équilibré** sélectionne un gouverneur adaptatif compatible et limite les maxima CPU/GPU à 80 % de la plage originale exposée.
- **Jeu** choisit des gouverneurs réactifs disponibles et autorise jusqu'à 100 % de cette plage.
- Les limites manuelles et les profils de jeu sont saisis en MHz. Le module convertit vers l'unité sysfs, choisit un palier pris en charge et reste dans la plage connue.
- La liste de jeux provient des applications installées. Le paquet, les fréquences, actions début/fin et scripts locaux associés restent sur l'appareil.

## Gestion thermique et confidentialité

Les protections et services thermiques Android/noyau ne sont jamais désactivés ou falsifiés. À 75 °C ou plus pendant un profil Jeu, le module revient temporairement à Équilibré; il réapplique le profil sous 68 °C.

Aucune télémétrie ni requête réseau n'est émise par l'application ou le module. L'écran de consentement précède l'accès au tableau de bord et les mesures d'appareil. Un script personnalisé autorisé séparément en root peut avoir son propre comportement réseau; examinez-le avant exécution. Le retrait du consentement désactive les scripts et tente de restaurer les paramètres sauvegardés.

Si le module est désactivé dans Magisk, ses scripts ne tournent pas; l'APK installé peut alors seulement afficher l'état de dépendance. Le root ne donne pas à l'application un contrôle universel sur les packs d'icônes, thèmes, launcher ou applications.

## Construction et test

`build-module.ps1` construit le bundle WebUI depuis `src/webui.js`, compile l'application Android en APK de développement, l'embarque dans `app/UltraGamingMode.apk`, puis crée l'archive Magisk dans le dossier du module. Il inclut le chargeur d'installation Magisk, normalise les scripts et `module.prop` en fins de ligne Unix (LF), marque les scripts exécutables et écarte les anciens ZIP de sa propre archive. Le script restaure les dépendances npm à partir du lockfile si nécessaire. L'APK de développement utilise la signature debug Android : pour distribuer des mises à jour publiques, configurez une clé de signature release privée et pérenne dans le build Android.

Le projet Android est dans `android-app/`; son WebView charge les fichiers intégrés via `WebViewAssetLoader` et expose seulement le pont nécessaire aux commandes du module. Les accès CPU/GPU et l'installation doivent être testés sur un appareil Android rooté; les contrôles sur PC ne remplacent pas ce test matériel.

## Fluidité de l'interface

L'optimisation couvre l'ensemble du tableau de bord : système, batterie, mémoire, stockage, réseau, thermique et matériel. Les panneaux de détails ne sont reconstruits que si les données de leur catégorie changent, et uniquement lorsqu'ils sont affichés. Les mesures sont actualisées toutes les 10 secondes, suspendues en arrière-plan; la liste des jeux n'est plus interrogée en boucle. Le graphique thermique conserve son bitmap quand sa taille ne change pas. Le flou et les ombres Liquid Glass sont allégés pour réduire le travail de composition, tout en respectant les préférences système de transparence et d'animations réduites.

Ces changements réduisent le travail périodique et le coût de composition, mais aucun gain de FPS ou de fluidité n'est affirmé sans profilage sur un téléphone réel. Références : [Android — optimiser les vues](https://developer.android.com/develop/ui/views/layout/custom-views/optimizing-view), [Android — diagnostiquer le rendu et les saccades](https://developer.android.com/topic/performance/issues/render), [web.dev — performance de rendu](https://web.dev/articles/rendering-performance) et [web.dev — optimiser INP](https://web.dev/articles/optimize-inp).

## Références officielles

- [Guide développeur Magisk — structure des modules, `module.prop`, scripts de démarrage](https://topjohnwu.github.io/Magisk/guides.html)
- [Android Developers — activités et point d'entrée de l'application](https://developer.android.com/guide/components/activities/intro-activities)
- [AndroidX WebKit — WebViewAssetLoader](https://developer.android.com/reference/androidx/webkit/WebViewAssetLoader)
