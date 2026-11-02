#!/system/bin/sh
# Run by Magisk when the module is disabled or uninstalled.
# Restore the vendor's own fan policy, whichever way the module was holding it:
#   owner=vendor -> pxrfanservice is stopped; just start it again.
#   owner=test   -> exit MCU test mode, then start pxrfanservice.
#
# The service loop and watchdog are killed first so neither can re-take the fan
# after we release it.

MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="$MODDIR/state"
PID_FILE="$STATE_DIR/service.pid"
WATCHDOG_PID="$STATE_DIR/watchdog.pid"
OWNED="$STATE_DIR/owned"
CTRL_MODE="$STATE_DIR/ctrl_mode"
TOOL="/system/bin/gd32ipdclient_test"
SVC="$MODDIR/service.sh"

kill_service_loop() {
    _p=""
    [ -r "$PID_FILE" ] && read -r _p < "$PID_FILE" 2>/dev/null
    if [ -n "$_p" ]; then
        kill -TERM "$_p" 2>/dev/null
        sleep 1
        kill -9 "$_p" 2>/dev/null
    fi
    # 兜底：pid 文件缺失/过期时用完整路径匹配（不能用裸 basename，会误伤别的进程）
    pkill -f "$SVC" 2>/dev/null
    sleep 1
    pkill -9 -f "$SVC" 2>/dev/null
}

kill_watchdog() {
    _w=""
    [ -r "$WATCHDOG_PID" ] && read -r _w < "$WATCHDOG_PID" 2>/dev/null
    [ -n "$_w" ] && kill -9 "$_w" 2>/dev/null
    pkill -f "$MODDIR/watchdog.sh" 2>/dev/null
}

start_vendor() {
    [ "$(getprop init.svc.pxrfanservice 2>/dev/null)" = "running" ] && return 0
    setprop ctl.start pxrfanservice 2>/dev/null
    setprop sys.pxrfanservice.state 1 2>/dev/null
    _n=0
    while [ "$_n" -lt 10 ]; do
        [ "$(getprop init.svc.pxrfanservice 2>/dev/null)" = "running" ] && return 0
        sleep 1
        _n=$((_n + 1))
    done
    return 1
}

kill_watchdog
kill_service_loop

_mode=$(cat "$CTRL_MODE" 2>/dev/null)
if [ "$_mode" = "test" ] || [ -f "$STATE_DIR/in_test" ]; then
    $TOOL setfantestmode 0 >/dev/null 2>&1
fi
rm -f "$OWNED" "$CTRL_MODE" "$STATE_DIR/in_test"

# Belt and braces: the vendor service must be up even if the flags were stale,
# so disabling/uninstalling can never leave the fan with nobody in control.
start_vendor

rm -rf "$STATE_DIR" 2>/dev/null

/system/bin/log -t "PicoFanTC" "module stopped, vendor fan policy restored" 2>/dev/null

exit 0
