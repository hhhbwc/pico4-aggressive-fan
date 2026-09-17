#!/system/bin/sh
# PICO 4 Fan Auto Temp Control — v1.3.0
#
# 本版本修掉一批会让模块静默失灵的缺陷，设计意图（皮肤温度分档 + 绕过原厂锁）
# 与档位机制保持不变。逐条说明见下面的注释和 CHANGELOG.md。
#
# v1.3.0 修掉的缺陷
# ---------------------------------------------------------------------------
# [1] enter_test_mode() 原来只看 state/in_test 标记文件，从不校验 MCU 真实的
#     test mode 固件状态。MCU 侧锁一旦丢失（厂商重握手 / 异常），标记文件仍在，
#     脚本就永远不再下发 setfantestmode 1 -> 之后每一次 setfantestspeed 都被
#     MCU 拒绝，模块变成"僵尸"：仍在运行、仍觉得自己在控风扇，实际上完全没有
#     控制权，而且每 5 秒往 logcat 写一条失败日志把环形缓冲刷满，
#     连启动阶段的关键日志都被挤掉。
#     现在：任何一次写入失败都视为"锁已丢"，清掉标记 -> 重进 test mode ->
#     立刻重试一次；失败日志按次数节流。
#
# [2] RPM_CAP 自锁。原来只要 rpm >= RPM_CAP 就把 duty 固定成 RPM_DUTY，
#     此时温度档位被完全旁路；而在这个 duty 下 rpm 恒 >= RPM_CAP，
#     条件永远成立 -> 转速再也降不下来（想降 rpm 必须先降 duty，
#     而降 duty 又要求 rpm 已经低于阈值，逻辑死锁）。
#     现在：升速需要温度档位 >= RPM_RELEASE_RANK 作为闸门，温度一回落即自动释放。
#
# [3] HYSTERESIS 名不副实。原来只有 QUIET 分支用到了 prev，
#     WARM/HOT/VERYHOT 的回落是不带回滞的纯阈值比较，回滞参数实际上不起作用。
#     现在：统一的档位阶梯 + 真实回滞，降档必须低于 (该档阈值 - HYSTERESIS)。
#
# [4] 过热交回原厂后，下一个循环就因为 IN_TEST 缺失而立刻抢回 test mode，
#     "把高温柔性保护交还原厂"实际只维持了 5 秒。
#     现在：交回后要等温度落回 OVERHEAT_RELEASE_RANK 档才重新接管。
#
# [5] action.sh disable 不持久：enabled 与 in_test 都被删掉，重启后逻辑走到
#     自动接管分支，模块又起来了（表现为"关了它，重启自己又开"）。
#     现在：显式关闭写 state/disabled 标记，重启后依然保持关闭，直到 enable。
#
# [6] 行尾符（CRLF）会直接废掉整个模块。Android 的 sh 不把 CR 当空白字符：
#       tier=$(pick_tier) 会变成 tier="IDLE\r"，case 匹配不上，控制逻辑静默失效。
#       实测 CRLF 版 service.sh 在设备上每行赋值都报 "inaccessible or not found"。
#       现在：config.cfg 加载前先 tr -d '\r'（兼容记事本存出来的 CRLF）；
#       仓库用 .gitattributes 强制 LF；customize.sh 在安装时再做一次归一化。
#
# 其它：binder 工具调用统一套 timeout，避免对端卡死把整个循环挂住（原版没有
# 看门狗，卡住后风扇会停在最后一次写入的转速）；state/last_run.log 死变量清掉。
#
# 用法补充
# ---------------------------------------------------------------------------
#   sh service.sh --selftest    纯逻辑自检（只读，不写风扇、不碰真实节点）
#
# 原有机制与参数含义保持不变，详见 config.cfg 与 README.md。

LOG_TAG="PicoFanTC"

# Resolve the module dir from our own path so the script also works when
# tested from a scratch location instead of the installed module path.
MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/pico4_fan_tempcontrol"

# 测试钩子：允许自检时把状态目录 / 温度节点指到临时位置，不触碰真实设备节点。
STATE_DIR="${PICO4_STATE_DIR:-$MODDIR/state}"
TEMP_NODE="${PICO4_TEMP_NODE:-/sys/class/thermal/thermal_zone86/temp}"

CONFIG_FILE="$MODDIR/config.cfg"
ENABLED="$STATE_DIR/enabled"
DISABLED="$STATE_DIR/disabled"
CUR_DUTY="$STATE_DIR/cur_duty"
CUR_TIER="$STATE_DIR/cur_tier"
IN_TEST="$STATE_DIR/in_test"

