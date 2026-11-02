#!/system/bin/sh
# Watchdog for the v2 control path.
#
# service.sh owns the fan by stopping pxrfanservice. If that process is killed
# with -9 its EXIT trap does not run, so nobody would bring the vendor service
# back and the fan would stay at the last duty forever. This loop watches
# state/service.pid and restores the vendor within ~5 seconds.
#
# It exits on its own once ownership is released (normal disable/uninstall),
# so it never lingers after the module hands the fan back.
#
# Manual hold (action.sh set / cycle) is a deliberate mode, not a crash: the
# daemon is killed on purpose so it cannot overwrite the pinned duty. In that
# mode the watchdog must NOT hand the fan back — instead it keeps the vendor
# stopped and re-asserts the pinned duty if anything overwrites it.

LOG_TAG="PicoFanTC"
MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="${PICO4_STATE_DIR:-$MODDIR/state}"

OWNED="$STATE_DIR/owned"
CTRL_MODE="$STATE_DIR/ctrl_mode"
PID_FILE="$STATE_DIR/service.pid"
DISABLED="$STATE_DIR/disabled"
PINNED="$STATE_DIR/pinned"
# hold = 守护被**故意**停掉时，风扇要守住的 duty。
# 与 pinned 分开：pinned 是 action.sh set 的"手动固定"标签，hold 同时覆盖
# action.sh cycle（切到某一档后同样会停掉守护）。
HOLD="$STATE_DIR/hold"
TOOL="/system/bin/gd32ipdclient_test"

log() {
    /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null || echo "$LOG_TAG: $*" >&2
}

vendor_running() {
    [ "$(getprop init.svc.pxrfanservice 2>/dev/null)" = "running" ]
}

start_vendor() {
    vendor_running && return 0
    setprop ctl.start pxrfanservice 2>/dev/null
    _n=0
    while [ "$_n" -lt 10 ]; do
        vendor_running && return 0
        sleep 1
        _n=$((_n + 1))
    done
    return 1
}

# 正常接口还是 test mode，由 state/ctrl_mode 决定（与 service.sh 同口径）。
duty_cmd() {
    case "$(cat "$CTRL_MODE" 2>/dev/null)" in
        test) echo setfantestspeed ;;
        *)    echo setfanspeed ;;
    esac
}

get_duty() {
    $TOOL getfaninfo 2>/dev/null \
        | sed -n 's/^duty=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# 手动固定模式：守住固定 duty。
#
# action.sh set / cycle 会**故意**杀掉 service.sh（否则守护会按温度把固定值
# 覆盖掉），并留下 state/hold 记录要守的 duty。这时守护"消失"是设计，
# 不是崩溃 —— 绝不能把控制权交回原厂，否则用户要的固定值当场失效。
#
# 这里做两件事：
#   1) 原厂服务如果又被系统拉起来，立刻停掉（否则原厂会改写 duty）；
#   2) 读一次实际 duty，和要守的值不一致就写回去（补上原厂抢走的那一帧）。
hold_pinned() {
    _want=$(cat "$HOLD" 2>/dev/null)
    case "$_want" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$_want" -le 100 ] 2>/dev/null || return 0

    if vendor_running; then
        log "watchdog: pxrfanservice came back (manual hold), stopping it"
        setprop ctl.stop pxrfanservice 2>/dev/null
        sleep 1
    fi

    _cur=$(get_duty)
    if [ -n "$_cur" ] && [ "$_cur" != "$_want" ]; then
        log "watchdog: held duty $_want lost (fan at $_cur), re-asserting"
        $TOOL "$(duty_cmd)" "$_want" >/dev/null 2>&1
    fi
}

while :; do
    sleep 5

    if [ ! -f "$OWNED" ]; then
        exit 0
    fi

    if [ -f "$DISABLED" ]; then
        log "watchdog: module disabled while owner active, restoring vendor"
        rm -f "$OWNED" "$CTRL_MODE"
        start_vendor
        exit 0
    fi

    _p=$(cat "$PID_FILE" 2>/dev/null)
    _daemon_alive=0
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
        _daemon_alive=1
    fi

    if [ "$_daemon_alive" = "0" ]; then
        # 守护没了。分两种情况：
        #
        # 1) 有 state/hold：这是**故意**的 —— action.sh set / cycle 会停掉
        #    守护，好让它不按温度覆盖用户要的固定值。这时不能把风扇交回原厂
        #    （那会让固定值当场失效），改为守住这个 duty。
        # 2) 没有 hold：守护是崩了（kill -9 之类），兜底把原厂拉回来。
        if [ -f "$HOLD" ]; then
            hold_pinned
            continue
        fi
        log "watchdog: service.sh is gone but fan is still owned, restoring vendor"
        rm -f "$OWNED" "$CTRL_MODE" "$STATE_DIR/in_test"
        start_vendor
        exit 0
    fi

    # 厂商服务被系统重新拉起时，先由 watchdog 停掉，缩短"原厂在写"的窗口；
    # service.sh 每轮也会检查并处理。
    if [ "$(cat "$CTRL_MODE" 2>/dev/null)" = "vendor" ] && vendor_running; then
        log "watchdog: pxrfanservice came back, stopping it"
        setprop ctl.stop pxrfanservice 2>/dev/null
    fi
done
