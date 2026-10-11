#!/system/bin/sh

MODDIR=${0%/*}
STATE_DIR=/data/adb/ultra-gaming-mode
PROFILE_DIR=$STATE_DIR/profiles
PROFILE_FILE=$STATE_DIR/profile
SNAPSHOT_FILE=$STATE_DIR/original-settings-v2.tsv
THERMAL_LIMIT_C=75
THERMAL_RESUME_C=68

fail() {
    echo "Erreur: $*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" = "0" ] || fail "les commandes de gestion doivent être exécutées en root."
}

list_cpu_governors() {
    for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
                    /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -w "$governor" ] && echo "$governor"
    done
}

list_gpu_governors() {
    for governor in /sys/class/devfreq/*gpu*/governor \
                    /sys/class/devfreq/*kgsl*/governor \
                    /sys/class/kgsl/kgsl-3d0/devfreq/governor; do
        [ -w "$governor" ] && echo "$governor"
    done
}

list_cpu_frequency_policies() {
    found=0
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$policy" ] || continue
        echo "$policy"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        for policy in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
            [ -d "$policy" ] && echo "$policy"
        done
    fi
}

list_gpu_frequency_devices() {
    for device in /sys/class/devfreq/*gpu* /sys/class/devfreq/*kgsl* /sys/class/kgsl/kgsl-3d0/devfreq; do
        [ -d "$device" ] && echo "$device"
    done
}

is_cpu_node() {
    case "$1" in
        /sys/devices/system/cpu/cpufreq/policy*/scaling_governor|/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

snapshot() {
    require_root
    mkdir -p "$STATE_DIR" || fail "impossible de créer $STATE_DIR."
    [ -s "$SNAPSHOT_FILE" ] && return 0
    tmp=$SNAPSHOT_FILE.tmp
    : > "$tmp" || fail "impossible d'écrire l'état initial."

    {
        for policy in $(list_cpu_frequency_policies); do
            echo "$policy/scaling_governor"
            echo "$policy/scaling_min_freq"
            echo "$policy/scaling_max_freq"
        done
        for device in $(list_gpu_frequency_devices); do
            echo "$device/governor"
            echo "$device/min_freq"
            echo "$device/max_freq"
        done
    } | sort -u | while IFS= read -r node; do
        [ -r "$node" ] && [ -w "$node" ] || continue
        value=$(cat "$node" 2>/dev/null) || continue
        printf '%s\t%s\n' "$node" "$value"
    done > "$tmp"

    mv "$tmp" "$SNAPSHOT_FILE" || fail "impossible de sauvegarder les gouverneurs initiaux."
    [ -s "$SNAPSHOT_FILE" ] || fail "aucun réglage CPU/GPU accessible à sauvegarder."
}

restore_snapshot() {
    [ -r "$SNAPSHOT_FILE" ] || fail "état initial indisponible; redémarrez pour restaurer les réglages du noyau."
    restored=0
    while IFS="$(printf '\t')" read -r node value; do
        case "$node" in
            /sys/*) ;;
            *) continue ;;
        esac
        [ -w "$node" ] || continue
        if printf '%s' "$value" > "$node" 2>/dev/null; then
            restored=$((restored + 1))
        fi
    done < "$SNAPSHOT_FILE"
    [ "$restored" -gt 0 ] || fail "aucun gouverneur initial n'a pu être restauré."
    echo "Profil d'origine restauré ($restored gouverneur(s))."
}

snapshot_value() {
    [ -r "$SNAPSHOT_FILE" ] || return 1
    awk -F '\t' -v node="$1" '$1 == node { print $2; exit }' "$SNAPSHOT_FILE"
}

supported_frequency() {
    node=$1
    requested=$2
    direction=$3
    case "$node" in
        */scaling_max_freq|*/scaling_min_freq)
            frequencies=${node%/*}/scaling_available_frequencies
            ;;
        */max_freq|*/min_freq)
            frequencies=${node%/*}/available_frequencies
            ;;
        *)
            echo "$requested"
            return 0
            ;;
    esac
    [ -r "$frequencies" ] || { echo "$requested"; return 0; }
    selected=
    for frequency in $(cat "$frequencies" 2>/dev/null); do
        case "$frequency" in ''|*[!0-9]*) continue ;; esac
        case "$direction" in
            max)
                if [ "$frequency" -le "$requested" ] && { [ -z "$selected" ] || [ "$frequency" -gt "$selected" ]; }; then
                    selected=$frequency
                fi
                ;;
            min)
                if [ "$frequency" -ge "$requested" ] && { [ -z "$selected" ] || [ "$frequency" -lt "$selected" ]; }; then
                    selected=$frequency
                fi
                ;;
        esac
    done
    echo "${selected:-$requested}"
}

available_governors() {
    node=$1
    case "$node" in
        */scaling_governor)
            available=${node%/*}/scaling_available_governors
            ;;
        *)
            available=${node%/*}/available_governors
            ;;
    esac
    [ -r "$available" ] && cat "$available"
}

set_governor() {
    node=$1
    shift
    [ -w "$node" ] || return 1
    available=$(available_governors "$node")
    for candidate in "$@"; do
        if [ -n "$available" ]; then
            case " $available " in
                *" $candidate "*) ;;
                *) continue ;;
            esac
        fi
        if printf '%s' "$candidate" > "$node" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

read_temp_c() {
    max=0
    found=0
    for zone in /sys/class/thermal/thermal_zone[0-9]*; do
        [ -r "$zone/temp" ] || continue
        value=$(cat "$zone/temp" 2>/dev/null)
        case "$value" in
            ''|*[!0-9-]*) continue ;;
        esac
        case "$value" in
            -* ) continue ;;
            * ) ;;
        esac
        if [ "$value" -gt 1000 ]; then
            value=$((value / 1000))
        fi
        [ "$value" -le 0 ] && continue
        [ "$value" -gt "$max" ] && max=$value
        found=1
    done
    [ "$found" -eq 1 ] || return 1
    echo "$max"
}

apply_cpu_limits() {
    min_percent=$1
    max_percent=$2
    cpu_limit_count=0
    for policy in $(list_cpu_frequency_policies); do
        [ -d "$policy" ] || continue
        [ -r "$policy/cpuinfo_min_freq" ] && [ -r "$policy/cpuinfo_max_freq" ] || continue
        [ -w "$policy/scaling_min_freq" ] && [ -w "$policy/scaling_max_freq" ] || continue
        hardware_min=$(cat "$policy/cpuinfo_min_freq" 2>/dev/null)
        hardware_max=$(cat "$policy/cpuinfo_max_freq" 2>/dev/null)
        case "$hardware_min:$hardware_max" in
            *[!0-9:]*|:*) continue ;;
        esac
        [ "$hardware_max" -gt 0 ] || continue
        saved_max=$(snapshot_value "$policy/scaling_max_freq")
        case "$saved_max" in
            ''|*[!0-9]*) saved_max=$(cat "$policy/scaling_max_freq" 2>/dev/null) ;;
        esac
        case "$saved_max" in
            ''|*[!0-9]*) saved_max=$hardware_max ;;
        esac
        [ "$saved_max" -gt "$hardware_max" ] && saved_max=$hardware_max
        [ "$saved_max" -lt "$hardware_min" ] && saved_max=$hardware_min

        span=$((saved_max - hardware_min))
        target_min=$((hardware_min + span / 100 * min_percent + span % 100 * min_percent / 100))
        target_max=$((hardware_min + span / 100 * max_percent + span % 100 * max_percent / 100))
        target_min=$(supported_frequency "$policy/scaling_min_freq" "$target_min" min)
        target_max=$(supported_frequency "$policy/scaling_max_freq" "$target_max" max)
        [ "$target_min" -gt "$target_max" ] && target_min=$target_max

        # Lower the current minimum first if the new maximum is below it.
        current_min=$(cat "$policy/scaling_min_freq" 2>/dev/null)
        case "$current_min" in
            ''|*[!0-9]*) current_min=$hardware_min ;;
        esac
        if [ "$target_max" -lt "$current_min" ]; then
            printf '%s' "$target_min" > "$policy/scaling_min_freq" 2>/dev/null || :
        fi
        if printf '%s' "$target_max" > "$policy/scaling_max_freq" 2>/dev/null; then
            cpu_limit_count=$((cpu_limit_count + 1))
        fi
        printf '%s' "$target_min" > "$policy/scaling_min_freq" 2>/dev/null || :
    done
    echo "Politiques CPU fréquence accessibles: $cpu_limit_count."
}

apply_gpu_limits() {
    min_percent=$1
    max_percent=$2
    gpu_limit_count=0
    for device in $(list_gpu_frequency_devices); do
        [ -d "$device" ] || continue
        [ -r "$device/min_freq" ] && [ -r "$device/max_freq" ] || continue
        [ -w "$device/min_freq" ] && [ -w "$device/max_freq" ] || continue
        hardware_min=$(snapshot_value "$device/min_freq")
        hardware_max=$(snapshot_value "$device/max_freq")
        case "$hardware_min" in ''|*[!0-9]*) hardware_min=$(cat "$device/min_freq" 2>/dev/null) ;; esac
        case "$hardware_max" in ''|*[!0-9]*) hardware_max=$(cat "$device/max_freq" 2>/dev/null) ;; esac
        case "$hardware_min:$hardware_max" in
            *[!0-9:]*|:*) continue ;;
        esac
        [ "$hardware_max" -gt 0 ] || continue
        saved_max=$(snapshot_value "$device/max_freq")
        case "$saved_max" in
            ''|*[!0-9]*) saved_max=$hardware_max ;;
        esac
        [ "$saved_max" -gt "$hardware_max" ] && saved_max=$hardware_max
        [ "$saved_max" -lt "$hardware_min" ] && saved_max=$hardware_min
        span=$((saved_max - hardware_min))
        target_min=$((hardware_min + span / 100 * min_percent + span % 100 * min_percent / 100))
        target_max=$((hardware_min + span / 100 * max_percent + span % 100 * max_percent / 100))
        target_min=$(supported_frequency "$device/min_freq" "$target_min" min)
        target_max=$(supported_frequency "$device/max_freq" "$target_max" max)
        [ "$target_min" -gt "$target_max" ] && target_min=$target_max
        current_min=$(cat "$device/min_freq" 2>/dev/null)
        case "$current_min" in
            ''|*[!0-9]*) current_min=$hardware_min ;;
        esac
        if [ "$target_max" -lt "$current_min" ]; then
            printf '%s' "$target_min" > "$device/min_freq" 2>/dev/null || :
        fi
        if printf '%s' "$target_max" > "$device/max_freq" 2>/dev/null; then
            gpu_limit_count=$((gpu_limit_count + 1))
        fi
        printf '%s' "$target_min" > "$device/min_freq" 2>/dev/null || :
    done
    echo "Noeuds GPU fréquence accessibles: $gpu_limit_count."
}

frequency_from_mhz() {
    mhz=$1
    reference=$2
    case "$reference" in
        ''|*[!0-9]*) echo "$mhz" ;;
        *)
            if [ "$reference" -ge 100000000 ]; then
                echo $((mhz * 1000000))
            elif [ "$reference" -ge 100000 ]; then
                echo $((mhz * 1000))
            else
                echo "$mhz"
            fi
            ;;
    esac
}

frequency_to_mhz() {
    frequency=$1
    case "$frequency" in
        ''|*[!0-9]*) echo 0 ;;
        *)
            if [ "$frequency" -ge 100000000 ]; then
                echo $((frequency / 1000000))
            elif [ "$frequency" -ge 100000 ]; then
                echo $((frequency / 1000))
            else
                echo "$frequency"
            fi
            ;;
    esac
}

validate_frequency_mhz() {
    case "$1" in
        ''|*[!0-9]*) fail "la fréquence doit être un nombre entier de MHz positif." ;;
    esac
    [ "$1" -gt 0 ] || fail "la fréquence doit être supérieure à 0 MHz."
    [ "$1" -le 100000 ] || fail "fréquence MHz hors plage raisonnable."
}

apply_cpu_frequency_mhz() {
    requested_min=$1
    requested_max=$2
    validate_frequency_mhz "$requested_min"
    validate_frequency_mhz "$requested_max"
    [ "$requested_min" -le "$requested_max" ] || fail "le minimum CPU ne peut pas dépasser le maximum."
    cpu_limit_count=0
    for policy in $(list_cpu_frequency_policies); do
        [ -d "$policy" ] || continue
        [ -r "$policy/cpuinfo_min_freq" ] && [ -r "$policy/cpuinfo_max_freq" ] || continue
        [ -w "$policy/scaling_min_freq" ] && [ -w "$policy/scaling_max_freq" ] || continue
        hardware_min=$(cat "$policy/cpuinfo_min_freq" 2>/dev/null)
        hardware_max=$(cat "$policy/cpuinfo_max_freq" 2>/dev/null)
        case "$hardware_min:$hardware_max" in *[!0-9:]*|:*) continue ;; esac
        [ "$hardware_max" -gt 0 ] || continue
        saved_max=$(snapshot_value "$policy/scaling_max_freq")
        case "$saved_max" in ''|*[!0-9]*) saved_max=$hardware_max ;; esac
        [ "$saved_max" -gt "$hardware_max" ] && saved_max=$hardware_max
        [ "$saved_max" -lt "$hardware_min" ] && saved_max=$hardware_min

        target_min=$(frequency_from_mhz "$requested_min" "$hardware_max")
        target_max=$(frequency_from_mhz "$requested_max" "$hardware_max")
        [ "$target_min" -lt "$hardware_min" ] && target_min=$hardware_min
        [ "$target_max" -lt "$hardware_min" ] && target_max=$hardware_min
        [ "$target_max" -gt "$saved_max" ] && target_max=$saved_max
        target_min=$(supported_frequency "$policy/scaling_min_freq" "$target_min" min)
        target_max=$(supported_frequency "$policy/scaling_max_freq" "$target_max" max)
        [ "$target_min" -gt "$target_max" ] && target_min=$target_max

        current_min=$(cat "$policy/scaling_min_freq" 2>/dev/null)
        case "$current_min" in ''|*[!0-9]*) current_min=$hardware_min ;; esac
        if [ "$target_max" -lt "$current_min" ]; then
            printf '%s' "$target_min" > "$policy/scaling_min_freq" 2>/dev/null || :
        fi
        if printf '%s' "$target_max" > "$policy/scaling_max_freq" 2>/dev/null; then
            cpu_limit_count=$((cpu_limit_count + 1))
        fi
        printf '%s' "$target_min" > "$policy/scaling_min_freq" 2>/dev/null || :
    done
    [ "$cpu_limit_count" -gt 0 ] || fail "aucune plage de fréquence CPU modifiable."
    echo "Fréquences CPU appliquées: $requested_min–$requested_max MHz."
}

apply_gpu_frequency_mhz() {
    requested_max=$1
    validate_frequency_mhz "$requested_max"
    gpu_limit_count=0
    for device in $(list_gpu_frequency_devices); do
        [ -r "$device/min_freq" ] && [ -r "$device/max_freq" ] || continue
        [ -w "$device/min_freq" ] && [ -w "$device/max_freq" ] || continue
        hardware_min=$(snapshot_value "$device/min_freq")
        hardware_max=$(snapshot_value "$device/max_freq")
        case "$hardware_min" in ''|*[!0-9]*) hardware_min=$(cat "$device/min_freq" 2>/dev/null) ;; esac
        case "$hardware_max" in ''|*[!0-9]*) hardware_max=$(cat "$device/max_freq" 2>/dev/null) ;; esac
        case "$hardware_min:$hardware_max" in *[!0-9:]*|:*) continue ;; esac
        [ "$hardware_max" -gt 0 ] || continue
        saved_max=$(snapshot_value "$device/max_freq")
        case "$saved_max" in ''|*[!0-9]*) saved_max=$hardware_max ;; esac
        [ "$saved_max" -gt "$hardware_max" ] && saved_max=$hardware_max
        [ "$saved_max" -lt "$hardware_min" ] && saved_max=$hardware_min
        target_max=$(frequency_from_mhz "$requested_max" "$hardware_max")
        [ "$target_max" -gt "$saved_max" ] && target_max=$saved_max
        [ "$target_max" -lt "$hardware_min" ] && target_max=$hardware_min
        target_max=$(supported_frequency "$device/max_freq" "$target_max" max)
        current_min=$(cat "$device/min_freq" 2>/dev/null)
        case "$current_min" in ''|*[!0-9]*) current_min=$hardware_min ;; esac
        if [ "$target_max" -lt "$current_min" ]; then
            printf '%s' "$hardware_min" > "$device/min_freq" 2>/dev/null || :
        fi
        if printf '%s' "$target_max" > "$device/max_freq" 2>/dev/null; then
            gpu_limit_count=$((gpu_limit_count + 1))
        fi
    done
    [ "$gpu_limit_count" -gt 0 ] || fail "aucune plage de fréquence GPU modifiable."
    echo "Plafond GPU appliqué: $requested_max MHz."
}

apply_profile() {
    require_root
    require_consent
    profile=$1
    case "$profile" in
        stock)
            restore_snapshot
            ;;
        balanced)
            for node in $(list_cpu_governors); do
                set_governor "$node" schedutil interactive ondemand || :
            done
            cpu_result=$(apply_cpu_limits 0 80)
            gpu_result=$(apply_gpu_limits 0 80)
            echo "Profil équilibré appliqué; plafonds CPU/GPU à 80% des fréquences exposées."
            echo "$cpu_result"
            echo "$gpu_result"
            ;;
        gaming)
            for node in $(list_cpu_governors); do
                if is_cpu_node "$node"; then
                    set_governor "$node" schedutil interactive ondemand || :
                fi
            done
            for node in $(list_gpu_governors); do
                set_governor "$node" msm-adreno-tz simple_ondemand schedutil || :
            done
            cpu_result=$(apply_cpu_limits 0 100)
            gpu_result=$(apply_gpu_limits 0 100)
            echo "Profil jeu appliqué; fréquences dans les limites matérielles."
            echo "$cpu_result"
            echo "$gpu_result"
            ;;
        *)
            fail "profil inconnu: $profile (attendus: stock, balanced, gaming ou game-NAME)."
            ;;
    esac

    mkdir -p "$STATE_DIR" || fail "impossible de créer $STATE_DIR."
    printf '%s\n' "$profile" > "$PROFILE_FILE" || fail "impossible d'enregistrer le profil."
}

validate_percent_pair() {
    case "$1:$2" in
        *[!0-9:]*|:*) fail "pourcentage invalide." ;;
    esac
    [ "$1" -le 100 ] && [ "$2" -le 100 ] && [ "$1" -le "$2" ] || fail "plage invalide (0 <= min <= max <= 100)."
}

run_game_action() {
    action=$1
    case "$action" in
        none) ;;
        gaming) apply_profile gaming ;;
        balanced) apply_profile balanced ;;
        stock) apply_profile stock ;;
        *) fail "action de profil non autorisée." ;;
    esac
}

require_consent() {
    grep -qx 'accepted-v2 risk-v2 privacy-v1' "$STATE_DIR/accepted" 2>/dev/null || fail "acceptez d'abord les risques et la politique de confidentialité dans la WebUI."
}

apply_game() {
    require_root
    require_consent
    id=$1
    valid_game_id "$id" || fail "identifiant de jeu invalide."
    file=$PROFILE_DIR/game-$id
    [ -r "$file" ] || fail "profil de jeu introuvable."
    name=$(sed -n 's/^name=//p' "$file" | head -n 1)
    min_mhz=$(sed -n 's/^cpu_min_mhz=//p' "$file" | head -n 1)
    max_mhz=$(sed -n 's/^cpu_max_mhz=//p' "$file" | head -n 1)
    gpu_mhz=$(sed -n 's/^gpu_max_mhz=//p' "$file" | head -n 1)
    min_percent=$(sed -n 's/^min_percent=//p' "$file" | head -n 1)
    max_percent=$(sed -n 's/^max_percent=//p' "$file" | head -n 1)
    gpu_percent=$(sed -n 's/^gpu_percent=//p' "$file" | head -n 1)
    start_action=$(sed -n 's/^start_action=//p' "$file" | head -n 1)
    script_id=$(sed -n 's/^script=//p' "$file" | head -n 1)
    : "${start_action:=gaming}"
    run_game_action "$start_action"
    if [ -n "$min_mhz" ] && [ -n "$max_mhz" ]; then
        cpu_result=$(apply_cpu_frequency_mhz "$min_mhz" "$max_mhz")
        if [ -n "$gpu_mhz" ]; then
            gpu_result=$(apply_gpu_frequency_mhz "$gpu_mhz")
        else
            gpu_result="Fréquences GPU non exposées par ce noyau."
        fi
    else
        : "${min_percent:=0}" "${max_percent:=100}" "${gpu_percent:=100}"
        validate_percent_pair "$min_percent" "$max_percent"
        case "$gpu_percent" in *[!0-9]*|'') fail "plafond GPU invalide." ;; esac
        [ "$gpu_percent" -le 100 ] || fail "plafond GPU maximum: 100% des fréquences exposées."
        cpu_result=$(apply_cpu_limits "$min_percent" "$max_percent")
        gpu_result=$(apply_gpu_limits 0 "$gpu_percent")
    fi
    printf '%s\n' "game-$id" > "$PROFILE_FILE" || fail "impossible d'enregistrer le profil."
    package=$(sed -n 's/^package=//p' "$file" | head -n 1)
    if [ -n "$script_id" ] && [ "$script_id" != "none" ]; then
        [ -f "$STATE_DIR/allow-root-scripts" ] || fail "activez d'abord l'autorisation séparée des scripts root."
        case "$script_id" in
            *[!a-zA-Z0-9_-]*) fail "identifiant de script invalide." ;;
        esac
        script=$MODDIR/game-scripts/$script_id.sh
        [ -f "$script" ] && [ ! -L "$script" ] || fail "script local introuvable ou lien symbolique interdit: game-scripts/$script_id.sh"
        sh "$script" "$package" || fail "échec du script local associé au profil."
    fi
    if [ -n "$min_mhz" ] && [ -n "$max_mhz" ] && [ -n "$gpu_mhz" ]; then
        echo "Profil $name appliqué (CPU $min_mhz-$max_mhz MHz, GPU max $gpu_mhz MHz)."
    elif [ -n "$min_mhz" ] && [ -n "$max_mhz" ]; then
        echo "Profil $name appliqué (CPU $min_mhz-$max_mhz MHz; GPU non exposé)."
    else
        echo "Profil $name appliqué (ancien format en pourcentages)."
    fi
    echo "$cpu_result"
    echo "$gpu_result"
}

sanitize() {
    printf '%s' "$1" | tr '\n\r|' '   '
}

status() {
    profile=stock
    if [ -r "$PROFILE_FILE" ]; then
        IFS= read -r profile < "$PROFILE_FILE"
    fi
    echo "profile|$(sanitize "$profile")"
    if grep -qx 'accepted-v2 risk-v2 privacy-v1' "$STATE_DIR/accepted" 2>/dev/null; then echo "consent|accepted"; else echo "consent|missing"; fi
    if [ -f "$STATE_DIR/allow-root-scripts" ]; then echo "scripts|allowed"; else echo "scripts|blocked"; fi
    echo "thermal_limit|$THERMAL_LIMIT_C"
    grep -qx 'accepted-v2 risk-v2 privacy-v1' "$STATE_DIR/accepted" 2>/dev/null || return 0

    echo "device|model|$(sanitize "$(getprop ro.product.model 2>/dev/null)")"
    echo "device|manufacturer|$(sanitize "$(getprop ro.product.manufacturer 2>/dev/null)")"
    echo "device|android|$(sanitize "$(getprop ro.build.version.release 2>/dev/null)")"
    echo "device|kernel|$(sanitize "$(uname -r 2>/dev/null)")"
    echo "device|chipset|$(sanitize "$(getprop ro.soc.model 2>/dev/null)")"
    echo "device|uptime|$(sanitize "$(awk '{printf \"%d\", $1/3600}' /proc/uptime 2>/dev/null)")"
    echo "device|load|$(sanitize "$(awk '{print $1\" / \"$2\" / \"$3}' /proc/loadavg 2>/dev/null)")"

    if [ -r /proc/meminfo ]; then
        awk '
            /^MemTotal:/ { total=$2 }
            /^MemAvailable:/ { available=$2 }
            END {
                if (total > 0) {
                    used=total-available
                    printf "memory|%d|%d|%d\n", used, total, (used*100/total)
                }
            }
        ' /proc/meminfo
    fi
    if command -v df >/dev/null 2>&1; then
        df -k /data 2>/dev/null | awk 'NR==2 && $2+0>0 { printf "storage|%d|%d|%d\n", $3, $2, ($3*100/$2) }'
    fi
    battery=/sys/class/power_supply/battery
    if [ -d "$battery" ]; then
        for metric in capacity status temp voltage_now current_now; do
            [ -r "$battery/$metric" ] || continue
            value=$(cat "$battery/$metric" 2>/dev/null)
            case "$metric" in
                temp) case "$value" in ''|*[!0-9-]*) continue ;; esac; value=$(awk "BEGIN {printf \"%.1f\", $value/10}") ;;
                voltage_now) case "$value" in ''|*[!0-9-]*) continue ;; esac; value=$(awk "BEGIN {printf \"%.2f\", $value/1000000}") ;;
                current_now) case "$value" in ''|*[!0-9-]*) continue ;; esac; value=$(awk "BEGIN {printf \"%.0f\", $value/1000}") ;;
            esac
            echo "battery|$metric|$(sanitize "$value")"
        done
    fi
    for interface in wlan0 rmnet_data0 rmnet0; do
        rx=/sys/class/net/$interface/statistics/rx_bytes
        tx=/sys/class/net/$interface/statistics/tx_bytes
        if [ -r "$rx" ] && [ -r "$tx" ]; then
            echo "network|$interface|$(cat "$rx" 2>/dev/null)|$(cat "$tx" 2>/dev/null)"
        fi
    done

    for node in $(list_cpu_governors); do
        value=$(cat "$node" 2>/dev/null)
        echo "cpu|$(sanitize "${node%/*}")|$(sanitize "$value")"
    done
    for policy in $(list_cpu_frequency_policies); do
        minimum=$(cat "$policy/cpuinfo_min_freq" 2>/dev/null)
        maximum=$(snapshot_value "$policy/scaling_max_freq")
        case "$maximum" in ''|*[!0-9]*) maximum=$(cat "$policy/cpuinfo_max_freq" 2>/dev/null) ;; esac
        current=$(cat "$policy/scaling_cur_freq" 2>/dev/null)
        case "$minimum:$maximum" in
            *[!0-9:]*|:*) continue ;;
        esac
        echo "cpu_range|$(sanitize "$policy")|$minimum|$maximum"
        [ -n "$current" ] && echo "cpu_freq|$(sanitize "$policy")|$(sanitize "$current")"
    done
    for node in $(list_gpu_governors); do
        value=$(cat "$node" 2>/dev/null)
        echo "gpu|$(sanitize "${node%/*}")|$(sanitize "$value")"
    done
    for device in $(list_gpu_frequency_devices); do
        minimum=$(snapshot_value "$device/min_freq")
        maximum=$(snapshot_value "$device/max_freq")
        case "$minimum" in ''|*[!0-9]*) minimum=$(cat "$device/min_freq" 2>/dev/null) ;; esac
        case "$maximum" in ''|*[!0-9]*) maximum=$(cat "$device/max_freq" 2>/dev/null) ;; esac
        current=$(cat "$device/cur_freq" 2>/dev/null)
        case "$minimum:$maximum" in
            *[!0-9:]*|:*) continue ;;
        esac
        echo "gpu_range|$(sanitize "$device")|$minimum|$maximum"
        [ -n "$current" ] && echo "gpu_freq|$(sanitize "$device")|$(sanitize "$current")"
    done

    for zone in /sys/class/thermal/thermal_zone[0-9]*; do
        [ -r "$zone/temp" ] || continue
        type=$(cat "$zone/type" 2>/dev/null)
        temp=$(cat "$zone/temp" 2>/dev/null)
        case "$temp" in
            ''|*[!0-9-]*) continue ;;
        esac
        if [ "$temp" -gt 1000 ] || [ "$temp" -lt -1000 ]; then
            temp=$(awk "BEGIN { printf \"%.1f\", $temp / 1000 }" 2>/dev/null)
        fi
        echo "thermal|$(sanitize "$type")|$(sanitize "$temp")"
    done
}

list_games() {
    mkdir -p "$PROFILE_DIR"
    for file in "$PROFILE_DIR"/game-*; do
        [ -f "$file" ] || continue
        name=${file##*/game-}
        package=$(sed -n 's/^package=//p' "$file" | head -n 1)
        title=$(sed -n 's/^name=//p' "$file" | head -n 1)
        min_mhz=$(sed -n 's/^cpu_min_mhz=//p' "$file" | head -n 1)
        max_mhz=$(sed -n 's/^cpu_max_mhz=//p' "$file" | head -n 1)
        gpu_mhz=$(sed -n 's/^gpu_max_mhz=//p' "$file" | head -n 1)
        frequency_unit=$(sed -n 's/^frequency_unit=//p' "$file" | head -n 1)
        if [ "$frequency_unit" != "mhz" ]; then
            min_percent=$(sed -n 's/^min_percent=//p' "$file" | head -n 1)
            max_percent=$(sed -n 's/^max_percent=//p' "$file" | head -n 1)
            gpu_percent=$(sed -n 's/^gpu_percent=//p' "$file" | head -n 1)
            : "${min_percent:=0}" "${max_percent:=100}" "${gpu_percent:=100}"
            for policy in $(list_cpu_frequency_policies); do
                hardware_min=$(cat "$policy/cpuinfo_min_freq" 2>/dev/null)
                hardware_max=$(snapshot_value "$policy/scaling_max_freq")
                case "$hardware_max" in ''|*[!0-9]*) hardware_max=$(cat "$policy/cpuinfo_max_freq" 2>/dev/null) ;; esac
                case "$hardware_min:$hardware_max" in *[!0-9:]*|:*) continue ;; esac
                span=$((hardware_max - hardware_min))
                min_mhz=$(frequency_to_mhz $((hardware_min + span / 100 * min_percent + span % 100 * min_percent / 100)))
                max_mhz=$(frequency_to_mhz $((hardware_min + span / 100 * max_percent + span % 100 * max_percent / 100)))
                break
            done
            for device in $(list_gpu_frequency_devices); do
                hardware_min=$(snapshot_value "$device/min_freq")
                hardware_max=$(snapshot_value "$device/max_freq")
                case "$hardware_min" in ''|*[!0-9]*) hardware_min=$(cat "$device/min_freq" 2>/dev/null) ;; esac
                case "$hardware_max" in ''|*[!0-9]*) hardware_max=$(cat "$device/max_freq" 2>/dev/null) ;; esac
                case "$hardware_min:$hardware_max" in *[!0-9:]*|:*) continue ;; esac
                span=$((hardware_max - hardware_min))
                gpu_mhz=$(frequency_to_mhz $((hardware_min + span / 100 * gpu_percent + span % 100 * gpu_percent / 100)))
                break
            done
        fi
        start_action=$(sed -n 's/^start_action=//p' "$file" | head -n 1)
        stop_action=$(sed -n 's/^stop_action=//p' "$file" | head -n 1)
        script_id=$(sed -n 's/^script=//p' "$file" | head -n 1)
        echo "game|$(sanitize "$name")|$(sanitize "$package")|$(sanitize "$title")|${min_mhz:-0}|${max_mhz:-0}|${gpu_mhz-}|${start_action:-gaming}|${script_id:-none}|${stop_action:-balanced}"
    done
}

