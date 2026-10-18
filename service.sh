#!/system/bin/sh
# PICO 4 Fan Auto Temp Control — v1.5.0
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
# [7] config.cfg 盲目 source 导致变量覆盖 + 任意代码执行（root RCE）。
#     /system/bin/sh 下直接 source 用户可编辑文件，非白名单键（TOOL / STATE_DIR /
#     MODDIR / TEMP_NODE / LOG_TAG）能被覆盖，例如 TOOL=/system/bin/false 让模块
#     永久失效；值里的 $(...) / 反引号在 source 时执行，等于 root 下任意命令执行。
#     现在改为白名单逐行解析：先去 CR，只接受 19 个已知数值键，拒绝一切非白名单
#     键与含命令替换（$( )、`、`;`、`&`）的值。实机注入测试：TOOL 覆盖被忽略、
#     PWNED=$(touch ...) 与 TIER_QUIET=$(touch ...) 都未触发。
#
# [8] 看门狗在实机上对脚本型 MCU 工具失效。v1.4.0 用 `$(timeout 5 "$TOOL" ...)`，
#     实机测出 toybox timeout 杀"内含 sleep 60 的脚本"要等满 60s（信号传不到二次
#     exec 的子进程），看门狗退化、风扇冻结在最后转速。同时 `$( )` 管道捕获会因
#     孤儿子进程持有写端而永久阻塞。现在不再用 timeout 二进制：后台跑+轮询 kill -0
#     + 超时 kill -9 整个进程组，输出重定向到临时文件事后 cat。实测脚本型工具卡死
#     被稳定掐在 5s。
#
# 其它：state/last_run.log 死变量清掉。
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
LAST_OK="$STATE_DIR/last_ok"
GAVE_UP="$STATE_DIR/gave_up"
PID_FILE="$STATE_DIR/service.pid"

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

# 连续写入失败达到该次数后，放弃控制、退出 test mode 交还原厂。
# 没有这个上限时，工具一旦持续拒绝（固件变更 / 权限丢失 / MCU 异常），
# 模块会无限重试、state 里却始终显示"正在控温"，风扇实际没人管。
MAX_FAIL_STREAK=10

# ---------------------------------------------------------------------------
# Load config.cfg if present. Each line is KEY=VALUE, '#' starts a comment.
# ---------------------------------------------------------------------------

# 仅从白名单读取 config.cfg。config.cfg 是用户可编辑文件，直接 source 会带来
# 两个致命问题：(1) 任意键都能覆盖脚本内部关键变量（TOOL / STATE_DIR / MODDIR /
# TEMP_NODE / LOG_TAG），例如写入 TOOL=/system/bin/false 让模块永久失效；
# (2) 值里的 $(...) 或反引号会在 source 时被执行（root 下即任意代码执行）。
# 所以这里逐行解析：先去 CR，只接受已知数值键，拒绝一切非白名单键与含命令
# 替换的值。实测注入 TOOL=/system/bin/false 或 PWNED=$(touch ...) 都被忽略。
CONFIG_KEYS="TIER_QUIET TIER_IDLE TIER_WARM TIER_HOT TIER_VERYHOT T0 T1 T2 T3 T4 HYSTERESIS LOOP_INTERVAL STARTUP_GRACE RETRY_BACKOFF FAIL_LOG_EVERY MAX_FAIL_STREAK RPM_CAP RPM_DUTY RPM_RELEASE_RANK OVERHEAT_RELEASE_RANK"

if [ -r "$CONFIG_FILE" ]; then
    CFG_NORM="$STATE_DIR/config.norm"
    if command -v tr >/dev/null 2>&1 \
       && tr -d '\r' < "$CONFIG_FILE" > "$CFG_NORM" 2>/dev/null; then
        _src="$CFG_NORM"
    else
        _src="$CONFIG_FILE"
    fi
    while IFS='=' read -r _k _v; do
        case "$_k" in ''|\#*) continue ;; esac
        [ -n "$_v" ] || continue
        # 拒绝含命令替换/语句分隔的 VALUE（防 PWNED=$(reboot) 之类注入）
        case "$_v" in *=*|*'$'*|*'\`'*|*';'*|*'&'*) continue ;; esac
        _ok=0
        for _w in $CONFIG_KEYS; do
            [ "$_k" = "$_w" ] && _ok=1 && break
        done
        [ "$_ok" = 1 ] || continue
        eval "$_k=\$_v"
    done < "$_src"
    rm -f "$CFG_NORM" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 配置校验
