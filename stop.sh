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
PINNED="$STATE_DIR/pinned"
HOLD="$STATE_DIR/hold"
TOOL="/system/bin/gd32ipdclient_test"
SVC="$MODDIR/service.sh"

# 只杀 argv 里带着指定路径的进程（真在跑那个脚本的）。
# 不用 `pkill -f "$SVC"`：那是子串匹配，任何命令行里**提到**这个路径的进程
# 都会被杀掉 —— 包括用户自己那条 `adb shell`（实测会把自己的 shell 一起
# 打死，命令直接返回 143/137）。
kill_by_argv() {
    _target="$1"
    _sig="${2:-TERM}"
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        [ -r "$_d/cmdline" ] || continue
        if tr '\0' '\n' < "$_d/cmdline" 2>/dev/null | grep -Fxq "$_target"; then
            kill "-$_sig" "$_pid" 2>/dev/null
        fi
    done
}

kill_service_loop() {
    _p=""
    [ -r "$PID_FILE" ] && read -r _p < "$PID_FILE" 2>/dev/null
    if [ -n "$_p" ]; then
        kill -TERM "$_p" 2>/dev/null
        sleep 1
        kill -9 "$_p" 2>/dev/null
    fi
    # 兜底：pid 文件缺失/过期时按 argv 精确匹配（不能用裸 basename，
    # 也不能用 pkill -f 的子串匹配，都会误伤别的进程）。
    kill_by_argv "$SVC" TERM
    sleep 1
    kill_by_argv "$SVC" KILL
}

kill_watchdog() {
    _w=""
    [ -r "$WATCHDOG_PID" ] && read -r _w < "$WATCHDOG_PID" 2>/dev/null
    [ -n "$_w" ] && kill -9 "$_w" 2>/dev/null
    kill_by_argv "$MODDIR/watchdog.sh" KILL
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
rm -f "$OWNED" "$CTRL_MODE" "$STATE_DIR/in_test" "$PINNED" "$HOLD"

# Belt and braces: the vendor service must be up even if the flags were stale,
# so disabling/uninstalling can never leave the fan with nobody in control.
start_vendor

rm -rf "$STATE_DIR" 2>/dev/null

/system/bin/log -t "PicoFanTC" "module stopped, vendor fan policy restored" 2>/dev/null

exit 0
