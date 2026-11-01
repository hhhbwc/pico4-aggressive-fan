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
#   disable  - exit test mode, restore stock policy (persistent across reboot)
#   set N    - pin the fan to a fixed duty N% (0-100) until restart or disable
#   cycle    - walk through QUIET -> IDLE -> WARM -> HOT -> VERYHOT -> (back to QUIET)
#   restart  - kill and respawn service.sh (picks up config.cfg edits)
#   auto     - follow the persisted state flag (what boot does)
#
# 修补说明：上游的 disable 其实不持久 —— 它把 enabled 和 in_test 都删掉，
# 于是重启后 service.sh 会走到"自动接管"分支又自己开起来，表现为
# "明明关了，重启自己又开了"。修补版新增 state/disabled 标记：
#   disable / off -> 写 disabled，service.sh 重启后不再自动接管
#   enable  / on  / set / cycle -> 清掉 disabled

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="$MODDIR/state"
CONFIG_FILE="$MODDIR/config.cfg"
ENABLED="$STATE_DIR/enabled"
DISABLED="$STATE_DIR/disabled"
IN_TEST="$STATE_DIR/in_test"
CUR_DUTY="$STATE_DIR/cur_duty"
CUR_TIER="$STATE_DIR/cur_tier"
PINNED="$STATE_DIR/pinned"
LAST_OK="$STATE_DIR/last_ok"
GAVE_UP="$STATE_DIR/gave_up"
PID_FILE="$STATE_DIR/service.pid"
TOOL="/system/bin/gd32ipdclient_test"
TEMP_NODE="/sys/class/thermal/thermal_zone86/temp"
SVC="$MODDIR/service.sh"

mkdir -p "$STATE_DIR" 2>/dev/null

# Load the same config the service uses, so status shows real thresholds.
TIER_QUIET=0; TIER_IDLE=25; TIER_WARM=55; TIER_HOT=65; TIER_VERYHOT=78
T0=41000; T1=47000; T2=50000; T3=53000; T4=56000
HYSTERESIS=800
RPM_CAP=12000; RPM_DUTY=88; RPM_RELEASE_RANK=3
OVERHEAT_RELEASE_RANK=3
MAX_FAIL_STREAK=10

# 优先用 service.sh --dumpcfg 的输出：那是**校验后**的生效值。
# 直接 source config.cfg 会出现"配置写错了，但 status 显示的还是错的值"，
# 排查时被误导。拿不到就退回老办法（去 CR 后 source）。
if [ -r "$SVC" ] && sh "$SVC" --dumpcfg > "$STATE_DIR/config.effective" 2>/dev/null; then
    . "$STATE_DIR/config.effective" 2>/dev/null
    rm -f "$STATE_DIR/config.effective" 2>/dev/null
elif [ -r "$CONFIG_FILE" ]; then
    # 与 service.sh 一致：先去掉 CR，避免 CRLF 配置里的回车跑进状态表和 duty 值。
    CFG_NORM="$STATE_DIR/config.norm"
    if command -v tr >/dev/null 2>&1 \
       && tr -d '\r' < "$CONFIG_FILE" > "$CFG_NORM" 2>/dev/null; then
        . "$CFG_NORM" 2>/dev/null
        rm -f "$CFG_NORM" 2>/dev/null
    else
        . "$CONFIG_FILE" 2>/dev/null
    fi
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

is_disabled() {
    [ -f "$DISABLED" ]
}

# 只认 pid 文件里记的那个进程，不再靠 pgrep -f 猜。
# pgrep/pkill 在部分精简环境不存在，或匹配串过宽会误判/误杀。
svc_pid() {
    _p=""
    [ -r "$PID_FILE" ] && read -r _p < "$PID_FILE" 2>/dev/null
    [ -n "$_p" ] || return 1
    kill -0 "$_p" 2>/dev/null || return 1
    if [ -r "/proc/$_p/cmdline" ]; then
        tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q "service.sh" || return 1
    fi
    echo "$_p"
    return 0
}

service_running() {
    svc_pid >/dev/null 2>&1
}