# config.cfg 是被 source 进来的，任何值都直接生效。实测下来一个非法值就够
# 让模块静默失灵：
#   LOOP_INTERVAL=abc / 空   -> sleep 立即返回，主循环变成零延迟忙循环
#   TIER_HOT=150 / abc       -> set_duty 一律拒绝，落入永久重试
#   T0=50000 且 T1=47000     -> 档位阶梯跳档，2C 内 0% 直接跳到 55%
#   FAIL_LOG_EVERY=0         -> 取模除零，失败日志彻底不打印
# 这里统一夹紧到安全区间，非法值回落默认并记一条日志。
# ---------------------------------------------------------------------------

is_num() {
    _v="${1:-}"
    [ -n "$_v" ] || return 1
    case "$_v" in -*) _v="${_v#-}" ;; esac
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# clamp_int <变量名> <值> <下限> <上限> <默认值>
clamp_int() {
    _cv="${2:-}"
    if ! is_num "$_cv"; then
        _cv="$5"
        log "config: $1='${2:-}' 非法，回落到 $_cv"
    fi
    if [ "$_cv" -lt "$3" ] 2>/dev/null; then
        _cv="$3"; log "config: $1 夹紧到下限 $3"
    fi
    if [ "$_cv" -gt "$4" ] 2>/dev/null; then
        _cv="$4"; log "config: $1 夹紧到上限 $4"
    fi
    eval "$1=\$_cv"
}

sanitize_config() {
    clamp_int TIER_QUIET   "$TIER_QUIET"   0 100 0
    clamp_int TIER_IDLE    "$TIER_IDLE"    0 100 25
    clamp_int TIER_WARM    "$TIER_WARM"    0 100 55
    clamp_int TIER_HOT     "$TIER_HOT"     0 100 65
    clamp_int TIER_VERYHOT "$TIER_VERYHOT" 0 100 78

    clamp_int T0 "$T0" 0 200000 41000
    clamp_int T1 "$T1" 0 200000 47000
    clamp_int T2 "$T2" 0 200000 50000
    clamp_int T3 "$T3" 0 200000 53000
    clamp_int T4 "$T4" 0 200000 56000

    # 阈值必须严格递增，否则档位阶梯会跳档甚至倒挂。
    if [ "$T0" -ge "$T1" ] || [ "$T1" -ge "$T2" ] \
       || [ "$T2" -ge "$T3" ] || [ "$T3" -ge "$T4" ]; then
        log "config: 阈值非单调 (T0..T4=$T0,$T1,$T2,$T3,$T4)，回落 41/47/50/53/56 C"
        T0=41000; T1=47000; T2=50000; T3=53000; T4=56000
    fi

    # 回滞不能吃掉相邻档位的间隔，否则永远降不下来（风扇停不下来）。
    _gap=$((T1 - T0)); _g=$((T2 - T1)); [ "$_g" -lt "$_gap" ] && _gap=$_g
    _g=$((T3 - T2)); [ "$_g" -lt "$_gap" ] && _gap=$_g
    _g=$((T4 - T3)); [ "$_g" -lt "$_gap" ] && _gap=$_g
    _gap=$((_gap - 1)); [ "$_gap" -ge 0 ] || _gap=0
    clamp_int HYSTERESIS "$HYSTERESIS" 0 "$_gap" 800

    # LOOP_INTERVAL / RETRY_BACKOFF 下限为 1：0 或非法值会让 sleep 立即返回，
    # 主循环退化成忙循环，binder 调用风暴 + 打满 CPU。
    clamp_int LOOP_INTERVAL  "$LOOP_INTERVAL"  1 3600 5
    clamp_int STARTUP_GRACE  "$STARTUP_GRACE"  0 3600 45
    clamp_int RETRY_BACKOFF  "$RETRY_BACKOFF"  1 3600 3
    # FAIL_LOG_EVERY 下限为 1：0 会导致取模除零，失败日志彻底消失。
    clamp_int FAIL_LOG_EVERY "$FAIL_LOG_EVERY" 1 3600 12
    clamp_int MAX_FAIL_STREAK "$MAX_FAIL_STREAK" 1 1000 10

    clamp_int RPM_CAP  "$RPM_CAP"  0 100000 12000
    clamp_int RPM_DUTY "$RPM_DUTY" 0 100     88
    clamp_int RPM_RELEASE_RANK     "$RPM_RELEASE_RANK"     0 5 3
    clamp_int OVERHEAT_RELEASE_RANK "$OVERHEAT_RELEASE_RANK" 0 5 3
}

