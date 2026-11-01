# Changelog

## v1.6.1

自检（`--selftest`）的夹具缺陷，不影响模块运行逻辑。

`[3]` 阶梯用例跑在 `WAKE_SRC` 夹具文件创建之前，于是 `wake_state` 回落到读取
**设备的真实 mWakefulness**：设备当时处于睡眠态 → 命中 v1.6.0 新增的熄屏压档 →
除皮肤达到 T4 外，中间档位全部被压成 IDLE（`63000 -> IDLE`、`67000 -> IDLE`）。
在 Linux 上跑（没有 `dumpsys`）不会暴露，只有在真机上才看得到。

现在自检先把夹具置为 `Awake` 再跑，`[12]` 段再按用例覆盖。真机复验：
`63000->WARM / 65000->HOT / 67000->VERYHOT / 69000->OVERHEAT`，
回滞 `66199->HOT`、`64199->WARM`，全部与预期一致。

## v1.6.0

2026-10-31 在一台装了眼追面捕套件（PowerHub PH-022 坞 + SG-PC34M 35W 头）的
PICO 4 / A8110 上实机排查「插着电却掉电」与「熄屏后风扇仍满转」时得到的改动。

### Fixed

**1. 充电 IC 的温度根本没有参与风扇决策。**
`charger_temp`（PMIC 的 NTC，阈值 `charger_temp_max=800` 即 80°C）到 77–80°C 时，
驱动会把输入契约从 9V/3A 砍回 5V/1.55A；而 5V 档输入只有 7.75W，低于整机功耗
（8 核满载实测约 11W），电池转为**净放电 −1.2A** —— 这就是「插着还在掉电」。
热框架里 `pm8150b_tz` 没有绑定任何 cooling device，只能上报不能处置。
现在把 `charger_temp` 作为第二温度源（60/65/70/75/79°C 分档）与皮肤取较高者。

**2. 过热档把风扇交回原厂 = 交给一个更弱的策略。**
实测原厂锁 duty 40% / 7790 RPM，而本模块 VERYHOT=78%、RPM_DUTY=88%（14165 RPM）。
越热越松手，等于在最需要风的时候放弃散热。新增 `OVERHEAT_HANDBACK`（默认 0 =
自己吃满风），想恢复上游行为设 1。

**3. 皮肤阈值与本机实际分布不匹配。**
这台机器只要醒着 SoC 就 63–76°C、虚拟皮肤常年 57–61°C，而旧 T4=56°C 让「醒着」
就等于「过热」→ 风扇整天 88%。重标定为 57/63/65/67/69（实测：空闲 25% / 4960 RPM，
负载 88% / 14000 RPM，撤负载后自动回落 55%）。

**4. 漂移校验把写入失败吞掉了（又一类「僵尸」）。**
每 30 秒一次的回读校验在重写失败时既不清 `IN_TEST` 也不重进 test mode，于是
`state/cur_duty` 继续显示 88% 而硬件早回落原厂转速。现在失败即判定丢锁 →
清标记 → 重新接管。注入故障实测：1 秒内完成 `drift → re-arm → duty 恢复`。

**5. 睡眠时风扇会「冻住」。**
守护进程睡过去就被内核冻结，风扇停在上次写入的 duty 上（睡前 88%，整晚 88%）。
新增 `SCREEN_OFF_MAX_RANK`：检测到非 `Awake` 就把档位压到 IDLE（25%），真烫
（充电 IC ≥ CHG3 或皮肤 ≥ T4）则不压。

### Added

- `--selftest` 增加 [8] 双温度源合流、[10] 熄屏压档的判定用例。
- `--dumpcfg` 输出全部 v1.6 新键；`action.sh status` 增加充电 IC 阈值与当前
  `mWakefulness` 显示。
- 仓库首次附带**可刷入的 Magisk 模块 zip**（含 `META-INF/` 与 `update-binary`），
  此前 release 只上传了文档。

### 实测数据（同负载 A/B，PICO 4 / A8110）

| | 不限流 | 限流 1.2A |
|---|---|---|
| 9V↔5V 掉档（4.5 分钟） | 4 次 | **0 次** |
| 充电 IC 峰值 | 80.4°C（die=Hot） | 77.5°C |
| 电池电流 | +2.0A，5V 档 −1.2A | +1.03A |
| 电量 | +1% | **+2%** |

## v1.5.0

Real-device hardening release. Both fixes below were found by running the module **on a real
PICO 4 (A8110)** — the dash simulation used for v1.4.0 could not surface them, because they only
manifest on Android's actual `/system/bin/sh` (mksh) and toybox userland.

