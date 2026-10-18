#!/system/bin/sh
# Run by Magisk when the module is disabled or uninstalled.
# Restore the vendor's own fan policy so the device behaves stock again.
#
# Important: exiting MCU test mode alone is NOT enough to restore vendor
# control. The MCU keeps rejecting the vendor's duty frames until
# pxrfanservice re-initialises, which re-runs the handshake that clears the
# lock. So we always restart pxrfanservice here, regardless of the flag state.

MODDIR="/data/adb/modules/pico4_fan_tempcontrol"
STATE_DIR="$MODDIR/state"
PID_FILE="$STATE_DIR/service.pid"
TOOL="/system/bin/gd32ipdclient_test"
SVC="$MODDIR/service.sh"

# 关键：退出 MCU test mode **不够**。
# 还在跑的 service.sh 会在下一个周期发现 in_test 没了，立刻重新抢回 test mode
# 并继续写 duty —— 表现就是"模块卸了，风扇却停在某个转速下不来，只有重启才好"。
# 所以必须先把循环杀掉，再退 test mode。顺序不能反：先杀的话临死前可能又抢一次。
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

if [ -f "$STATE_DIR/in_test" ]; then
    $TOOL setfantestmode 0 >/dev/null 2>&1
    setprop sys.pxrfanservice.state 2 2>/dev/null
    sleep 1
fi

kill_service_loop

# Belt and braces: make sure the vendor service is up even if the flag is
# stale or missing, so an uninstall can never leave the fan with nobody in
# control of it.
if [ "$(getprop init.svc.pxrfanservice 2>/dev/null)" != "running" ]; then
    setprop sys.pxrfanservice.state 1 2>/dev/null
fi

rm -rf "$STATE_DIR" 2>/dev/null

/system/bin/log -t "PicoFanTC" "module stopped, vendor fan policy restored" 2>/dev/null

exit 0
