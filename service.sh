#!/system/bin/sh

MODDIR=${0%/*}
STATE_DIR=/data/adb/ultra-gaming-mode
PROFILE_FILE=$STATE_DIR/profile

mkdir -p "$STATE_DIR" || exit 1

count=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$count" -lt 60 ]; do
    sleep 5
    count=$((count + 1))
done

sleep 10
if [ -f "$MODDIR/app/UltraGamingMode.apk" ]; then
    install_log=$STATE_DIR/app-install.log
    if pm install -r "$MODDIR/app/UltraGamingMode.apk" > "$install_log" 2>&1; then
        echo "Ultra Gaming Mode: application installee ou mise a jour." >> "$install_log"
    else
        echo "Ultra Gaming Mode: installation automatique de l'application echouee." >> "$install_log"
    fi
else
    echo "Ultra Gaming Mode: APK absent; application Android non installee." >&2
fi

if ! sh "$MODDIR/control.sh" snapshot; then
    echo "Ultra Gaming Mode: snapshot CPU/GPU indisponible; aucun réglage appliqué au démarrage." >&2
    exit 0
fi

exec sh "$MODDIR/control.sh" auto