log() {
    # 用绝对路径：函数名叫 log 会遮蔽同名二进制，裸写 log 会无限递归刷爆 logd。
    /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null || echo "$LOG_TAG: $*"
}

# 配置加载完立刻校验一次，之后所有逻辑拿到的都是合法值。
sanitize_config

# ---------------------------------------------------------------------------
# Fan access.
# gd32ipdclient_test 是 binder 调用，且**失败时仍然返回 exit code 0**
# （只会打印 "setrfantestspeed N failed" + "=== operation failed! ==="），
# 所以只能靠匹配输出里的 success 判断，不能用退出码。同时套一层 timeout，
# 万一对端卡住不至于把整个控制循环挂死。
# ---------------------------------------------------------------------------

TOOL_TIMEOUT=5

# 调用 MCU 工具并带看门狗。这是整个控制循环最不能出错的环节：
#   1) 绝不通过 $(...) 管道捕获工具输出。若工具内部又 spawn 了子进程（脚本、
#      脚本型 wrapper、binder 客户端都常见），被强杀后那个孙子进程会成孤儿
#      并继续持有管道写端，导致 $() 一直阻塞到孙子自然结束 —— 看门狗彻底
#      失效。实测 toybox timeout 杀"脚本内含 sleep 60"要等满 60s 而非 5s。
#      输出一律重定向到临时文件，事后 cat，从根上避开管道。
#   2) 不依赖 /system/bin/timeout 二进制：真机上 toybox timeout 杀"经 shebang
#      二次 exec 的脚本"时信号传不到，5s 看门狗退化为等满 60s。所以这里自己
#      实现：后台跑 + 轮询 kill -0 + 超时 kill -9 整个进程组，工具若是脚本，
#      其子进程（sleep / 子 shell）一并被清，不留孤儿。
run_tool() {
    _of=$(mktemp "$STATE_DIR/.tool.XXXXXX" 2>/dev/null) || _of="$STATE_DIR/.tool.$$"
    "$TOOL" "$@" > "$_of" 2>/dev/null &
    _tp=$!
    _tw=0
    while [ "$_tw" -lt "$TOOL_TIMEOUT" ]; do
        kill -0 "$_tp" 2>/dev/null || break
        sleep 1
        _tw=$((_tw + 1))
    done
    if [ -n "$_tp" ] && kill -0 "$_tp" 2>/dev/null; then
        # 杀整个进程组：工具若是脚本，其子进程一并清除
        /system/bin/kill -9 "-$_tp" 2>/dev/null || kill -9 "$_tp" 2>/dev/null
        # 不走 log()：run_tool 输出被 $( ) 捕获，写 stdout 会混进 success 匹配。
        /system/bin/log -t "$LOG_TAG" "WARN: $TOOL $* 超时 ${TOOL_TIMEOUT}s，已强杀" \
            2>/dev/null || echo "$LOG_TAG: WARN: $* timeout" >&2
    fi
    wait "$_tp" 2>/dev/null
    cat "$_of" 2>/dev/null
    rm -f "$_of" 2>/dev/null
}

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
    # $1 = max attempts (NOT seconds — 每次尝试可能被 TOOL_TIMEOUT 拖到 5s)
    wait_s="${1:-3}"
    # 注意：这里必须用独立变量名。原来用 n，而 main() 的循环计数器也叫 n，
    # dash 里没有作用域隔离，get_duty 一返回就把 main 的 n 清零了 ——
    # 结果 "每 6 个循环校验一次持有值" 的漂移校验几乎永远不会触发。
    _dn=0
    while [ "$_dn" -lt "$wait_s" ]; do
        out="$(run_tool getfaninfo)"
        d=$(echo "$out" | sed -n 's/^duty=\([0-9][0-9]*\).*/\1/p' | head -n 1)
        if [ -n "$d" ] && [ "$d" -le 100 ] 2>/dev/null; then
            echo "$d"
            return 0
        fi
        _dn=$((_dn + 1))
        # 最后一次不必再等
        [ "$_dn" -lt "$wait_s" ] && sleep 1
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
    # 同样不能用 n（会覆盖 main 的循环计数器），见 get_duty 里的说明。
    _en=0
    while [ "$_en" -lt 15 ]; do
        s=$(getprop init.svc.pxrfanservice 2>/dev/null)
        [ "$s" = "running" ] && [ "$_en" -ge 3 ] && return 0
        sleep 1
        _en=$((_en + 1))
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