TOOL="/system/bin/gd32ipdclient_test"

mkdir -p "$STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# Defaults. Override from $CONFIG_FILE if present.
# ---------------------------------------------------------------------------

# Tier table, lowest first. Each is a duty percent 0-100.
TIER_QUIET="0"        # skin < T0, ambient is cold; no fan needed
TIER_IDLE="25"        # T0-T1
TIER_WARM="55"        # T1-T2
TIER_HOT="65"         # T2-T3
TIER_VERYHOT="78"     # T3-T4

# Thresholds, in millidegrees C.
# T0 默认从 38000 提到 41000：PICO 4 息屏静置的皮温实测就在 37.5-38.0C 之间飘，
# 原来的 T0=38C 正好压在待机皮温上，配合"第一档直接 45%(约 7700RPM)"，
# 会造成 0 <-> 7700 RPM 无限横跳。
T0=41000   # quiet -> idle
T1=47000   # idle -> warm
T2=50000   # warm -> hot
T3=53000   # hot -> very hot
T4=56000   # very hot -> overheat (hand back to vendor)

# Hysteresis in millidegrees C. 降档需要低于 (该档阈值 - HYSTERESIS)。
# 0.8C 起步；配合 T0=41C，待机时不会再反复起跳。
HYSTERESIS=800

LOOP_INTERVAL=5          # seconds
STARTUP_GRACE=45         # seconds after boot before taking over

# RPM 升速闸门。只有温度档位不低于该档时，才允许因为 rpm 偏高而升速。
# 3 = HOT。实测 rpm 冲到 13600 时皮肤才 53C，闸门设在 HOT(>=50C) 可以
# 保证"热的时候给余量、温度一回落立刻松开"，不会长时间白吃 88% 的噪音。
RPM_CAP=12000
RPM_DUTY=88
RPM_RELEASE_RANK=3

# 过热交回原厂后，温度降回该档才重新接管。3 = HOT。
OVERHEAT_RELEASE_RANK=3

# 写风扇失败后的重试间隔（秒）。
RETRY_BACKOFF=3

# 失败日志节流：每 N 次失败记一条（第 1 次总是记）。防止刷爆 logcat。
FAIL_LOG_EVERY=12

# ---------------------------------------------------------------------------
# Load config.cfg if present. Each line is KEY=VALUE, '#' starts a comment.
# ---------------------------------------------------------------------------

if [ -r "$CONFIG_FILE" ]; then
    # 防御 CRLF：README 让用户用记事本编辑 config.cfg，而 Windows 记事本默认存 CRLF。
    # 那样 TIER_IDLE=25 会被赋值成 "25<CR>"，回车会跟着进 state/cur_duty、日志和
    # action.sh 的表格里，值比较也不再严格相等，排查起来很费劲。
    # 先去掉 CR 再 source；没有 tr 就退回原来的直接 source。
    CFG_NORM="$STATE_DIR/config.norm"
    if command -v tr >/dev/null 2>&1 \
       && tr -d '\r' < "$CONFIG_FILE" > "$CFG_NORM" 2>/dev/null; then
        . "$CFG_NORM" 2>/dev/null
        rm -f "$CFG_NORM" 2>/dev/null
    else
        . "$CONFIG_FILE" 2>/dev/null
    fi
fi

log() {
    # 用绝对路径：函数名叫 log 会遮蔽同名二进制，裸写 log 会无限递归刷爆 logd。
    /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null || echo "$LOG_TAG: $*"
}

# ---------------------------------------------------------------------------
# Fan access.
# gd32ipdclient_test 是 binder 调用，且**失败时仍然返回 exit code 0**
# （只会打印 "setrfantestspeed N failed" + "=== operation failed! ==="），
# 所以只能靠匹配输出里的 success 判断，不能用退出码。同时套一层 timeout，
# 万一对端卡住不至于把整个控制循环挂死。
# ---------------------------------------------------------------------------

if [ -x /system/bin/timeout ]; then
    run_tool() { /system/bin/timeout 5 "$TOOL" "$@" 2>/dev/null; }
else
    run_tool() { "$TOOL" "$@" 2>/dev/null; }
fi