# 杀掉 service.sh：优先 pid 文件，pgrep/pkill 只作兜底且用完整路径匹配。
kill_service() {
    _p=$(svc_pid 2>/dev/null)
    [ -n "$_p" ] && kill -TERM "$_p" 2>/dev/null
    pkill -f "$SVC" 2>/dev/null
    sleep 2
    _p=$(svc_pid 2>/dev/null)
    [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
    pkill -9 -f "$SVC" 2>/dev/null
    rm -f "$PID_FILE" 2>/dev/null
    return 0
}

# enable/on/set/cycle 之后，如果 service.sh 已经因为 disabled 退出，重新拉起它。
ensure_service() {
    if service_running; then return 0; fi
    nohup sh "$SVC" >/dev/null 2>&1 &
    sleep 2
    service_running && echo "已重新拉起 service.sh"
    return 0
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
        *success*) echo "$1" > "$PINNED"; rm -f "$DISABLED"; echo "已固定 duty=$1%" ;;
        *) echo "固定失败"; return 1 ;;
    esac
    # Kill service.sh so it does not re-evaluate and override the pin.
    kill_service
    return 0
}

cycle_step() {
    # Walk through tiers in order. Each invocation moves one step forward,
    # wrapping from VERYHOT back to QUIET.
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
                   rm -f "$DISABLED"
                   # 必须同时清掉 pinned：否则 set 之后再 cycle，status 会一直
                   # 显示"手动固定 (duty=50%)"，与刚切到的档位不符。
                   rm -f "$PINNED"
                   kill_service
                   return 0 ;;
        *) echo "切档失败"; return 1 ;;
    esac
}

tier_table() {
    echo "档位表 (来自 config.cfg):"
    printf "  < %-5sC  quiet   duty=%s%%\n" "$((T0 / 1000))" "$TIER_QUIET"
    printf "  %-5s-%-5sC  idle    duty=%s%%\n" "$((T0 / 1000))" "$((T1 / 1000))" "$TIER_IDLE"
    printf "  %-5s-%-5sC  warm    duty=%s%%\n" "$((T1 / 1000))" "$((T2 / 1000))" "$TIER_WARM"
    printf "  %-5s-%-5sC  hot     duty=%s%%\n" "$((T2 / 1000))" "$((T3 / 1000))" "$TIER_HOT"
    printf "  %-5s-%-5sC  vhot    duty=%s%%\n" "$((T3 / 1000))" "$((T4 / 1000))" "$TIER_VERYHOT"
    if [ "${OVERHEAT_HANDBACK:-0}" = "1" ]; then
        printf "  >= %sC       交回原厂策略 (OVERHEAT_HANDBACK=1)\n" "$((T4 / 1000))"
    else
        printf "  >= %sC       overheat duty=%s%% (原厂只有 35-40%%)\n" "$((T4 / 1000))" "${TIER_OVERHEAT:-88}"
    fi
    printf "  回滞 HYSTERESIS=%s mC (%sC) | RPM 升速闸门档位=%s | 过热重新接管档位=%s\n" \
        "$HYSTERESIS" "$(awk "BEGIN{printf \"%.1f\", $HYSTERESIS/1000}")" \
        "$RPM_RELEASE_RANK" "$OVERHEAT_RELEASE_RANK"
    printf "  RPM 闸门: rpm>=%s 时升到 duty=%s%% | 连续失败 %s 次后放弃并交还原厂\n" \
        "$RPM_CAP" "$RPM_DUTY" "$MAX_FAIL_STREAK"
    printf "  第二温度源=充电IC NTC，档位 %s/%s/%s/%s/%s mC 回滞 %s\n" \
        "${CHG0:-60000}" "${CHG1:-65000}" "${CHG2:-70000}" "${CHG3:-75000}" "${CHG4:-79000}" "${CHG_HYSTERESIS:-1500}"
    _wk=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
    printf "  熄屏压档: 上限档=%s (0=QUIET 1=IDLE 2=WARM … -1=关闭) | 当前 mWakefulness=%s\n" \
        "${SCREEN_OFF_MAX_RANK:--1}" "${_wk:-?}"
}

