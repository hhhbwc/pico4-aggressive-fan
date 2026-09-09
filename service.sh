#!/system/bin/sh
# PICO 4 Fan Auto Temp Control
#
# Why this exists:
#   The vendor fan driver (pxrfanservice) owns the fan. Measured on this unit,
#   its policy is very conservative:
#     idle  ~ duty 30-40%, ~7050 RPM
#     load  ~ duty 30->35%, ~6200 RPM, then LOCKED
#   Skin-msm temperature climbed from 45.7C to 51.8C under 5 minutes of heavy
#   CPU load and the vendor never raised the fan again.
#
# This module replaces that policy with a skin-temperature stepped curve, one
# tier above the vendor's. At the overheat tier it exits test mode so the
# vendor's own duty writes are accepted again, letting its high-temp protection
# logic come back.
#
# HOW IT WORKS (no service killing required):
#   /system/bin/gd32ipdclient_test setfantestmode 1
#   ...
#   /system/bin/gd32ipdclient_test setfantestspeed <pct>
#
# The GD32 MCU keeps "test mode" as a firmware state. While it is set, the
# MCU rejects the vendor's SetFanSpeed frames (logcat shows the vendor's
# "79 32 00 4b" frame getting "retry_cnt=3 ret=4" from the MCU) while still
# accepting setfantestspeed. That is the clean lock: pxrfanservice keeps
# running and doing its bookkeeping, but its duty writes never reach the motor.
#
# Exiting test mode is NOT enough to restore vendor control on its own: the
# lock only clears when pxrfanservice re-initialises (a fresh handshake frame
# "79 00 00 00 28 23 00 00 01 73" is then accepted with ret=10). So the
# overheat path below toggles pxrfanservice to force that re-handshake.
#
# NOTE: runs as root from Magisk; gd32ipdclient_test talks to a root-only
# binder service.

LOG_TAG="PicoFanTC"
# Resolve the module dir from our own path so the script also works when
# tested from a scratch location instead of the installed module path.
MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="$MODDIR/state"
ENABLED="$STATE_DIR/enabled"
CUR_DUTY="$STATE_DIR/cur_duty"
IN_TEST="$STATE_DIR/in_test"

TOOL="/system/bin/gd32ipdclient_test"
TEMP_NODE="/sys/class/thermal/thermal_zone86/temp"   # skin-msm-therm-usr, millidegrees C

mkdir -p "$STATE_DIR" 2>/dev/null

# Tier table, lowest first. Overheat hands control back to the vendor.
TIER_IDLE="45"
TIER_WARM="55"
TIER_HOT="65"
TIER_VERYHOT="78"

# Thresholds, in millidegrees C.
T1=47000   # idle -> warm
T2=50000   # warm -> hot
T3=53000   # hot -> very hot
T4=56000   # very hot -> overheat (hand back to vendor)

LOOP_INTERVAL=5          # seconds
STARTUP_GRACE=45         # seconds after boot before taking over

log() {
    # Use the absolute path: naming this function "log" shadows the binary, so a
    # bare "log" here would recurse forever and flood logd.
    /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null || echo "$LOG_TAG: $*"
}

# ---------------------------------------------------------------------------
# Fan access. gd32ipdclient_test prints e.g. "setrfantestspeed 55 success" and
# "duty=55 rpm=8530 rpm_target=9000 ..." so we parse the first trailing number.
# ---------------------------------------------------------------------------

set_duty() {
    # $1 = duty percent 0-100
    [ "$1" -ge 0 ] 2>/dev/null || return 1
    [ "$1" -le 100 ] 2>/dev/null || return 1
    out="$($TOOL setfantestspeed "$1" 2>/dev/null)"
    case "$out" in
        *success*) return 0 ;;
        *)         return 1 ;;
    esac
}

get_duty() {
    # $1 = max seconds to wait for a valid reply
    wait_s="${1:-3}"
    n=0
    while [ "$n" -lt "$wait_s" ]; do
        out="$($TOOL getfaninfo 2>/dev/null)"
        d=$(echo "$out" | sed -n 's/^duty=\([0-9][0-9]*\).*/\1/p' | head -n 1)
        if [ -n "$d" ] && [ "$d" -le 100 ] 2>/dev/null; then
            echo "$d"
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# Test mode (the MCU-side lock)
# ---------------------------------------------------------------------------

enter_test_mode() {
    if [ -f "$IN_TEST" ]; then
        return 0
    fi
    out="$($TOOL setfantestmode 1 2>/dev/null)"
    case "$out" in
        *success*) : > "$IN_TEST"; return 0 ;;
        *)         return 1 ;;
    esac
}

