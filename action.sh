#!/system/bin/sh
# Manual control for the Magisk Manager "Action" button, or from shell:
#
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh set <0-100>"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh cycle"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh restart"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh auto"   (default)
#
#   status   - print current duty/rpm/skin temp/tier/vendor state + tier table
#   enable   - enter MCU test mode and let service.sh drive the fan
#   disable  - exit test mode, restore stock policy
#   set N    - pin the fan to a fixed duty N% (0-100) until restart or disable
#   cycle    - walk through QUIET -> IDLE -> WARM -> HOT -> VERYHOT -> (back to QUIET)
#   restart  - kill and respawn service.sh (picks up config.cfg edits)
#   auto     - follow the persisted state/enabled flag (what boot does)
#
# The enable/disable choice is persisted in state/enabled, so a reboot keeps
# the user's last choice.

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="$MODDIR/state"
CONFIG_FILE="$MODDIR/config.cfg"
ENABLED="$STATE_DIR/enabled"
IN_TEST="$STATE_DIR/in_test"
CUR_DUTY="$STATE_DIR/cur_duty"
CUR_TIER="$STATE_DIR/cur_tier"
PINNED="$STATE_DIR/pinned"
TOOL="/system/bin/gd32ipdclient_test"
TEMP_NODE="/sys/class/thermal/thermal_zone86/temp"
SVC="$MODDIR/service.sh"

mkdir -p "$STATE_DIR" 2>/dev/null

# Load the same config the service uses, so status shows real thresholds.
TIER_QUIET=0; TIER_IDLE=45; TIER_WARM=55; TIER_HOT=65; TIER_VERYHOT=78
T0=38000; T1=47000; T2=50000; T3=53000; T4=56000
HYSTERESIS=400
if [ -r "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE" 2>/dev/null
fi

CMD="${1:-auto}"
ARG="${2:-}"

in_test_mode() {
    [ -f "$IN_TEST" ]
}

vendor_running() {
    [ "$(getprop init.svc.pxrfanservice 2>/dev/null)" = "running" ]
}

is_pinned() {
    [ -f "$PINNED" ]
}

take_over() {
    out=$($TOOL setfantestmode 1 2>/dev/null)
    case "$out" in
        *success*) : > "$IN_TEST"; return 0 ;;
        *)         return 1 ;;
    esac
}

hand_back() {
    rm -f "$IN_TEST" "$PINNED"
    $TOOL setfantestmode 0 >/dev/null 2>&1
    # The MCU-side lock does not clear on exit alone; restarting pxrfanservice
    # forces the re-handshake that makes the MCU accept vendor duty frames.
    setprop sys.pxrfanservice.state 2
    n=0
    while [ "$n" -lt 15 ]; do
        vendor_running && [ "$n" -ge 3 ] && return 0
        sleep 1
        n=$((n + 1))
    done
    return 1
}

pin_duty() {
    # $1 = duty 0-100. Pins the fan to that duty until disable or restart.
    [ "$1" -ge 0 ] 2>/dev/null || { echo "无效 duty: $1"; return 1; }
    [ "$1" -le 100 ] 2>/dev/null || { echo "无效 duty: $1"; return 1; }
    if ! in_test_mode; then
        if ! take_over; then
            echo "开启 test mode 失败"
            return 1
        fi
    fi
    out=$($TOOL setfantestspeed "$1" 2>/dev/null)
    case "$out" in
        *success*) echo "$1" > "$PINNED"; echo "已固定 duty=$1%" ;;
        *) echo "固定失败"; return 1 ;;
    esac
    # Kill service.sh so it does not re-evaluate and override the pin.
    pkill -f "$(basename "$SVC")" 2>/dev/null
    return 0
}

cycle_step() {
    # Walk through tiers in order. Each invocation moves one step forward,
    # wrapping from VERYHOT back to QUIET.
    #
    # POSIX sh gotcha: "for s in $var" splits on IFS (space/newline/tab), but
    # "for s in \"$var\"" treats the whole string as a single word. We must
    # use the unquoted form or `set --` first.
    tiers="QUIET IDLE WARM HOT VERYHOT"

    # Locate current tier index (0-based). Default to QUIET (0) if unknown.
    cur=$(cat "$CUR_TIER" 2>/dev/null)
    case "$cur" in QUIET|IDLE|WARM|HOT|VERYHOT) ;; *) cur="QUIET" ;; esac

    idx=0
    i=0
    set -- $tiers
    for s in "$@"; do
        [ "$s" = "$cur" ] && idx=$i
        i=$((i + 1))
    done

    # Advance with wrap-around.
    next_idx=$(( (idx + 1) % 5 ))
    i=0
    next=""
    set -- $tiers
    for s in "$@"; do
        [ "$i" = "$next_idx" ] && { next="$s"; break; }
        i=$((i + 1))
    done

    echo "$next" > "$CUR_TIER"
    case "$next" in
        QUIET)   d="$TIER_QUIET" ;;
        IDLE)    d="$TIER_IDLE" ;;
        WARM)    d="$TIER_WARM" ;;
        HOT)     d="$TIER_HOT" ;;
        VERYHOT) d="$TIER_VERYHOT" ;;
        *) echo "未知档位: $next"; return 1 ;;
    esac

    if ! in_test_mode; then
        take_over || { echo "test mode 失败"; return 1; }
    fi
    out=$($TOOL setfantestspeed "$d" 2>/dev/null)
    case "$out" in
        *success*) echo "已切到 $next 档 (duty=$d%)"
                   pkill -f "$(basename "$SVC")" 2>/dev/null
                   return 0 ;;
        *) echo "切档失败"; return 1 ;;
    esac
}