list_installed_apps() {
    command -v pm >/dev/null 2>&1 || fail "commande Android pm indisponible."
    pm list packages -3 2>/dev/null | sed -n 's/^package://p' | sort -u | while IFS= read -r package; do
        case "$package" in
            ''|*[!a-zA-Z0-9._]*|.*|*.|*..*) continue ;;
        esac
        printf 'app|%s|%s\n' "$(sanitize "$package")" "$(sanitize "$package")"
    done
}

valid_game_id() {
    case "$1" in
        ''|*[!a-zA-Z0-9._-]*|.*|*.|*..*) return 1 ;;
        *) return 0 ;;
    esac
}

save_game() {
    require_root
    require_consent
    id=$2
    package=$3
    title=$4
    min_mhz=$5
    max_mhz=$6
    gpu_mhz=$7
    start_action=$8
    stop_action=$9
    script_id=${10}
    [ "$1" = "save-game" ] || fail "commande invalide."
    valid_game_id "$id" || fail "identifiant de jeu invalide."
    case "$package" in
        *[!a-zA-Z0-9._]*|'') fail "nom de paquet Android invalide." ;;
    esac
    case "$package" in
        *.*) ;;
        *) fail "le nom de paquet doit contenir un point." ;;
    esac
    case "$package" in
        .*|*.|*..*) fail "nom de paquet Android invalide." ;;
    esac
    command -v pm >/dev/null 2>&1 || fail "commande Android pm indisponible."
    pm path "$package" 2>/dev/null | grep -q '^package:' || fail "paquet Android introuvable sur cet appareil."
    case "$title" in
        *[!a-zA-Z0-9._\ -]*|'') fail "nom de jeu invalide (lettres/chiffres/espaces uniquement)." ;;
    esac
    : "${min_mhz:=0}" "${max_mhz:=0}" "${start_action:=gaming}" "${stop_action:=balanced}"
    validate_frequency_mhz "$min_mhz"
    validate_frequency_mhz "$max_mhz"
    [ -z "$gpu_mhz" ] || validate_frequency_mhz "$gpu_mhz"
    [ "$min_mhz" -le "$max_mhz" ] || fail "le minimum CPU ne peut pas dépasser le maximum."
    case "$start_action" in none|gaming|balanced|stock) ;; *) fail "action autorisée: none, gaming, balanced ou stock." ;; esac
    case "$stop_action" in none|gaming|balanced|stock) ;; *) fail "action d'arrêt autorisée: none, gaming, balanced ou stock." ;; esac
    : "${script_id:=none}"
    case "$script_id" in none) ;; *[!a-zA-Z0-9_-]*) fail "identifiant de script invalide." ;; esac
    if [ "$script_id" != "none" ]; then
        [ -f "$STATE_DIR/allow-root-scripts" ] || fail "activez d'abord l'autorisation séparée des scripts root."
        [ -f "$MODDIR/game-scripts/$script_id.sh" ] && [ ! -L "$MODDIR/game-scripts/$script_id.sh" ] || fail "script local introuvable ou lien symbolique interdit: game-scripts/$script_id.sh"
    fi
    mkdir -p "$PROFILE_DIR" || fail "impossible de créer les profils."
    file=$PROFILE_DIR/game-$id
    tmp=$file.tmp
    {
        printf 'name=%s\n' "$title"
        printf 'package=%s\n' "$package"
        printf 'frequency_unit=mhz\ncpu_min_mhz=%s\ncpu_max_mhz=%s\ngpu_max_mhz=%s\nstart_action=%s\nstop_action=%s\nscript=%s\n' "$min_mhz" "$max_mhz" "$gpu_mhz" "$start_action" "$stop_action" "$script_id"
    } > "$tmp" || fail "impossible d'enregistrer le profil."
    mv "$tmp" "$file" || fail "impossible de finaliser le profil."
    echo "Profil de jeu enregistré: $title ($package)."
}