### Fixed

**1. `config.cfg` was blindly `source`d — variable override + arbitrary code execution as root.**
The file is user-editable, and `source` lets *any* key overwrite internal script variables and
lets *any* value execute commands at parse time:

* `TOOL=/system/bin/false`, `STATE_DIR=/data/evil`, `TEMP_NODE=...`, `LOG_TAG=...`,
  `MODDIR=...` — all of these are in-script variables. Overriding `TOOL` silently disables fan
  control; overriding `STATE_DIR`/`MODDIR` redirects all state writes off the module.
* `EVIL=$(touch /data/...)` or a value containing backticks — executes at `source` time, i.e.
  **arbitrary command execution as root** on every boot.

Replaced the `source` with a **whitelist line parser**: strip CR first, accept only the 19 known
numeric keys, and reject any value containing `$( )`, backticks, `;` or `&`. Verified on-device
with a hostile `config.cfg` containing `TOOL=/system/bin/false`, `STATE_DIR=/data/.../evilstate`,
`PWNED=$(touch ...)` and even `TIER_QUIET=$(touch ...)` (a whitelist key carrying a `$( )`
value): none of the overrides took effect, neither payload file was created, and the loop still
engaged and controlled the fan normally.

**2. The watchdog could not kill script-type MCU tools — fan froze.**
v1.4.0 wrapped tool calls in `$(timeout 5 "$TOOL" ...)`. On the device, toybox `timeout` fails
to deliver the signal to a tool that is itself a script (shebang + a `sleep 60` inside): the
watchdog degrades to waiting the full 60 s, so a hung tool freezes the fan at its last speed
instead of timing out. The `$( )` capture also blocks forever when the killed tool leaves an
orphaned child holding the pipe write end.

Rewrote `run_tool` to **not use the `timeout` binary at all**: launch the tool in the background,
poll `kill -0`, and on timeout `kill -9` the entire process group (so a script and its children
are reaped together); tool output goes to a temp file, never a pipe. On-device test with a tool
that `sleep 60`s: each call is now bounded to 5 s and the loop keeps making progress
(`speed_calls=3` within a 22 s window — a broken watchdog would only have managed 1).

### Upgrade note

`config.cfg` is read the same way as before (whitelist parse), so existing files keep working.
The security fix means **a `config.cfg` that relied on overriding `TOOL`/`STATE_DIR`/etc. will
no longer take effect** — those were never supported keys and were a hole, not a feature.

---

## v1.4.0

Robustness release. 这一版修的是 v1.3.0 里**仍然会让模块静默失灵**的几个口子，
全部在 dash（等价于 Android `/system/bin/sh`）仿真环境下复现过。

### Fixed

**1. 写入持续被拒时无限重试，且永不交还原厂。**
`set_duty` 失败后 `cur_duty_written` 永远为空 → 每个周期都重试，形成永久的 binder
调用风暴；`state/cur_duty` / `cur_tier` 从头到尾没被创建过，而 `enabled` / `in_test`
都在，`action.sh status` 显示"模式: 本模块温控"看起来一切正常。更糟的是失败路径既不
退出 test mode 也不交还原厂 —— MCU 卡在 test mode，厂商的 duty 帧同样被拒，风扇没人管。

新增 `MAX_FAIL_STREAK`（默认 10）：连续失败到上限就 `exit_test_mode` 并写
`state/gave_up`，`status` 会明确显示"已放弃控制"。`action.sh restart` 或重启设备会重新尝试。

**2. `stop.sh` 不杀运行中的 service.sh。**
卸载/停用模块时只删了 state，主循环进程还在跑、仍持有 MCU test mode，并在下一个周期
发现 `in_test` 没了之后重新抢回控制权。表现是"模块卸了，风扇却停在某个转速下不来，
只有重启才好"。现在 `stop.sh` 会先退 test mode、再按 pid 文件 / 完整路径杀掉循环。

**3. 循环计数器 `n` 被 `get_duty()` / `exit_test_mode()` 覆盖。**
dash 没有作用域隔离，这两个函数都用 `n` 做自己的计数器，而 `main()` 的 `n` 用于
`if [ $((n % 6)) -eq 0 ]` 的漂移校验。`get_duty` 在第一次成功时 `n` 还是 0 就返回，
而 main 每次成功写 duty 都会调它 —— 于是档位一变化 `n` 就被清零，那段"每 ~30s
重新断言一次持有 duty"的看门狗实际上是死代码。改用独立变量名。