tier_table() {
    # Print the tier table using the current config values, so the user can
    # see what they are about to live with without opening service.sh.
    echo "档位表 (来自 config.cfg):"
    printf "  < %-5sC  quiet   duty=%s%%\n" "$((T0 / 1000))" "$TIER_QUIET"
    printf "  %-5s-%-5sC  idle    duty=%s%%\n" "$((T0 / 1000))" "$((T1 / 1000))" "$TIER_IDLE"
    printf "  %-5s-%-5sC  warm    duty=%s%%\n" "$((T1 / 1000))" "$((T2 / 1000))" "$TIER_WARM"
    printf "  %-5s-%-5sC  hot     duty=%s%%\n" "$((T2 / 1000))" "$((T3 / 1000))" "$TIER_HOT"
    printf "  %-5s-%-5sC  vhot    duty=%s%%\n" "$((T3 / 1000))" "$((T4 / 1000))" "$TIER_VERYHOT"
    printf "  >= %sC       交回原厂策略\n" "$((T4 / 1000))"
    printf "  滞回 HYSTERESIS=%s mC (%sC)\n" "$HYSTERESIS" "$(awk "BEGIN{printf \"%.1f\", $HYSTERESIS/1000}")"
}

status() {
    echo "== 风扇温控状态 =="
    if in_test_mode; then
        if is_pinned; then
            echo "模式: 手动固定 (duty=$(cat "$PINNED")%)"
        elif [ -f "$ENABLED" ]; then
            echo "模式: 本模块温控 (duty 由皮肤温度决定)"
        else
            echo "模式: MCU test mode 已开，但 service.sh 未运行"
        fi
    elif vendor_running; then
        echo "模式: 原厂温控 (PICO 自带策略)"
    else
        echo "模式: 异常 (vendor 服务未运行)"
    fi

    t=$(cat "$TEMP_NODE" 2>/dev/null)
    info=$($TOOL getfaninfo 2>/dev/null)
    d=$(echo "$info" | sed -n 's/^duty=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    r=$(echo "$info" | sed -n 's/^rpm=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    v=$(getprop init.svc.pxrfanservice 2>/dev/null)
    svc=$(pidof "$(basename "$SVC")" 2>/dev/null || true)
    [ -z "$svc" ] && svc=$(pgrep -f "$(basename "$SVC")" 2>/dev/null || true)
    cur_tier=$(cat "$CUR_TIER" 2>/dev/null || echo "(none)")
    cur_duty=$(cat "$CUR_DUTY" 2>/dev/null || echo "(none)")

    if [ -n "$t" ]; then t_c="$((t / 1000))"; else t_c="?"; fi
    printf "皮肤温度 %s°C | 风扇 duty=%s%% rpm=%s\n" "$t_c" "${d:-?}" "${r:-?}"
    printf "vendor=%s | 当前档=%s (上次写入 duty=%s)\n" "${v:-?}" "$cur_tier" "$cur_duty"
    [ -n "$svc" ] && printf "service.sh PID=%s\n" "$svc"

    echo ""
    tier_table
}

restart_service() {
    pkill -f "$(basename "$SVC")" 2>/dev/null
    sleep 2
    nohup sh "$SVC" >/dev/null 2>&1 &
    sleep 3
    new=$(pgrep -f "$(basename "$SVC")" 2>/dev/null || true)
    if [ -n "$new" ]; then
        echo "已重启 service.sh (PID=$new)，已加载最新 config.cfg"
        return 0
    fi
    echo "重启失败，service.sh 未运行"
    return 1
}

case "$CMD" in
    status)
        status
        ;;
    enable)
        if pin_to=$(cat "$PINNED" 2>/dev/null); then :; fi
        if is_pinned; then
            rm -f "$PINNED"
        fi
        if take_over; then
            : > "$ENABLED"
            echo "已开启本模块温控"
        else
            echo "开启失败 (setfantestmode 1 被拒绝)"
        fi
        status
        ;;
    disable)
        if hand_back; then
            rm -f "$ENABLED"
            echo "已恢复原厂温控"
        else
            echo "恢复失败 (vendor 服务未能重新握手)"
        fi
        status
        ;;
    set)
        if [ -z "$ARG" ]; then
            echo "用法: action.sh set <0-100>"
            exit 1
        fi
        if [ "$ARG" -lt 0 ] 2>/dev/null || [ "$ARG" -gt 100 ] 2>/dev/null; then
            echo "无效 duty: $ARG (需 0-100)"
            exit 1
        fi
        pin_duty "$ARG"
        status
        ;;
    cycle)
        cycle_step
        status
        ;;
    restart)
        restart_service
        status
        ;;
    auto|off|on)
        # 'auto' means: follow whatever the flag says, which is what boot does.
        # 'on'  = take over, 'off' = hand back. Kept short for convenience.
        if [ "$CMD" = "on" ]; then
            take_over && : > "$ENABLED" || exit 1
            echo "已开启本模块温控"
        elif [ "$CMD" = "off" ]; then
            hand_back && rm -f "$ENABLED" || exit 1
            echo "已恢复原厂温控"
        fi
        status
        ;;
    *)
        echo "用法: action.sh [status|enable|disable|set <0-100>|cycle|restart|on|off|auto]"
        exit 1
        ;;
esac

exit 0