remove_game() {
    require_root
    require_consent
    id=$1
    valid_game_id "$id" || fail "identifiant de jeu invalide."
    file=$PROFILE_DIR/game-$id
    [ -f "$file" ] || fail "profil de jeu introuvable."
    if [ -r "$PROFILE_FILE" ] && [ "$(cat "$PROFILE_FILE" 2>/dev/null)" = "game-$id" ]; then
        apply_profile balanced
    fi
    rm -f "$file" || fail "impossible de supprimer le profil."
    echo "Profil de jeu supprimé: $id."
}

detect_game_package() {
    focused=$(dumpsys activity activities 2>/dev/null | sed -n -E '/(mResumedActivity|topResumedActivity)/s/.* u[0-9]+ ([A-Za-z0-9._]+)\/.*/\1/p' | head -n 1)
    if [ -z "$focused" ]; then
        focused=$(dumpsys window 2>/dev/null | sed -n -E '/mCurrentFocus|mFocusedApp/s/.* u[0-9]+ ([A-Za-z0-9._]+)\/.*/\1/p' | head -n 1)
    fi
    [ -n "$focused" ] || return 1
    for file in "$PROFILE_DIR"/game-*; do
        [ -f "$file" ] || continue
        package=$(sed -n 's/^package=//p' "$file" | head -n 1)
        [ -n "$package" ] || continue
        if [ "$focused" = "$package" ]; then
            echo "${file##*/game-}"
            return 0
        fi
    done
    return 1
}