set_duty() {
    # $1 = duty percent 0-100
    [ "$1" -ge 0 ] 2>/dev/null || return 1
    [ "$1" -le 100 ] 2>/dev/null || return 1
    out="$(run_tool setfantestspeed "$1")"
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
        out="$(run_tool getfaninfo)"
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

get_rpm() {
    out="$(run_tool getfaninfo)"
    echo "$out" | sed -n 's/^rpm=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# ---------------------------------------------------------------------------
# Test mode (the MCU-side lock)
# ---------------------------------------------------------------------------

enter_test_mode() {
    # 修 [1]：原来这里只要 $IN_TEST 存在就直接 return 0，从不问 MCU。
    # 标记文件不可信 —— 每次都实际下发一次，幂等且廉价。
    out="$(run_tool setfantestmode 1)"
    case "$out" in
        *success*) : > "$IN_TEST"; return 0 ;;
        *)         return 1 ;;
    esac
}

# Exit test mode AND force the vendor to re-handshake with the MCU, because the
# lock does not clear on exit alone. Restarting pxrfanservice makes the MCU
# accept vendor duty frames again.
exit_test_mode() {
    rm -f "$IN_TEST"
    run_tool setfantestmode 0 >/dev/null 2>&1
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
# Tier ladder.
#   rank: 0 QUIET  1 IDLE  2 WARM  3 HOT  4 VERYHOT  5 OVERHEAT
# ---------------------------------------------------------------------------

tier_rank() {
    case "$1" in
        QUIET)    echo 0 ;;
        IDLE)     echo 1 ;;
        WARM)     echo 2 ;;
        HOT)      echo 3 ;;
        VERYHOT)  echo 4 ;;
        OVERHEAT) echo 5 ;;
        RPM-CAP)  echo 2 ;;   # 兼容上游写下的旧状态文件
        *)        echo -1 ;;
    esac
}

pick_tier() {
    t=$(cat "$TEMP_NODE" 2>/dev/null)
    case "$t" in
        ''|*[!0-9]*) return 1 ;;
    esac

    prev=$(cat "$CUR_TIER" 2>/dev/null)
    case "$prev" in
        QUIET|IDLE|WARM|HOT|VERYHOT) ;;
        *) prev=IDLE ;;   # unknown / first run: behave like IDLE
    esac
    prev_rank=$(tier_rank "$prev")

    # 升档：纯阈值，跨过就上（快速响应升温，安全优先）。
    rank=0
    [ "$t" -ge "$T0" ] && rank=1
    [ "$t" -ge "$T1" ] && rank=2
    [ "$t" -ge "$T2" ] && rank=3
    [ "$t" -ge "$T3" ] && rank=4
    [ "$t" -ge "$T4" ] && rank=5

    if [ "$rank" -ge "$prev_rank" ]; then
        new_rank=$rank
    else
        # 降档：修 [3]，逐档检查真实回滞。
        # 要降到 rank-1，必须低于「rank-1 对应阈值 - HYSTERESIS」。
        new_rank=$prev_rank
        while [ "$new_rank" -gt "$rank" ]; do
            case "$new_rank" in
                5) thr=$T4 ;;
                4) thr=$T3 ;;
                3) thr=$T2 ;;
                2) thr=$T1 ;;
                1) thr=$T0 ;;
                *) break ;;
            esac
            if [ "$t" -lt "$((thr - HYSTERESIS))" ]; then
                new_rank=$((new_rank - 1))
            else
                break
            fi
        done
    fi

    case "$new_rank" in
        0) echo QUIET ;;
        1) echo IDLE ;;
        2) echo WARM ;;
        3) echo HOT ;;
        4) echo VERYHOT ;;
        *) echo OVERHEAT ;;
    esac
}

# Resolve a tier label to its duty percent.
tier_duty() {
    case "$1" in
        QUIET)    echo "$TIER_QUIET" ;;
        IDLE)     echo "$TIER_IDLE" ;;
        WARM)     echo "$TIER_WARM" ;;
        HOT)      echo "$TIER_HOT" ;;
        VERYHOT)  echo "$TIER_VERYHOT" ;;
        OVERHEAT) echo "" ;;   # not a duty; caller handles handback
        *) return 1 ;;
    esac
}

# decide <tier> <rpm>  ->  prints "<name> <duty>"
# 修 [2]：rpm 升速必须同时满足温度闸门，否则一旦冲上 12000 就再也降不下来。
decide() {
    _tier="$1"
    _rpm="$2"
    _d=$(tier_duty "$_tier")
    [ -z "$_d" ] && return 1
    _r=$(tier_rank "$_tier")
    if [ -n "$_rpm" ] && [ "$RPM_CAP" -gt 0 ] 2>/dev/null \
       && [ "$_rpm" -ge "$RPM_CAP" ] 2>/dev/null \
       && [ "$_r" -ge "$RPM_RELEASE_RANK" ]; then
        echo "RPM-CAP $RPM_DUTY"
    else
        echo "$_tier $_d"
    fi
    return 0
}

