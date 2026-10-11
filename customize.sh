#!/system/bin/sh

ui_print "- Ultra Gaming Mode"
ui_print "- Cree par BarouTech."
ui_print "- L'application Android sera installee au prochain demarrage."
ui_print "- Le root est demande par Android au premier lancement."
ui_print "- Le throttling thermique Android/noyau reste actif."

set_perm "$MODPATH/control.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
if [ -f "$MODPATH/app/UltraGamingMode.apk" ]; then
    set_perm "$MODPATH/app/UltraGamingMode.apk" 0 0 0644
else
    abort "! APK absent. Construisez le ZIP complet avec build-module.ps1 avant de flasher."
fi
set_perm_recursive "$MODPATH/game-scripts" 0 0 0755 0644
