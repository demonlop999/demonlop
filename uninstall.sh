#!/system/bin/sh

STATE_DIR=/data/adb/ultra-gaming-mode
MODDIR=${0%/*}

if [ -x "$MODDIR/control.sh" ]; then
    if ! sh "$MODDIR/control.sh" decline; then
        echo "Ultra Gaming Mode: restauration impossible; données et sauvegarde conservées dans $STATE_DIR." >&2
        exit 0
    fi
fi

if ! rm -rf "$STATE_DIR"; then
    echo "Ultra Gaming Mode: impossible de supprimer les données locales dans $STATE_DIR." >&2
fi
