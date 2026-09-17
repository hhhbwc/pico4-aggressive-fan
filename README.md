# PICO 4 Aggressive Fan Control (更激进的风扇转速)

**English** | [中文](#中文) | [Русский](#русский)

---

A Magisk module that replaces PICO 4's stock fan curve with a skin-temperature stepped curve, one tier higher. Uses GD32 MCU test mode to bypass the stock 35% duty lock — the vendor service (`pxrfanservice`) stays running untouched.

> **v1.3.0** fixes several defects that made the module silently lose control of the fan — a stale test-mode flag, an RPM escalation rule that never released, hysteresis that was documented but never implemented, a non-persistent `disable`, and CRLF line endings breaking the scripts outright. Details and measured evidence: [CHANGELOG.md](CHANGELOG.md).
>
> If you are upgrading from v1.2.0, re-check `config.cfg`: the shipped `T0` (38000 → 41000) and `TIER_IDLE` (45 → 25) changed, and four new keys were added. Your existing file is read as-is, so delete it to pick up the new defaults.

**核心机制**: `setfantestmode 1` puts the GD32 MCU into test mode, where it rejects the vendor's `SetFanSpeed` frames at the firmware level. The vendor keeps running its temperature sampling and state machine — only its duty writes stop reaching the motor.

---

## English

### Why this exists

The PICO 4 fan is not driven by the Snapdragon 865 directly. The chain is:

```
Snapdragon 865 ──UART /dev/ttyHS1──> GD32 MCU ──PWM──> fan motor
  gd32ipdservice                      (RPM feedback counting)
      ↑
  pxrfanservice  ← stock fan policy lives here
```

The stock `pxrfanservice` policy is very conservative (measured on the author's unit):

| State | duty | RPM | Skin temp (zone86) |
|---|---|---|---|
| Idle | 30–40% | ~7050 | ~52°C |
| Heavy load (12 procs, 5 min) | 30→35% then **locked** | ~6200 | 45.7°C → 51.8°C, keeps rising |

Under load the fan climbs to 35% and stops. Skin temperature climbs to 51.8°C and the fan does not respond.

This module replaces that policy with a stepped curve, one tier above stock.

### Core mechanism: MCU test mode

This module uses a set of commands from PICO's factory test program:

```sh
/system/bin/gd32ipdclient_test setfantestmode 1    # enter test mode
/system/bin/gd32ipdclient_test setfantestspeed 55   # set speed
```

Once test mode is entered, the GD32 MCU **rejects** the vendor's `SetFanSpeed` frames. Verifiable in logcat:

```
gd32ipdservice: L1:79 2d 00 54            ← vendor sends duty=45
gd32ipdservice: L1:retry_cnt=3 ret=4      ← MCU rejects
```

The duty written by `setfantestspeed` is unaffected. This means **`pxrfanservice` keeps running normally** — its temperature sampling, state machine, and logging all work; only its duty output stops reaching the motor. No need to stop the vendor service, no side effects.

Exiting test mode does not unlock immediately — the MCU still waits for the vendor to re-handshake (`79 00 00 00 28 23 00 00 01 73` accepted, `ret=10`) before accepting duty frames again. So the exit path restarts `pxrfanservice` to trigger that handshake.

### Fan tiers

Temperature source: `/sys/class/thermal/thermal_zone86/temp` (skin-msm-therm-usr, millidegrees C)

| Skin temp | tier | duty | Measured RPM |
|---|---|---|---|
| < 41°C | quiet | 0% | 0 |
| 41–47°C | idle | 25% | 4346 |
| 47–50°C | warm | 55% | ~9000 |
| 50–53°C | hot | 65% | ~10600 |
| 53–56°C | very hot | 78% | 12220 |
| ≥ 56°C | **hand back to stock policy** | vendor decides |

Measured duty → RPM curve on a PICO A8110:

| duty | 0% | 15% | 20% | 25% | 30% | 35% | 45% | 65% | 78% | 88% |
|---|---|---|---|---|---|---|---|---|---|---|
| RPM | 0 | 3456 | 3488 | 4346 | 5132 | 5973 | 7548 | ~10600 | 12220 | 13671 |

About 3450 RPM is the slowest the fan will actually turn, so any duty under ~15% is effectively "off".

**Why `T0` is 41°C and not 38°C.** A PICO 4 sitting idle with the screen off measures 37.5–40°C skin. A 38°C threshold therefore sits directly on the idle temperature, and with a first tier of 45% (~7500 RPM) that produced a 0 ↔ 7500 RPM flap: the fan audibly spinning up and stopping again every few minutes on a headset nobody was using.

The quiet tier matches what the vendor itself does around 36°C (drops the fan to 0).

The last tier deliberately hands control back to the stock firmware: when it gets genuinely hot, exiting test mode, restarting the vendor service, and restoring its thermal-protection logic is safer than this module holding a fixed duty. Control is taken back only once the skin has fallen to the `HOT` tier again (`OVERHEAT_RELEASE_RANK`, default 3) — releasing it and immediately re-grabbing it five seconds later would defeat the whole point.

**Hysteresis**: tiers move up the moment a threshold is crossed, but move down only once the skin has fallen below `threshold − HYSTERESIS` (default 800 mC = 0.8°C). A wobble at a boundary therefore does not ping-pong the fan every loop. (In v1.2.0 this was documented but not actually implemented outside the quiet tier — the parameter had no effect.)

**RPM cap, temperature-gated**: if the MCU reports rpm ≥ `RPM_CAP` (default 12000) **and** the temperature tier is at least `RPM_RELEASE_RANK` (default 3 = hot, i.e. skin ≥ 50°C), the next loop raises duty to `RPM_DUTY` (default 88%).

The temperature gate is what keeps this safe. Without it the rule latches permanently, and it does so in a way that looks fine in a code read: rpm ≥ 12000 sets duty to 88%; at duty 88% the fan reports ≥ 12000 rpm; so the condition is true again forever — and it bypasses the temperature table entirely. The only way out would be a lower duty, which requires rpm to already be under the cap. Measured rpm really does reach 13671 at duty 88%, so this was reachable in ordinary use and the fan would sit near full speed at idle until reboot. With the gate it drops back as soon as the skin returns below 50°C.

### Tuning

All thresholds and tier duties live in `config.cfg` next to `service.sh`. Edit it, then either:

```sh
# Re-read config.cfg without rebooting the module:
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh restart"

# Or reboot the module (or the device).
```

Example `config.cfg` (the shipped default):

```
TIER_QUIET=0   TIER_IDLE=25   TIER_WARM=55   TIER_HOT=65   TIER_VERYHOT=78
T0=41000  T1=47000  T2=50000  T3=53000  T4=56000
HYSTERESIS=800
LOOP_INTERVAL=5
STARTUP_GRACE=45
RPM_CAP=12000
RPM_DUTY=88
RPM_RELEASE_RANK=3
OVERHEAT_RELEASE_RANK=3
RETRY_BACKOFF=3
FAIL_LOG_EVERY=12
```

The file is read with CR stripped, so saving it with a Windows editor (Notepad etc.) that writes CRLF is safe. Keys you leave out fall back to the built-in defaults.

### Usage

After install, the module takes over the fan automatically on boot.

Manual control (Magisk Manager "Action" button, or from shell):

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"    # print duty/rpm/temp/tier + tier table
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"    # let service.sh drive the fan by temperature
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"   # restore stock policy
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh set 70"    # pin fan to a fixed 70% until disable/restart
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh cycle"     # walk QUIET->IDLE->WARM->HOT->VERYHOT->QUIET
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh restart"   # reload config.cfg (kill + respawn service.sh)
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh selftest"  # pure-logic check, read-only
```

The switch state survives reboot (v1.3.0): `state/enabled` means "the module is driving the fan", `state/disabled` means "the user turned it off" — after a `disable` the module will not quietly take over again at boot. `disable` also hands the fan back to the vendor and the running control loop exits by itself.

To restore stock behaviour: disable or uninstall the module. `stop.sh` exits test mode, restarts the vendor service, and returns the fan to stock control.

### Real-time fan status

```sh
su -c '/system/bin/gd32ipdclient_test getfaninfo'
# duty=55 rpm=8530 rpm_target=9000 mode=duty mode
```

### Extended keys (v1.3.0)

Beyond the tier table, `config.cfg` carries a few knobs that did not exist in v1.2.0:

| Key | Default | Meaning |
|---|---|---|
| `RPM_RELEASE_RANK` | 3 | Temperature tier (`0` quiet … `4` very hot) required before the RPM-cap rule may raise duty. `3` = only at skin ≥ 50°C. Raise it to keep the fan quieter, lower it for more headroom. |
| `OVERHEAT_RELEASE_RANK` | 3 | Temperature tier the skin must fall back to before the module retakes control after an overheat handback. |
| `RETRY_BACKOFF` | 3 | Seconds to wait after a rejected fan write before trying again. |
| `FAIL_LOG_EVERY` | 12 | Log throttling — only 1 in N consecutive write failures is logged (the first one is always logged). |

To make the overheat tier hold a fixed 90% instead of handing back to the vendor, replace `exit_test_mode` with `set_duty 90` in the `main` loop's overheat branch and drop the `IN_TEST` bookkeeping there — but you then lose the vendor's own high-temperature protection.

### Self-test

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/service.sh --selftest"
```

Runs the tier ladder, hysteresis and RPM gate as pure logic against a scratch state directory. It does not touch the fan or the real sensor node, so it is safe to run any time. Use it to see exactly what a given `config.cfg` will do before you rely on it. `action.sh selftest` is a shorthand for the same thing.

### Notes

1. **Root required.** `gd32ipdclient_test` talks to a root-only binder service; a plain shell cannot drive it.
2. **Unofficial method.** Uses PICO's factory test program; no public interface is exposed. Firmware updates may change the paths or parameters. The scripts degrade gracefully if the tool or the temp node is missing, but they will not force-lock the fan — if they cannot get control, they exit and let the vendor take over.
3. **Vendor service always runs.** It is never killed. Its high-temp protection logic re-activates at the overheat tier. Under normal temperatures you will just be cooler.
4. **Fan speed ceiling:** duty 88% measures 13671 RPM; duty 100% is around 12500 on some units. Noise rises noticeably above duty ~85%.
5. **Uninstall restores stock.** No manual cleanup needed; `stop.sh` exits test mode and restarts the vendor service.
6. **Auto-takeover on reboot**, unless you turned it off with `action.sh disable` — that writes `state/disabled` and is honoured across reboots.
7. **Line endings matter.** Android's sh does not treat CR as whitespace: a CRLF `service.sh` fails on every line (observed: `service.sh[44]: : inaccessible or not found`, the module completely dead), and a CRLF `config.cfg` puts a stray CR into every value. This repo ships `.gitattributes` forcing LF, `customize.sh` normalises at install time, and `config.cfg` is read with CR stripped.
8. **A silent module is the failure mode to watch for.** The loop logs only on state changes, so a healthy system is quiet. If the log fills with rejection lines, run `action.sh status` and `service.sh --selftest` — they report whether the module actually holds the MCU test-mode lock rather than assuming it does.

### Files

| File | Purpose |
|---|---|
| `module.prop` | Magisk module metadata |
| `customize.sh` | Set permissions and normalise line endings at install |
| `service.sh` | Main loop: stepped fan control by temperature (plus `--selftest`) |
| `stop.sh` | Exit test mode and restore stock policy on uninstall |
| `action.sh` | Manual enable/disable / status / selftest |
| `config.cfg` | Thresholds and tier duties |
| `CHANGELOG.md` | Version history and the v1.3.0 bug-fix notes |
| `.gitattributes` | Forces LF for scripts and config |

### Credit

The core locking mechanism (`setfantestmode`) was discovered via [Seva167/PicoFanControl](https://github.com/Seva167/PicoFanControl). That project does manual speed control only (min 50%, no temperature feedback, does not handle the unlock path). This module adds skin-temperature stepped control, full 0–100% range, overheat handback, and automatic boot takeover via Magisk.

---

## 中文

### 为什么要做这个

PICO 4 的风扇不是由骁龙 865 直接控制的。链路是：

```
骁龙865 ──UART /dev/ttyHS1──> GD32 MCU ──PWM──> 风扇电机
  gd32ipdservice                      (RPM 反馈计数)
      ↑
  pxrfanservice  ← 原厂温控策略在这里
```

原厂 `pxrfanservice` 的策略实测非常保守（本模块作者设备实测数据）：

| 状态 | duty | RPM | 皮肤温度 (zone86) |
|---|---|---|---|
| 空闲 | 30–40% | ~7050 | ~52°C |
| 满负载（12 进程压 5 分钟） | 30→35% 后**锁死** | ~6200 | 45.7°C → 51.8°C 一路涨 |

负载下风扇升到 35% 就不再加了，皮肤温度一路涨到 51.8°C 都不响应。

本模块把 vendor 停掉，自己按皮肤温度分档，整体高一档。

### 核心机制：MCU 测试模式

本模块用的是 PICO 出厂测试程序里的一组命令，而不是普通的面速命令：

```sh
/system/bin/gd32ipdclient_test setfantestmode 1    # 进入测试模式
/system/bin/gd32ipdclient_test setfantestspeed 55   # 设速
```

进入测试模式后，GD32 MCU 会**拒绝** vendor 的 SetFanSpeed 帧。logcat 里可以验证：

```
gd32ipdservice: L1:79 2d 00 54            ← vendor 发 duty=45
gd32ipdservice: L1:retry_cnt=3 ret=4      ← MCU 拒收
```

而 `setfantestspeed` 写入的 duty 不受影响。这样 **pxrfanservice 全程正常运行**，它的温度采样、状态机、日志都在工作，只是它的 duty 下发到不了电机。不需要停 vendor 服务，没有副作用。

退出测试模式不会立刻解锁——MCU 还要等 vendor 重新握手一次（`79 00 00 00 28 23 00 00 01 73` 被接受，`ret=10`）才恢复接收 duty 帧。所以退出路径会重启 `pxrfanservice` 触发这次握手。

### 温控档位

温度源：`/sys/class/thermal/thermal_zone86/temp`（skin-msm-therm-usr，单位毫摄氏度）

| 皮肤温度 | 档位 | duty | 实测 RPM |
|---|---|---|---|
| < 41°C | 安静 | 0% | 0 |
| 41–47°C | 空闲 | 25% | 4346 |
| 47–50°C | 温热 | 55% | ~9000 |
| 50–53°C | 较热 | 65% | ~10600 |
| 53–56°C | 很热 | 78% | 12220 |
| ≥ 56°C | **交回原厂策略** | 由原厂决定 |

PICO A8110 实测 duty → RPM 曲线：

| duty | 0% | 15% | 20% | 25% | 30% | 35% | 45% | 65% | 78% | 88% |
|---|---|---|---|---|---|---|---|---|---|---|
| RPM | 0 | 3456 | 3488 | 4346 | 5132 | 5973 | 7548 | ~10600 | 12220 | 13671 |

约 3450 RPM 是风扇真正能转起来的最低转速，所以 15% 以下基本等同于停转。

**为什么 T0 是 41°C 而不是 38°C**：PICO 4 息屏静置的皮肤温度实测就在 37.5–40°C。阈值定在 38°C 正好压在待机温度上，而第一档又是 45%（约 7500 RPM），于是出现 0 ↔ 7500 RPM 的反复起跳——一台没人用的设备，风扇每隔几分钟就自己转起来又停下。

安静档对应厂商在 36°C 左右自动停风扇的行为。

最后一档故意把控制权还给原厂：温度真的过高时，退出测试模式、重启 vendor 服务、恢复原厂保护逻辑，比本模块死守一个 duty 安全。控制权要等皮肤落回「较热」档（`OVERHEAT_RELEASE_RANK`，默认 3）才重新接管——交回 5 秒就抢回来等于没交回。

**滞回**：档位向上跨阈值直接升档，向下则需要皮肤温度跌破 `阈值 − HYSTERESIS` 才降档。默认 HYSTERESIS=800 mC（0.8°C）。（v1.2.0 里这段描述只写在文档里，代码除安静档外根本没实现，这个参数实际上不起作用。）

**RPM 上限（带温度闸门）**：若 MCU 上报 rpm ≥ `RPM_CAP`（默认 12000）**且**当前温度档位不低于 `RPM_RELEASE_RANK`（默认 3 = 较热，即皮肤 ≥ 50°C），下一循环才把 duty 提到 `RPM_DUTY`（默认 88%）。

这道温度闸门是安全的关键。没有它，这条规则会永久自锁，而且是那种"读代码时看不出问题"的锁：rpm ≥ 12000 → duty 设为 88%；而在 88% 下风扇上报的 rpm 又 ≥ 12000 → 条件永远成立，同时温度表被完全旁路。唯一的出路是把 duty 降下来，而这又要求 rpm 已经低于阈值——逻辑死锁。实测 duty 88% 时 rpm 真的会到 13671，所以这在日常使用中就能触发，触发后风扇会一直接近满速转下去直到重启。加了闸门之后，皮肤一回到 50°C 以下转速就降下来。

### 调整

所有阈值和档位都在 `config.cfg` 里。改完后：

```sh
# 不重启模块即可重读 config.cfg：
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh restart"

# 或重启模块/设备。
```

默认 `config.cfg`（即出厂值）：

```
TIER_QUIET=0   TIER_IDLE=25   TIER_WARM=55   TIER_HOT=65   TIER_VERYHOT=78
T0=41000  T1=47000  T2=50000  T3=53000  T4=56000
HYSTERESIS=800
LOOP_INTERVAL=5
STARTUP_GRACE=45
RPM_CAP=12000
RPM_DUTY=88
RPM_RELEASE_RANK=3
OVERHEAT_RELEASE_RANK=3
RETRY_BACKOFF=3
FAIL_LOG_EVERY=12
```

读取时会先去掉 CR，所以用 Windows 记事本编辑存成 CRLF 也没问题。没写的键回落到内置默认值。

### 使用方法

安装后模块开机自动接管风扇。

手动控制（Magisk 管理器的「操作」按钮，或直接进 shell）：

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"    # 打印 duty/rpm/温度/档位 + 档位表
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"    # 让 service.sh 按温度控风扇
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"   # 恢复原厂策略
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh set 70"    # 固定 70%，直到 disable 或 restart
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh cycle"     # 走档：安静->空闲->温热->较热->很热->安静
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh restart"   # 重载 config.cfg（杀 service.sh 重启）
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh selftest"  # 纯逻辑自检，只读
```

开关状态会写入 `state/enabled`，重启后按上次选择恢复。

恢复出厂行为：禁用或卸载模块即可，`stop.sh` 会自动退出测试模式、重启 vendor 服务，把风扇还给原厂。

### 查看风扇实时状态

```sh
su -c '/system/bin/gd32ipdclient_test getfaninfo'
# duty=55 rpm=8530 rpm_target=9000 mode=duty mode
```

### 新增参数（v1.3.0）

除档位表之外，`config.cfg` 里还有几个 v1.2.0 没有的开关：

| 参数 | 默认 | 含义 |
|---|---|---|
| `RPM_RELEASE_RANK` | 3 | 允许 RPM 升速规则生效所需的最低温度档位（`0` 安静 … `4` 很热）。`3` = 只有皮肤 ≥ 50°C 才升速。调大更安静，调小余量更多。 |
| `OVERHEAT_RELEASE_RANK` | 3 | 过热交回原厂后，皮肤要降回该档才重新接管。 |
| `RETRY_BACKOFF` | 3 | 风扇写入被拒后，下次重试前等待的秒数。 |
| `FAIL_LOG_EVERY` | 12 | 日志节流：连续 N 次失败只记 1 条（第 1 次总是记）。 |

想让过热档固定成 90% 而不是交回原厂，把 `main` 循环过热分支里的 `exit_test_mode` 换成 `set_duty 90`，并去掉那里的 `IN_TEST` 相关处理——但这样一来你就失去了原厂自己的高温保护。

### 自检

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/service.sh --selftest"
```

把档位阶梯、滞回和 RPM 闸门当作纯逻辑在临时状态目录里跑一遍。不碰风扇、不碰真实温度节点，任何时候都能跑。想确认某份 `config.cfg` 到底会怎么动作，先跑它。`action.sh selftest` 是同一个东西的简写。

### 注意事项

1. **需要 root**。`gd32ipdclient_test` 走的是 root-only 的 binder 服务，普通 shell 调不动。
2. **非官方方案**。走的是出厂测试程序 `gd32ipdclient_test`，PICO 没暴露公开接口。理论上固件升级后路径或参数可能变。脚本对工具缺失和温度节点缺失有降级处理，但不会强行锁住风扇——拿不到控制权就退出，让原厂接手。
3. **vendor 服务始终运行**，不会被杀掉。它的高温保护逻辑在过热档会重新生效。日常温度下你只会更凉快。
4. **风扇转速上限**：duty 88% 实测 13671 RPM；duty=100% 约 ~12500 RPM。duty 超过 ~85% 噪音明显上升。
5. **卸载即恢复**。不用手动清理，`stop.sh` 会退出测试模式并重新拉起 vendor 服务。
6. **重启后自动接管**，除非你用 `action.sh disable` 关过——那条命令会写 `state/disabled`，重启也会保持关闭。
7. **行尾符会出事**。Android 的 sh 不把 CR 当空白字符：CRLF 的 `service.sh` 每一行都会失败（实测报 `service.sh[44]: : inaccessible or not found`，模块彻底失灵），CRLF 的 `config.cfg` 会把回车带进每个值里。仓库用 `.gitattributes` 强制 LF，`customize.sh` 在安装时再归一化一次，`config.cfg` 读取时也会去掉 CR。
8. **模块"安静"才是正常**。控制循环只在状态变化时记日志，所以日志少是好事。如果日志被失败信息刷满，跑 `action.sh status` 和 `service.sh --selftest`——它们会告诉你模块到底有没有真正握住 MCU 的测试模式，而不是假设它握着。

### 文件清单

| 文件 | 作用 |
|---|---|
| `module.prop` | Magisk 模块元信息 |
| `customize.sh` | 安装时设置权限并归一化行尾符 |
| `service.sh` | 主循环：按温度分档控风扇（含 `--selftest`） |
| `stop.sh` | 卸载时退出测试模式、恢复原厂策略 |
| `action.sh` | 手动开关 / 状态查询 / 自检 |
| `config.cfg` | 阈值与各档 duty |
| `CHANGELOG.md` | 版本历史与 v1.3.0 修复说明 |
| `.gitattributes` | 强制脚本与配置使用 LF |

### 致谢

核心锁定机制（`setfantestmode`）是通过 [Seva167/PicoFanControl](https://github.com/Seva167/PicoFanControl) 发现的。该项目只做手动调速（最低 50%、无温度反馈、不处理解锁路径）。本模块增加了皮肤温度分档控制、0–100% 全范围、过热交回、以及通过 Magisk 开机自动接管。

---

## Русский

### Зачем это нужно

Вентилятор PICO 4 не управляется Snapdragon 865 напрямую. Цепочка:

```
Snapdragon 865 ──UART /dev/ttyHS1──> GD32 MCU ──PWM──> мотор вентилятора
  gd32ipdservice                      (подсчёт оборотов RPM)
      ↑
  pxrfanservice  ← заводская политика охлаждения здесь
```

Заводская политика `pxrfanservice` очень консервативна (измерения на устройстве автора):

| Состояние | duty | RPM | Т-ра кожи (zone86) |
|---|---|---|---|
| Свободный ход | 30–40% | ~7050 | ~52°C |
| Высокая нагрузка (12 процессов, 5 мин) | 30→35% затем **заблокировано** | ~6200 | 45.7°C → 51.8°C, продолжает расти |

Под нагрузкой вентилятор поднимается до 35% и останавливается. Температура кожи растёт до 51.8°C, а вентилятор не реагирует.

Этот модуль заменяет эту политику ступенчатой кривой, на одну ступень выше заводской.

### Ключевой механизм: тестовый режим MCU

Модуль использует набор команд из заводской тестовой программы PICO:

```sh
/system/bin/gd32ipdclient_test setfantestmode 1    # вход в тестовый режим
/system/bin/gd32ipdclient_test setfantestspeed 55   # установка скорости
```

После входа в тестовый режим GD32 MCU **отклоняет** кадры `SetFanSpeed` от vendor. Проверить в logcat:

```
gd32ipdservice: L1:79 2d 00 54            ← vendor шлёт duty=45
gd32ipdservice: L1:retry_cnt=3 ret=4      ← MCU отклоняет
```

Duty, записанный через `setfantestspeed`, не затрагивается. Это значит, что **`pxrfanservice` продолжает работать нормально** — его замеры температуры, конечный автомат и логирование работают; просто его duty не доходит до мотора. Нет необходимости останавливать vendor-сервис, нет побочных эффектов.

Выход из тестового режима не разблокирует немедленно — MCU всё ещё ждёт повторного handshakena с vendor (`79 00 00 00 28 23 00 00 01 73` принят, `ret=10`), прежде чем снова принимать duty-кадры. Поэтому путь выхода перезапускает `pxrfanservice`, чтобы запустить этот handshake.

### Ступени охлаждения

Источник температуры: `/sys/class/thermal/thermal_zone86/temp` (skin-msm-therm-usr, миллисели)

| Т-ра кожи | ступень | duty | Измеренные RPM |
|---|---|---|---|
| < 41°C | тихий | 0% | 0 |
| 41–47°C | свободный | 25% | 4346 |
| 47–50°C | тёплый | 55% | ~9000 |
| 50–53°C | горячий | 65% | ~10600 |
| 53–56°C | очень горячий | 78% | 12220 |
| ≥ 56°C | **возврат заводской политики** | решает vendor |

Измеренная кривая duty → RPM на PICO A8110:

| duty | 0% | 15% | 20% | 25% | 30% | 35% | 45% | 65% | 78% | 88% |
|---|---|---|---|---|---|---|---|---|---|---|
| RPM | 0 | 3456 | 3488 | 4346 | 5132 | 5973 | 7548 | ~10600 | 12220 | 13671 |

Примерно 3450 RPM — минимальные обороты, на которых вентилятор вообще вращается, поэтому duty ниже ~15% практически равен выключенному.

**Почему T0 = 41°C, а не 38°C.** У PICO 4, лежащего с выключенным экраном, температура кожи составляет 37.5–40°C. Порог 38°C попадает ровно на эту температуру простоя, а первая ступень — 45% (~7500 RPM), что давало мигание 0 ↔ 7500 RPM: вентилятор на неиспользуемом шлеме сам запускался и останавливался каждые несколько минут.

Тихая ступень соответствует заводскому поведению около 36°C (вентилятор выключается).

Последняя ступень намеренно возвращает управление заводской прошивке: когда становится по-настоящему жарко, выход из тестового режима, перезапуск vendor-сервиса и восстановление заводской логики термозащиты безопаснее, чем удержание фиксированного duty этим модулем. Управление возвращается только когда кожа опускается до ступени `HOT` (`OVERHEAT_RELEASE_RANK`, по умолчанию 3) — отдать управление и через пять секунд забрать его обратно лишает смысла всю защиту.

**Истерезис**: ступень растёт сразу при переходе порога, а падает только после падения ниже `порог − ИСТЕРЕЗИС` (по умолчанию 800 мС = 0.8°C). (В v1.2.0 это было описано в документации, но в коде, кроме тихой ступени, не реализовано — параметр ни на что не влиял.)

**Ограничение по RPM, с температурным шлюзом**: если MCU сообщает rpm ≥ `RPM_CAP` (по умолчанию 12000) **и** текущая температурная ступень не ниже `RPM_RELEASE_RANK` (по умолчанию 3 = горячий, т.е. кожа ≥ 50°C), на следующем цикле duty поднимается до `RPM_DUTY` (по умолчанию 88%).

Именно температурный шлюз делает это правило безопасным. Без него правило залипает навсегда, причём так, что при чтении кода это незаметно: rpm ≥ 12000 задаёт duty 88%; при duty 88% вентилятор снова сообщает ≥ 12000 rpm; условие остаётся истинным вечно, а температурная таблица полностью игнорируется. Единственный выход — снизить duty, но для этого rpm уже должен быть ниже порога. Измеренный rpm действительно достигает 13671 при duty 88%, то есть это достижимо в обычной работе, и вентилятор крутился бы почти на максимуме в простое до перезагрузки. Со шлюзом обороты падают, как только кожа возвращается ниже 50°C.

### Настройка

Все пороги и ступени — в `config.cfg` рядом с `service.sh`. Измените, затем:

```sh
# Перечитать config.cfg без перезагрузки модуля:
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh restart"

# Или перезапустите модуль / устройство.
```

Пример `config.cfg` (установленные по умолчанию значения):

```
TIER_QUIET=0   TIER_IDLE=25   TIER_WARM=55   TIER_HOT=65   TIER_VERYHOT=78
T0=41000  T1=47000  T2=50000  T3=53000  T4=56000
HYSTERESIS=800
LOOP_INTERVAL=5
STARTUP_GRACE=45
RPM_CAP=12000
RPM_DUTY=88
RPM_RELEASE_RANK=3
OVERHEAT_RELEASE_RANK=3
RETRY_BACKOFF=3
FAIL_LOG_EVERY=12
```

Файл читается с удалением CR, поэтому сохранять его редактором Windows (Notepad и т.п.), который пишет CRLF, безопасно. Пропущенные ключи берут встроенные значения по умолчанию.

### Использование

После установки модуль автоматически перехватывает вентилятор при загрузке.

Ручное управление (кнопка «Action» в Magisk Manager или из shell):

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"    # duty/об/мин/т-ра/ступень + таблица
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"    # service.sh управляет вентилятором по температуре
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"   # вернуть заводскую политику
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh set 70"    # зафиксировать duty=70% до disable или restart
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh cycle"     # пройти ступени: тихий->свободный->тёплый->горячий->очень->тихий
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh restart"   # перечитать config.cfg (перезапуск service.sh)
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh selftest"  # проверка чистой логики, только чтение
```

Состояние переключателя переживает перезагрузку (v1.3.0): `state/enabled` означает «модуль управляет вентилятором», `state/disabled` — «пользователь выключил модуль». После `disable` модуль не перехватит управление снова при загрузке. `disable` также возвращает вентилятор vendor, а работающий цикл управления завершается сам.

Для возврата к заводскому поведению: отключите или удалите модуль. `stop.sh` выйдет из тестового режима, перезапустит vendor-сервис и вернёт вентилятор заводскому управлению.

### Статус вентилятора в реальном времени

```sh
su -c '/system/bin/gd32ipdclient_test getfaninfo'
# duty=55 rpm=8530 rpm_target=9000 mode=duty mode
```

### Дополнительные ключи (v1.3.0)

Помимо таблицы ступеней, в `config.cfg` есть ключи, которых не было в v1.2.0:

| Ключ | По умолчанию | Значение |
|---|---|---|
| `RPM_RELEASE_RANK` | 3 | Температурная ступень (`0` тихий … `4` очень горячий), начиная с которой правилу RPM разрешено поднимать duty. `3` = только при коже ≥ 50°C. Больше — тише, меньше — больше запаса. |
| `OVERHEAT_RELEASE_RANK` | 3 | Ступень, до которой должна остыть кожа, прежде чем модуль снова возьмёт управление после возврата vendor при перегреве. |
| `RETRY_BACKOFF` | 3 | Пауза в секундах после отклонённой записи duty перед следующей попыткой. |
| `FAIL_LOG_EVERY` | 12 | Ограничение логов: из N подряд неудачных записей логируется только одна (первая — всегда). |

Чтобы последняя ступень держала фиксированные 90% вместо возврата vendor, замените `exit_test_mode` на `set_duty 90` в ветке перегрева главного цикла и уберите там работу с `IN_TEST` — но тогда вы теряете заводскую термозащиту.

### Самотест

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/service.sh --selftest"
```

Прогоняет лестницу ступеней, истерезис и RPM-шлюз как чистую логику во временном каталоге состояния. Вентилятора и реального узла температуры не касается, поэтому запускать можно в любой момент. Удобно, чтобы заранее увидеть, как поведёт себя конкретный `config.cfg`. `action.sh selftest` — то же самое.

### Примечания

1. **Требуется root.** `gd32ipdclient_test` общается с root-only binder-сервисом; обычный shell его не двигает.
2. **Неофициальный метод.** Используется заводская тестовая программа `gd32ipdclient_test`; публичного интерфейса нет. Обновления прошивки могут изменить пути или параметры. Скрипты gracefully деградируют при отсутствии инструмента или узла температуры, но не принудительно блокируют вентилятор — при невозможности получить управление они выходят и отдают контроль vendor.
3. **Vendor-сервис всегда работает.** Он никогда не убивается. Его логика защиты от перегрева активируется снова на последней ступени. При обычных температурах вы просто будете холоднее.
4. **Потолок оборотов:** при duty 88% измерено 13671 RPM; duty=100% даёт ~12500 RPM. Шум заметно растёт выше duty ~85%.
5. **Удаление возвращает заводское.** Ручная очистка не нужна; `stop.sh` выходит из тестового режима и перезапускает vendor-сервис.
6. **Автоперехват при перезагрузке**, если вы не отключали модуль через `action.sh disable` — эта команда пишет `state/disabled`, и флаг сохраняется между перезагрузками.
7. **Переводы строк важны.** Android sh не считает CR пробельным символом: `service.sh` с CRLF падает на каждой строке (наблюдалось `service.sh[44]: : inaccessible or not found`, модуль полностью мёртв), а `config.cfg` с CRLF добавляет лишний CR в каждое значение. В репозитории есть `.gitattributes` с принудительным LF, `customize.sh` нормализует при установке, а `config.cfg` читается с удалением CR.
8. **Главный признак проблемы — молчание модуля.** Цикл пишет в лог только при смене состояния, поэтому здоровая система тихая. Если лог заполняется строками об отказах, выполните `action.sh status` и `service.sh --selftest`: они показывают, действительно ли модуль удерживает тестовый режим MCU, а не предполагают это.

### Файлы

| Файл | Назначение |
|---|---|
| `module.prop` | Метаданные Magisk-модуля |
| `customize.sh` | Установка прав и нормализация переводов строк при установке |
| `service.sh` | Главный цикл: ступенчатое управление по температуре (плюс `--selftest`) |
| `stop.sh` | Выход из тестового режима и возврат заводской политики при удалении |
| `action.sh` | Ручное включение/выключение / статус / самотест |
| `config.cfg` | Пороги и значения duty по ступеням |
| `CHANGELOG.md` | История версий и список исправлений v1.3.0 |
| `.gitattributes` | Принудительный LF для скриптов и конфигурации |

### Благодарности

Ключевой механизм блокировки (`setfantestmode`) обнаружен через [Seva167/PicoFanControl](https://github.com/Seva167/PicoFanControl). Тот проект выполняет только ручное управление скоростью (минимум 50%, без обратной связи по температуре, без обработки пути разблокировки). Этот модуль добавляет ступенчатое управление по температуре кожи, полный диапазон 0–100%, возврат при перегреве и автоматический перехват при загрузке через Magisk.

---

## Open Source / 开源 / Открытый исходный код

This project is open source under the **MIT License**. See [LICENSE](LICENSE).

Forks, issues, and pull requests are welcome. The code targets a rooted PICO 4 (SM8650 / kona, model A8110); other PICO hardware may differ in the GD32 MCU firmware and is not tested.

本项目以 **MIT 许可证**开源。欢迎 fork、提 issue、提交 PR。代码针对越狱的 PICO 4（SM8650 / kona，型号 A8110）开发；其他 PICO 机型的 GD32 MCU 固件可能不同，未测试。

Проект распространяется по лицензии **MIT**. Fork, issues и pull requests приветствуются. Код написан для PICO 4 с root (SM8650 / kona, модель A8110); прошивки GD32 MCU других моделей PICO могут отличаться и не тестировались.
