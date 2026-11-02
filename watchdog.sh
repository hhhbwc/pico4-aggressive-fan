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

LOG_TAG="PicoFanTC"
MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="${PICO4_STATE_DIR:-$MODDIR/state}"

OWNED="$STATE_DIR/owned"
CTRL_MODE="$STATE_DIR/ctrl_mode"
PID_FILE="$STATE_DIR/service.pid"
DISABLED="$STATE_DIR/disabled"

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
    if [ -z "$_p" ] || ! kill -0 "$_p" 2>/dev/null; then
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