# 修 [4]：过热交回原厂后，是否允许重新接管。
# 只有温度已经降回 OVERHEAT_RELEASE_RANK 档（默认 HOT，<53C）才拿回控制权，
# 上游版本是交回 5 秒就抢回来，高温柔性保护形同虚设。
should_reengage() {
    [ "$(tier_rank "$1")" -le "$OVERHEAT_RELEASE_RANK" ]
}

# ---------------------------------------------------------------------------
# Enable / disable
# ---------------------------------------------------------------------------

enable() {
    if ! enter_test_mode; then
        return 1
    fi
    rm -f "$DISABLED"
    : > "$ENABLED"
    log "MCU test mode engaged, vendor duty writes now rejected"
    return 0
}

disable() {
    : > "$DISABLED"     # 修 [5]：持久化"用户关闭"，重启后不自动接管
    rm -f "$ENABLED"
    exit_test_mode
    log "MCU test mode exited, vendor fan policy restored (persistent)"
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

    # 修 [5]：用户显式关过 -> 不接管，等 action.sh enable 撤销。
    if [ -f "$DISABLED" ]; then
        log "disabled by user, standing by (action.sh enable to re-enable)"
        while [ -f "$DISABLED" ]; do
            sleep 10
        done
        log "disabled flag cleared, starting"
    fi

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

    cur_duty_written=""
    n=0
    fail_streak=0

    while : ; do
        n=$((n + 1))

        # 运行期间被用户关闭：交回原厂并退出。
        # 上游的 action.sh disable 只删标记，管不住已经在跑的循环 ——
        # 循环下一个周期就会因为 in_test 缺失而重新抢回 test mode。
        if [ -f "$DISABLED" ]; then
            log "user disabled the module while running, handing back to vendor"
            disable
            return 0
        fi

        tier=$(pick_tier)
        if [ -z "$tier" ]; then
            # Sensor read failed; keep last duty, do not guess.
            sleep "$LOOP_INTERVAL"
            continue
        fi
        t=$(cat "$TEMP_NODE" 2>/dev/null)

        # Overheat: hand the fan back to the vendor so its high-temp protection
        # runs. 修 [4]：这次要真的交回一段时间，见下面重新接管的闸门。
        if [ "$tier" = "OVERHEAT" ]; then
            if [ -f "$IN_TEST" ]; then
                exit_test_mode
                cur_duty_written=""
                log "skin $((t / 1000))C over heat, MCU test mode exited, vendor policy restored"
            fi
            sleep "$LOOP_INTERVAL"
            continue
        fi

        # 掉出 test mode 时重新接管。修 [4]：过热交回后必须等温度降回
        # OVERHEAT_RELEASE_RANK 档，避免刚交回 5 秒就抢回来。
        if [ ! -f "$IN_TEST" ]; then
            if should_reengage "$tier"; then
                if enter_test_mode; then
                    log "re-engaged MCU test mode at skin $((t / 1000))C"
                    cur_duty_written=""
                fi
            else
                sleep "$LOOP_INTERVAL"
                continue
            fi
        fi

        rpm_now=$(get_rpm)
        pos=$(decide "$tier" "$rpm_now")
        if [ -z "$pos" ]; then
            sleep "$LOOP_INTERVAL"
            continue
        fi
        cur_tier_name=${pos%% *}
        desired=${pos##* }

        # Only touch the fan when the desired duty actually changes.
        if [ "$desired" != "$cur_duty_written" ]; then
            if set_duty "$desired"; then
                fail_streak=0
                got=$(get_duty 4)
                cur_duty_written="$desired"
                echo "$desired" > "$CUR_DUTY"
                echo "$cur_tier_name" > "$CUR_TIER"
                log "skin $((t / 1000))C rpm ${rpm_now:-?} -> $cur_tier_name duty $desired (reported ${got:-?})"
            else
                # 修 [1] 的核心：写入被拒 == MCU 那边锁已经没了，标记文件不可信。
                fail_streak=$((fail_streak + 1))
                if [ $((fail_streak % FAIL_LOG_EVERY)) -eq 1 ]; then
                    log "setfantestspeed $desired rejected (streak $fail_streak), re-arming MCU test mode"
                fi
                rm -f "$IN_TEST"
                if enter_test_mode; then
                    if set_duty "$desired"; then
                        fail_streak=0
                        got=$(get_duty 4)
                        cur_duty_written="$desired"
                        echo "$desired" > "$CUR_DUTY"
                        echo "$cur_tier_name" > "$CUR_TIER"
                        log "re-armed ok: skin $((t / 1000))C -> $cur_tier_name duty $desired (reported ${got:-?})"
                    fi
                fi
                sleep "$RETRY_BACKOFF"
            fi
        fi

        # 每 ~6 个循环（约 30s）校验一次持有值。漂移了就静默重写。
        if [ $((n % 6)) -eq 0 ] && [ -n "$cur_duty_written" ]; then
            held=$(get_duty 4)
            if [ -n "$held" ] && [ "$held" != "$cur_duty_written" ]; then
                log "drift detected: wanted $cur_duty_written, MCU reports $held, re-asserting"
                set_duty "$cur_duty_written" >/dev/null 2>&1
            fi
        fi

        sleep "$LOOP_INTERVAL"
    done
}

# ---------------------------------------------------------------------------
# Self test — 纯逻辑校验，只读，不写风扇、不碰真实状态目录与温度节点。
# ---------------------------------------------------------------------------

selftest() {
    TMP="/data/local/tmp/pico4fan_selftest.$$"
    rm -rf "$TMP" 2>/dev/null
    mkdir -p "$TMP" 2>/dev/null || return 1

    ST="$TMP/temp"
    CT="$TMP/cur_tier"
    TEMP_NODE="$ST"
    CUR_TIER="$CT"

    echo "== [3] 阶梯 + 真实回滞 (T0=$T0 T1=$T1 T2=$T2 T3=$T3 T4=$T4 H=$HYSTERESIS) =="
    echo "prev=IDLE，按温度升序："
    for x in 36000 40990 41000 46990 47000 49990 50000 52990 53000 55990 56000; do
        echo "IDLE" > "$CT"
        printf '%s' "$x" > "$ST"
        printf "  t=%s (%.1fC) -> %s\n" "$x" "$(awk "BEGIN{printf \"%.1f\", $x/1000}")" "$(pick_tier)"
    done

    echo "prev=VERYHOT，检查降档回滞（应停在 52200=53000-$HYSTERESIS 附近）："
    for x in 52990 52250 52199 50000 49999 49200 49199; do
        echo "VERYHOT" > "$CT"
        printf '%s' "$x" > "$ST"
        printf "  t=%s (%.1fC) -> %s\n" "$x" "$(awk "BEGIN{printf \"%.1f\", $x/1000}")" "$(pick_tier)"
    done

    echo ""
    echo "== [2] RPM 升速闸门（RPM_CAP=$RPM_CAP RPM_DUTY=$RPM_DUTY 闸门档位=$RPM_RELEASE_RANK）=="
    echo "  decide IDLE    12500 -> $(decide IDLE 12500)     <- 低温柔闸门挡住，转速可回落"
    echo "  decide IDLE     7000 -> $(decide IDLE 7000)"
    echo "  decide WARM    12500 -> $(decide WARM 12500)"
    echo "  decide HOT     12500 -> $(decide HOT 12500)"
    echo "  decide VERYHOT 12500 -> $(decide VERYHOT 12500)"
    echo "  decide IDLE         -> $(decide IDLE '')"
    echo "  对比：上游无闸门时 IDLE/12500 会得到 RPM-CAP $RPM_DUTY 并永久自锁"
    echo "  实测：duty 88% -> 13671 RPM；duty 78% -> 12220 RPM（故上游确实会锁死）"

    echo ""
    echo "== [4] 过热交回后的重新接管闸门（OVERHEAT_RELEASE_RANK=$OVERHEAT_RELEASE_RANK）=="
    for x in IDLE WARM HOT VERYHOT; do
        if should_reengage "$x"; then r=接管; else r=继续交回原厂; fi
        printf "  tier=%-8s -> %s\n" "$x" "$r"
    done

    echo ""
    echo "== [1] 工具失败时的行为约定 =="
    echo "  gd32ipdclient_test 失败仍返回 rc=0，只能匹配 success 字符串 —— 已按此实现"

    rm -rf "$TMP" 2>/dev/null
    return 0
}

case "${1:-}" in
    --selftest|-t)
        selftest
        exit 0
        ;;
esac

main "$@"