# Exit test mode AND force the vendor to re-handshake with the MCU, because the
# lock does not clear on exit alone. Restarting pxrfanservice makes the MCU
# accept vendor duty frames again (observed: ret=10 after restart, ret=4 before).
exit_test_mode() {
    rm -f "$IN_TEST"
    $TOOL setfantestmode 0 >/dev/null 2>&1
    setprop sys.pxrfanservice.state 2
    n=0
    while [ "$n" -lt 15 ]; do
        s=$(getprop init.svc.pxrfanservice 2>/dev/null)
        [ "$s" = "running" ] && [ "$n" -ge 3 ] && return 0
        sleep 1
        n=$((n + 1))
    done
    log "vendor re-handshake did not complete"
    return 1
}

# ---------------------------------------------------------------------------
# Tier selection. Reads the skin sensor; on read failure keeps the last known
# duty rather than guessing, so a transient sensor glitch cannot drop the fan.
# ---------------------------------------------------------------------------

pick_tier() {
    t=$(cat "$TEMP_NODE" 2>/dev/null)
    case "$t" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$t" -ge "$T4" ]; then
        echo "OVERHEAT"
    elif [ "$t" -ge "$T3" ]; then
        echo "$TIER_VERYHOT"
    elif [ "$t" -ge "$T2" ]; then
        echo "$TIER_HOT"
    elif [ "$t" -ge "$T1" ]; then
        echo "$TIER_WARM"
    else
        echo "$TIER_IDLE"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Enable / disable
# ---------------------------------------------------------------------------

enable() {
    if ! enter_test_mode; then
        return 1
    fi
    : > "$ENABLED"
    log "MCU test mode engaged, vendor duty writes now rejected"
    return 0
}

disable() {
    rm -f "$ENABLED"
    exit_test_mode
    log "MCU test mode exited, vendor fan policy restored"
    return 0
}

is_enabled() {
    [ -f "$ENABLED" ]
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

main() {
    # Give the vendor services time to boot and the sensors to settle.
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
        sleep 2
    done
    sleep "$STARTUP_GRACE"

    if ! [ -x "$TOOL" ]; then
        log "ERROR: $TOOL missing or not executable, cannot control fan"
        return 1
    fi
    if [ ! -r "$TEMP_NODE" ]; then
        log "ERROR: temp node $TEMP_NODE missing"
        return 1
    fi

    # Honor a manual disable flag left by action.sh, so a reboot keeps the
    # user's last choice. If we are still in MCU test mode from a previous
    # session (power-loss edge case), make sure we own it or leave it cleanly.
    if is_enabled; then
        log "resuming: previous session ended with module control active"
        enter_test_mode
    else
        if [ -f "$IN_TEST" ]; then
            log "found stale test-mode flag, exiting test mode to restore vendor"
            exit_test_mode
        fi
        if ! enable; then
            log "ERROR: failed to enter test mode"
            return 1
        fi
    fi

    cur=""
    n=0
    while : ; do
        tier=$(pick_tier)
        if [ -z "$tier" ]; then
            # Sensor read failed; keep last duty, do not guess.
            sleep "$LOOP_INTERVAL"
            continue
        fi

        # Overheat: hand the fan back to the vendor so its high-temp protection
        # runs. This is a state change, not a per-loop action.
        if [ "$tier" = "OVERHEAT" ]; then
            if [ -f "$IN_TEST" ]; then
                t=$(cat "$TEMP_NODE" 2>/dev/null)
                exit_test_mode
                rm -f "$ENABLED"
                cur=""
                log "skin $((t / 1000))C over heat, MCU test mode exited, vendor policy restored"
            fi
            sleep "$LOOP_INTERVAL"
            continue
        fi

        # If the vendor re-took control (test mode fell out), re-engage.
        if [ ! -f "$IN_TEST" ]; then
            t=$(cat "$TEMP_NODE" 2>/dev/null)
            if enter_test_mode; then
                log "re-engaged MCU test mode (was disengaged at skin $((t / 1000))C)"
                cur=""
            fi
        fi

        # Hysteresis: only touch the fan when the tier actually changes, so the
        # MCU is not ping-ponged on a single-degree wobble.
        if [ "$tier" = "$cur" ]; then
            sleep "$LOOP_INTERVAL"
            continue
        fi

        if set_duty "$tier"; then
            got=$(get_duty 4)
            cur="$tier"
            echo "$tier" > "$CUR_DUTY"
            t=$(cat "$TEMP_NODE" 2>/dev/null)
            log "skin $((t / 1000))C tier -> duty $tier (reported ${got:-?})"
        else
            log "setfantestspeed $tier failed, will retry"
        fi

        n=$((n + 1))
        # Every ~30s verify we still hold the value we asked for. If something
        # drifted us away, re-assert without chattering the log.
        if [ $((n % 6)) -eq 0 ]; then
            held=$(get_duty 4)
            if [ -n "$held" ] && [ "$held" != "$cur" ]; then
                log "drift detected: wanted $cur, MCU reports $held, re-asserting"
                set_duty "$cur" >/dev/null 2>&1
            fi
        fi

        sleep "$LOOP_INTERVAL"
    done
}

main "$@"