**4. `config.cfg` 完全没有校验。**
它是被 `source` 进来的，任何值都直接生效。实测：`LOOP_INTERVAL=abc` → `sleep` 立即
返回 → 主循环退化成零延迟忙循环（binder 调用风暴 + 打满 CPU）；`TIER_HOT=150` →
每次写入被拒 → 落入缺陷 1；`T0=50000` 且 `T1=47000` → 档位阶梯跳档，2°C 内 0% 直接
跳到 55%；`FAIL_LOG_EVERY=0` → 取模除零，失败日志彻底不打印。

新增 `sanitize_config()`：档位 duty 夹紧 0-100、阈值必须严格递增、`HYSTERESIS` 上限为
相邻档位最小间隔-1、`LOOP_INTERVAL`/`RETRY_BACKOFF` 下限 1、`FAIL_LOG_EVERY` 下限 1。
非法值记日志并回落。`service.sh --dumpcfg` 可打印校验后的最终生效值。

**5. `decide` 把 `RPM-CAP` 写进 `state/cur_tier`。**
`pick_tier` 只认 `QUIET..VERYHOT`，读到 `RPM-CAP` 会当成未知档位回退成 `IDLE`，于是
触发过一次 RPM 闸门之后，紧接着的那次降温**完全不走回滞**；`action.sh cycle` 也会从头
开始，`status` 显示的档名不在档位表里。现在 `decide` 输出 `<真实档位名> <duty> <rpm|tier>`，
`cur_tier` 只写真实档位名，闸门状态单列一个字段（日志里以 `[rpm]` / `[tier]` 标出）。

**6. 没有实例锁。**
原来只靠 `pgrep -f` / `pkill -f` 判断与杀进程：它们不存在（精简环境）或匹配串过宽
（用的是裸 `service.sh`）时会跑出两个循环互相抢写 duty。现在 service.sh 写
`state/service.pid`，配合 `kill -0` + `/proc/<pid>/cmdline` 校验做单实例保护；
`action.sh` 的 restart / pin / cycle 统一走 `kill_service()`。

**7. `action.sh cycle` 不清除 `state/pinned`。**
`set 50` 之后再 `cycle`，`status` 仍显示"模式: 手动固定 (duty=50%)"，与刚切到的档位不符。

**8. 没有 `/system/bin/timeout` 时看门狗失效。**
v1.3.0 说"所有工具调用都套 `timeout 5`"，但 fallback 分支是裸调用，binder 对端挂死时
整个循环照样永久卡住。现在 fallback 用后台子 shell + 轮询 + 强杀自己实现超时兜底。

**9. 函数名 `enable` 遮蔽 POSIX 同名内建**（shellcheck SC3044），改名 `enable_control`。

### Added

* `MAX_FAIL_STREAK`（config.cfg，默认 10）
* `service.sh --dumpcfg` —— 打印校验后的最终生效配置，`action.sh status` 现在优先用它，
  避免"配置写错了但 status 显示的还是错的值"
* `state/gave_up` / `state/last_ok` / `state/service.pid`
* `status` 新增"上次成功写风扇: N 秒前"——模块看着在跑但这个数不动，就是没有控制权

---

## v1.3.0

Fixes a set of defects that could make the module **silently lose control of the fan while
still appearing to run normally** — the worst possible failure mode for a thermal manager,
because the log and the state files both look plausible.

All of the items below were reproduced on a PICO A8110 (PICO 4) before and after the fix.

### Fixed

**1. Stale test-mode flag turned the module into a zombie.**
`enter_test_mode()` returned early whenever `state/in_test` existed, so it never checked the
MCU's *actual* firmware state. The MCU-side lock can be lost on its own (vendor re-handshake,
anomaly), and once that happened the module never re-issued `setfantestmode 1` — every
`setfantestspeed` was rejected forever, and it logged a failure every 5 seconds until the
logcat ring buffer was full of nothing else (17+ minutes of continuous failures observed, and
the earlier boot-time records pushed out of the buffer).

Now a rejected write is treated as "the lock is gone": clear the flag, re-enter test mode,
retry immediately. Failure logging is throttled.

```
before:  ... setfantestspeed 45 failed, will retry      (forever, every 5 s)
after:   05:19:22.899 setfantestspeed 78 rejected (streak 1), re-arming MCU test mode
         05:19:23.016 re-armed ok: skin 53C -> VERYHOT duty 78 (reported 78)   ← 117 ms
```