status() {
    echo "== 风扇温控状态 =="
    if [ -f "$GAVE_UP" ]; then
        echo "模式: 已放弃控制 (写入持续被拒，已交还原厂) — action.sh restart 可重试"
    elif is_disabled; then
        echo "模式: 已关闭 (持久，重启保持) — vendor 控制，action.sh enable 可恢复"
    elif is_pinned; then
        if in_test_mode; then
            echo "模式: 手动固定 (duty=$(cat "$PINNED")%)"
        else
            echo "模式: 手动固定记录存在，但 MCU test mode 未生效 (风扇归 vendor)"
        fi
    elif in_test_mode; then
        if [ -f "$ENABLED" ]; then
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
    svc=$(svc_pid 2>/dev/null || true)
    cur_tier=$(cat "$CUR_TIER" 2>/dev/null || echo "(none)")
    cur_duty=$(cat "$CUR_DUTY" 2>/dev/null || echo "(none)")

    if [ -n "$t" ]; then t_c="$((t / 1000))"; else t_c="?"; fi
    printf "皮肤温度 %s°C | 风扇 duty=%s%% rpm=%s\n" "$t_c" "${d:-?}" "${r:-?}"
    printf "vendor=%s | 当前档=%s (上次写入 duty=%s)\n" "${v:-?}" "$cur_tier" "$cur_duty"
    [ -n "$svc" ] && printf "service.sh PID=%s\n" "$svc"
    # 最后一次成功写入风扇的时间。模块"看起来在跑"但这个值一直不更新，
    # 就说明它其实没有控制权 —— 这是排查静默失灵最有用的一行。
    if [ -r "$LAST_OK" ]; then
        _lo=$(cat "$LAST_OK" 2>/dev/null)
        _now=$(date +%s 2>/dev/null)
        if [ -n "$_lo" ] && [ -n "$_now" ]; then
            printf "上次成功写风扇: %s 秒前\n" "$((_now - _lo))"
        fi
    else
        echo "上次成功写风扇: 从未（本轮还没成功写入过）"
    fi
    printf "标记: %s\n" "$(ls "$STATE_DIR" 2>/dev/null | tr '\n' ' ')"

    echo ""
    tier_table
}

restart_service() {
    kill_service
    rm -f "$GAVE_UP" 2>/dev/null
    nohup sh "$SVC" >/dev/null 2>&1 &
    sleep 3
    new=$(svc_pid 2>/dev/null)
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
        if is_pinned; then
            rm -f "$PINNED"
        fi
        if take_over; then
            : > "$ENABLED"
            rm -f "$DISABLED" "$GAVE_UP"
            echo "已开启本模块温控 (持久)"
            ensure_service
        else
            echo "开启失败 (setfantestmode 1 被拒绝)"
        fi
        status
        ;;
    disable)
        if hand_back; then
            rm -f "$ENABLED"
            : > "$DISABLED"
            echo "已恢复原厂温控 (持久，重启不会自动接管)"
            echo "正在运行的 service.sh 会在一个周期内自行交回并退出"
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
    selftest)
        sh "$SVC" --selftest
        ;;
    auto|off|on)
        # 'auto' means: follow whatever the flag says, which is what boot does.
        # 'on'  = take over, 'off' = hand back. Kept short for convenience.
        if [ "$CMD" = "on" ]; then
            take_over && : > "$ENABLED" && rm -f "$DISABLED" "$GAVE_UP" || exit 1
            echo "已开启本模块温控 (持久)"
            ensure_service
        elif [ "$CMD" = "off" ]; then
            hand_back && rm -f "$ENABLED" && : > "$DISABLED" || exit 1
            echo "已恢复原厂温控 (持久)"
            echo "正在运行的 service.sh 会在一个周期内自行交回并退出"
        fi
        status
        ;;
    *)
        echo "用法: action.sh [status|enable|disable|set <0-100>|cycle|restart|selftest|on|off|auto]"
        exit 1
        ;;
esac

exit 0