auto_apply() {
    require_root
    last=none
    initialized=0
    thermal_limited=0
    desired_profile=stock
    while :; do
        if ! grep -qx 'accepted-v2 risk-v2 privacy-v1' "$STATE_DIR/accepted" 2>/dev/null; then
            if [ "$initialized" -eq 1 ]; then
                restore_snapshot || :
                initialized=0
                last=none
                thermal_limited=0
            fi
            sleep 10
            continue
        fi
        if [ "$initialized" -eq 0 ]; then
            desired_profile=stock
            [ -r "$PROFILE_FILE" ] && IFS= read -r desired_profile < "$PROFILE_FILE"
            case "$desired_profile" in
                stock|balanced|gaming) apply_profile "$desired_profile" ;;
                game-*) desired_profile=balanced; apply_profile balanced ;;
                *) desired_profile=stock; apply_profile stock ;;
            esac
            initialized=1
        fi
        if game_id=$(detect_game_package); then
            if [ "$game_id" != "$last" ]; then
                apply_game "$game_id"
                last=$game_id
                thermal_limited=0
            fi
        elif [ "$last" != "none" ]; then
            id=$last
            file=$PROFILE_DIR/game-$id
            stop_action=$(sed -n 's/^stop_action=//p' "$file" | head -n 1)
            : "${stop_action:=balanced}"
            run_game_action "$stop_action"
            last=none
            thermal_limited=0
        fi
        if [ "$last" = "none" ] && [ "$thermal_limited" -eq 0 ] && [ -r "$PROFILE_FILE" ]; then
            requested_profile=$(sed -n '1p' "$PROFILE_FILE")
            case "$requested_profile" in
                stock|balanced|gaming)
                    if [ "$requested_profile" != "$desired_profile" ]; then
                        apply_profile "$requested_profile"
                        desired_profile=$requested_profile
                    fi
                    ;;
            esac
        fi
        should_limit=0
        [ "$last" != "none" ] && should_limit=1
        [ "$desired_profile" = "gaming" ] && should_limit=1
        if [ "$should_limit" -eq 1 ]; then
            temp=$(read_temp_c 2>/dev/null) || temp=0
            case "$temp" in *[!0-9]*|'') temp=0 ;; esac
            if [ "$temp" -ge "$THERMAL_LIMIT_C" ] && [ "$temp" -gt 0 ] && [ "$thermal_limited" -eq 0 ]; then
                apply_profile balanced
                thermal_limited=1
                echo "Ultra Gaming Mode: limite thermique ${temp} C, profil équilibré temporaire." >&2
            elif [ "$temp" -lt "$THERMAL_RESUME_C" ] && [ "$temp" -gt 0 ] && [ "$thermal_limited" -eq 1 ]; then
                if [ "$last" != "none" ]; then
                    apply_game "$last"
                else
                    apply_profile "$desired_profile"
                fi
                thermal_limited=0
            fi
        fi
        sleep 10
    done
}