# decide <tier> <rpm>  ->  prints "<真实档位名> <duty> <rpm|tier>"
# 修 [2]：rpm 升速必须同时满足温度闸门，否则一旦冲上 12000 就再也降不下来。
#
# 第三个字段标出 duty 的来源（rpm 闸门 / 温度档位）。原来这里直接把
# "RPM-CAP" 当作档位名回给调用方，被写进 state/cur_tier；而 pick_tier
# 只认 QUIET..VERYHOT，读到 RPM-CAP 就当成"未知"回退成 IDLE，
# 于是紧接着的那次降温完全不走回滞，action.sh cycle 也会从头开始。
# 现在 cur_tier 只写真实档位名，闸门状态单列一个字段。
decide() {
    _tier="$1"
    _rpm="$2"
    _d=$(tier_duty "$_tier")
    [ -z "$_d" ] && return 1
    _r=$(tier_rank "$_tier")
    if [ -n "$_rpm" ] && [ "$RPM_CAP" -gt 0 ] 2>/dev/null \
       && [ "$_rpm" -ge "$RPM_CAP" ] 2>/dev/null \
       && [ "$_r" -ge "$RPM_RELEASE_RANK" ]; then
        echo "$_tier $RPM_DUTY rpm"
    else
        echo "$_tier $_d tier"
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

# 原名 enable —— 与 POSIX 同名内建冲突（shellcheck SC3044），改名。
enable_control() {
    if ! enter_test_mode; then
        return 1
    fi
    rm -f "$DISABLED" "$GAVE_UP"
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

# 判断 pid 是否是"还活着的 service.sh"。保守处理：读不到 /proc 时只信 kill -0，
# 读得到就再核一次 cmdline，防止 pid 复用到别的进程上误杀自己人。
svc_alive() {
    _p="${1:-}"
    [ -n "$_p" ] || return 1
    [ "$_p" != "$$" ] || return 1
    kill -0 "$_p" 2>/dev/null || return 1
    if [ -r "/proc/$_p/cmdline" ]; then
        tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q "service.sh" || return 1
    fi
    return 0
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

    # 单实例保护。原来只靠 action.sh 里的 pgrep/pkill -f，一旦它们不存在或
    # 匹配失败就会跑出两个循环互相抢写 duty。这里用 pid 文件 + kill -0 兜底，
    # 能读到 /proc 时再校一次 cmdline，避免 pid 复用导致误判。
    if [ -r "$PID_FILE" ]; then
        _old=$(cat "$PID_FILE" 2>/dev/null)
        if svc_alive "$_old"; then
            log "another service.sh (pid $_old) already running, exiting"
            return 0
        fi
    fi
    echo $$ > "$PID_FILE" 2>/dev/null
    trap 'rm -f "$PID_FILE" 2>/dev/null' EXIT

    # 上一次运行如果因写入持续失败而放弃过，新一轮重新尝试。
    rm -f "$GAVE_UP" 2>/dev/null

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
        if ! enable_control; then
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
        # decide 输出 "<真实档位名> <duty> <rpm|tier>"。用 set -- 拆，省三次 fork。
        # 这里就是要按空格拆字段，不需要引号
        # shellcheck disable=SC2086
        set -- $pos
        cur_tier_name="$1"
        desired="$2"
        gate="$3"

        # Only touch the fan when the desired duty actually changes.
        if [ "$desired" != "$cur_duty_written" ]; then
            if set_duty "$desired"; then
                fail_streak=0
                got=$(get_duty 2)
                cur_duty_written="$desired"
                echo "$desired" > "$CUR_DUTY"
                echo "$cur_tier_name" > "$CUR_TIER"
                date +%s > "$LAST_OK" 2>/dev/null
                log "skin $((t / 1000))C rpm ${rpm_now:-?} -> $cur_tier_name duty $desired [$gate] (reported ${got:-?})"
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
                        got=$(get_duty 2)
                        cur_duty_written="$desired"
                        echo "$desired" > "$CUR_DUTY"
                        echo "$cur_tier_name" > "$CUR_TIER"
                        date +%s > "$LAST_OK" 2>/dev/null
                        log "re-armed ok: skin $((t / 1000))C -> $cur_tier_name duty $desired [$gate] (reported ${got:-?})"
                    fi
                fi

                # 放弃阈值：写入持续被拒说明这一轮拿不到控制权（固件变更 /
                # 权限丢失 / MCU 异常）。再重试下去只会让 MCU 一直卡在 test
                # mode —— 厂商的 duty 帧同样被拒，风扇没人管，而 state 里
                # 还写着"本模块温控"。到上限就退出 test mode 交还原厂。
                if [ "$fail_streak" -ge "$MAX_FAIL_STREAK" ]; then
                    log "ERROR: $fail_streak consecutive rejections, giving up and handing back to vendor"
                    : > "$GAVE_UP" 2>/dev/null
                    rm -f "$ENABLED" 2>/dev/null
                    exit_test_mode
                    return 1
                fi
                sleep "$RETRY_BACKOFF"
            fi
        fi

        # 每 ~6 个循环（约 30s）校验一次持有值。漂移了就静默重写。
        if [ $((n % 6)) -eq 0 ] && [ -n "$cur_duty_written" ]; then
            held=$(get_duty 2)
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
    echo "  输出格式: <真实档位名> <duty> <rpm|tier>"
    echo "  decide IDLE    12500 -> $(decide IDLE 12500)     <- 低温柔闸门挡住，转速可回落"
    echo "  decide IDLE     7000 -> $(decide IDLE 7000)"
    echo "  decide WARM    12500 -> $(decide WARM 12500)"
    echo "  decide HOT     12500 -> $(decide HOT 12500)"
    echo "  decide VERYHOT 12500 -> $(decide VERYHOT 12500)"
    echo "  decide IDLE         -> $(decide IDLE '')"
    echo "  对比：上游无闸门时 IDLE/12500 会得到 RPM-CAP $RPM_DUTY 并永久自锁"
    echo "  实测：duty 88% -> 13671 RPM；duty 78% -> 12220 RPM（故上游确实会锁死）"

    echo ""
    echo "== [新] 配置校验（sanitize_config）=="
    echo "  当前生效值: LOOP_INTERVAL=$LOOP_INTERVAL RETRY_BACKOFF=$RETRY_BACKOFF"
    echo "              FAIL_LOG_EVERY=$FAIL_LOG_EVERY MAX_FAIL_STREAK=$MAX_FAIL_STREAK"
    echo "              HYSTERESIS=$HYSTERESIS (上限=相邻档位最小间隔-1)"
    echo "  阈值单调: T0=$T0 < T1=$T1 < T2=$T2 < T3=$T3 < T4=$T4"
    echo "  档位 duty: QUIET=$TIER_QUIET IDLE=$TIER_IDLE WARM=$TIER_WARM HOT=$TIER_HOT VERYHOT=$TIER_VERYHOT"
    echo "  非法值会被夹紧/回落并记日志，用 --dumpcfg 看最终生效值。"

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

# 打印校验后的最终生效配置（KEY=VALUE），供 action.sh 直接 source，
# 保证 status 显示的阈值与 service.sh 实际使用的是同一份，不会出现
# "配置写错了但 status 还显示错的值" 这种误导。
dumpcfg() {
    for _k in TIER_QUIET TIER_IDLE TIER_WARM TIER_HOT TIER_VERYHOT \
              T0 T1 T2 T3 T4 HYSTERESIS LOOP_INTERVAL STARTUP_GRACE \
              RPM_CAP RPM_DUTY RPM_RELEASE_RANK OVERHEAT_RELEASE_RANK \
              RETRY_BACKOFF FAIL_LOG_EVERY MAX_FAIL_STREAK; do
        eval "printf '%s=%s\n' \"\$_k\" \"\$$_k\""
    done
}

case "${1:-}" in
    --selftest|-t)
        selftest
        exit 0
        ;;
    --dumpcfg)
        dumpcfg
        exit 0
        ;;
esac

main "$@"