**2. The RPM-cap rule latched permanently and bypassed the temperature table.**
`if rpm >= RPM_CAP then duty = RPM_DUTY` (88%) ignores temperature entirely, and at duty 88%
the fan reports ≥ 12000 rpm again — so the condition is true forever. The only escape is a
lower duty, which requires rpm to already be under the cap. Deadlock: once the fan reached
12000 rpm, it stayed near full speed at idle until reboot.

Measured on this unit: duty 78% → 12220 rpm, duty 88% → 13671 rpm, so the threshold was
genuinely reachable in normal use.

New `RPM_RELEASE_RANK` (default 3 = hot) gates the rule on the temperature tier, so the fan
drops back as soon as the skin returns below 50°C.

```
before:  t=274s temp=46.6C rpm=13671 duty=88   ...and nothing changes
after:   t=274s temp=46.6C rpm=13671 duty=88
         t=284s temp=45.4C rpm=4937  duty=25   ← released automatically
```

**3. `HYSTERESIS` was documented but not implemented.**
`pick_tier()` read `prev` but only used it in the quiet branch; the warm/hot/very-hot
downgrades were plain threshold comparisons, so the parameter had no effect. Replaced with a
proper ladder: up on the threshold, down only below `threshold − HYSTERESIS`.

**4. "Hand back to the vendor" on overheat lasted five seconds.**
With `IN_TEST` removed, the next loop re-grabbed test mode immediately, defeating the vendor's
own high-temperature protection. New `OVERHEAT_RELEASE_RANK` (default 3 = hot) requires the
skin to fall back to that tier first.

**5. `action.sh disable` did not persist.** It removed both `enabled` and `in_test`, so at boot
the service fell into the auto-takeover branch and started controlling the fan again. Also, a
`service.sh` loop that was *already running* ignored the flag entirely and re-armed test mode
on its next cycle. Added `state/disabled`: `disable` writes it, boot honours it, the running
loop exits by itself.

**6. CRLF line endings killed the module outright.**
Android's sh does not treat CR as whitespace, so a CRLF `service.sh` fails on every
assignment—

```
$ sh service_crlf.sh --selftest
service_crlf.sh[44]: : inaccessible or not found
service_crlf.sh[46]: : inaccessible or not found
...
```

—and a CRLF `config.cfg` puts a stray CR into every value. This is easy to hit on Windows,
where git's default `core.autocrlf=true` checks the repo out as CRLF. Mitigated three ways:
`.gitattributes` forces LF, `customize.sh` normalises at install time, and `config.cfg` is read
with CR stripped.

**7. No timeout on the binder calls.** `gd32ipdclient_test` is a binder client; if the peer
hangs, the control loop hangs with it and the fan freezes at the last written duty. All tool
invocations now run under `timeout 5`.

**8. No runtime check of the disabled flag**, see item 5.

### Changed

* `T0` 38000 → **41000**. A PICO 4 idling with the screen off measures 37.5–40°C skin, so 38°C
  sat directly on the idle temperature.
* `TIER_IDLE` 45 → **25**. The first step was 0% → 45%, i.e. 0 → ~7500 RPM with nothing in
  between. (Measured curve: 25% = 4346 rpm, 45% = 7548 rpm, minimum spin ~3450 rpm.)
  Together with the `T0` change this removes a 0 ↔ 7500 RPM flap on an idle headset.
* `HYSTERESIS` 400 → **800** (and it now actually does something, see item 3).
* Overheat no longer clears `state/enabled`, which used to leave the state directory
  inconsistent (`in_test` present, `enabled` absent).
* Removed the dead `state/last_run.log` variable.

### Added

* `RPM_RELEASE_RANK`, `OVERHEAT_RELEASE_RANK`, `RETRY_BACKOFF`, `FAIL_LOG_EVERY` in `config.cfg`.
* `service.sh --selftest` (and `action.sh selftest`) — runs the tier ladder, hysteresis and RPM
  gate as pure logic against a scratch state directory. Reads no sensor, writes no fan, safe to
  run at any time. Test hooks: `PICO4_STATE_DIR`, `PICO4_TEMP_NODE`.
* `state/disabled` flag.
* `config.cfg` read with CR stripped; `.gitattributes`; install-time line-ending normalisation.

### Upgrade note

`config.cfg` is read as-is, so an existing file keeps the old numbers. To pick up the new
defaults, delete it and let the module recreate it, or copy the new values from the shipped
file.

---

## v1.2.0

Previous release. Skipped `1.1.0` and `1.0.0`.

* Moved thresholds and tier duties out of `service.sh` into `config.cfg`, so they can be
  reloaded with `action.sh restart` instead of editing the script.
* Added the `state/enabled` / `state/in_test` flags for boot takeover.
* Added `action.sh restart`.
