#!/system/bin/sh
# Manual control for the Magisk Manager "Action" button, or from shell:
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"
#   su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh auto"   (default)
#
# The choice is persisted in state/enabled, so a reboot keeps it.

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="$MODDIR/state"
ENABLED="$STATE_DIR/enabled"
IN_TEST="$STATE_DIR/in_test"
TOOL="/system/bin/gd32ipdclient_test"
TEMP_NODE="/sys/class/thermal/thermal_zone86/temp"

mkdir -p "$STATE_DIR" 2>/dev/null
CMD="${1:-auto}"

report() {
    t=$(cat "$TEMP_NODE" 2>/dev/null)
    info=$($TOOL getfaninfo 2>/dev/null)
    d=$(echo "$info" | sed -n 's/^duty=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    r=$(echo "$info" | sed -n 's/^rpm=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    v=$(getprop init.svc.pxrfanservice 2>/dev/null)
    if [ -n "$t" ]; then t="$((t / 1000))C"; else t="n/a"; fi
    echo "皮肤温度 $t | 风扇 duty=${d:-?}% rpm=${r:-?} | vendor策略=${v:-?}"
}

in_test_mode() {
    # Trust the state file first; fall back to probing the MCU.
    [ -f "$IN_TEST" ] && return 0
    return 1
}

vendor_running() {
    [ "$(getprop init.svc.pxrfanservice 2>/dev/null)" = "running" ]
}

take_over() {
    out=$($TOOL setfantestmode 1 2>/dev/null)
    case "$out" in
        *success*) : > "$IN_TEST"; return 0 ;;
        *)         return 1 ;;
    esac
}

hand_back() {
    rm -f "$IN_TEST"
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

case "$CMD" in
    status)
        echo "== 风扇温控状态 =="
        if in_test_mode; then
            if [ -f "$ENABLED" ]; then
                echo "模式: 本模块温控 (MCU 测试模式, duty 由皮肤温度决定)"
            else
                echo "模式: 手动固定 (MCU 测试模式已开, duty 不再自动变化)"
            fi
        elif vendor_running; then
            echo "模式: 原厂温控 (PICO 自带策略)"
        else
            echo "模式: 异常 (vendor 服务未运行)"
        fi
        report
        ;;
    enable)
        rm -f "$ENABLED"
        if take_over; then
            : > "$ENABLED"
            echo "已开启本模块温控"
        else
            echo "开启失败 (setfantestmode 1 被拒绝)"
        fi
        report
        ;;
    disable)
        if hand_back; then
            rm -f "$ENABLED"
            echo "已恢复原厂温控"
        else
            echo "恢复失败 (vendor 服务未能重新握手)"
        fi
        report
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
        report
        ;;
    *)
        echo "用法: action.sh [status|enable|disable|on|off|auto]"
        exit 1
        ;;
esac

exit 0