case "$1" in
    snapshot) snapshot ;;
    status) status ;;
    games) list_games ;;
    apply)
        [ -n "$2" ] || fail "usage: control.sh apply stock|balanced|gaming"
        case "$2" in game-*) valid_game_id "${2#game-}" || fail "identifiant de jeu invalide."; apply_profile gaming ;; *) apply_profile "$2" ;; esac
        ;;
    set-cpu)
        require_root
        require_consent
        validate_percent_pair "$2" "$3"
        apply_cpu_limits "$2" "$3"
        echo "Limites CPU demandées: $2-$3% des fréquences exposées."
        ;;
    set-gpu)
        require_root
        require_consent
        case "$2" in *[!0-9]*|'') fail "pourcentage GPU invalide." ;; esac
        [ "$2" -le 100 ] || fail "plafond GPU maximum: 100% des fréquences exposées."
        apply_gpu_limits 0 "$2"
        echo "Plafond GPU demandé: $2% des fréquences exposées."
        ;;
    save-game) save_game "$@" ;;
    apps) list_installed_apps ;;
    set-cpu-mhz)
        require_root
        require_consent
        apply_cpu_frequency_mhz "$2" "$3"
        ;;
    set-gpu-mhz)
        require_root
        require_consent
        apply_gpu_frequency_mhz "$2"
        ;;
    remove-game) [ -n "$2" ] || fail "usage: control.sh remove-game ID"; remove_game "$2" ;;
    apply-game) [ -n "$2" ] || fail "usage: control.sh apply-game ID"; apply_game "$2" ;;
    accept)
        require_root
        [ "$2" = "risk-v2" ] && [ "$3" = "privacy-v1" ] || fail "confirmation de risque et confidentialité requise."
        mkdir -p "$STATE_DIR" || fail "impossible de créer les données."
        printf 'accepted-v2 risk-v2 privacy-v1\n' > "$STATE_DIR/accepted" || fail "impossible d'enregistrer le consentement."
        echo "Consentement enregistré sur cet appareil."
        ;;
    allow-scripts)
        require_root
        require_consent
        case "$2" in
            yes) printf 'enabled\n' > "$STATE_DIR/allow-root-scripts" || fail "impossible d'activer les scripts." ;;
            no) rm -f "$STATE_DIR/allow-root-scripts" || fail "impossible de désactiver les scripts." ;;
            *) fail "usage: control.sh allow-scripts yes|no" ;;
        esac
        echo "Autorisation des scripts root mise à jour."
        ;;
    decline)
        require_root
        rm -f "$STATE_DIR/accepted" || fail "impossible de retirer le consentement."
        rm -f "$STATE_DIR/allow-root-scripts" || fail "impossible de désactiver les scripts root."
        restore_snapshot
        echo "Consentement retiré et gouverneurs initiaux restaurés."
        ;;
    auto) auto_apply ;;
    *)
        fail "usage: control.sh status|games|apps|apply PROFILE|set-cpu-mhz MIN_MHZ MAX_MHZ|set-gpu-mhz MAX_MHZ|save-game ID PACKAGE NAME CPU_MIN_MHZ CPU_MAX_MHZ GPU_MAX_MHZ ACTION [STOP_ACTION [SCRIPT]]|remove-game ID|apply-game ID|accept risk-v2 privacy-v1|allow-scripts yes|no|decline|auto"
        ;;
esac
