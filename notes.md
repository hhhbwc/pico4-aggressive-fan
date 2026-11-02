# PICO 4 Fan Auto Temp Control v2.0.0

**安装包**：`pico4_fan_tempcontrol-v2.0.0.zip`（Magisk 直接刷入）

## v2.0.0

2026-11-02，重写控制方式。本版解决的是「控制权老是被原厂抢走」这个老问题。

### Changed

**停掉原厂服务，改用它自己的正常接口调速。**

原厂的风扇策略只在一个 init 服务 `pxrfanservice` 里。v1.x 用的是 PICO 出厂测试程序那套命令，
靠 MCU 锁把原厂的 duty 帧拒掉：

```sh
gd32ipdclient_test setfantestmode 1      # v1.x：把 MCU 锁住
gd32ipdclient_test setfantestspeed 55
```

这把锁很脆。原厂 `PxrFanService` 的日志显示它在 `system_screen_on/off`、
`system_vrmode_start/stop` 时会做 reset，并且每 10 秒左右就重写一次自己的 duty（`fanState=35`）。
MCU 的锁一掉，原厂的下一帧就赢，模块再花一个漂移周期重建 test mode——这就是「老被抢」。

而原厂本来就有**正常通路**：`gd32ipdclient_test setfanspeed N` 走的是
`gd32ipdservice.SetFanSpeed`，和 `pxrfanservice` 自己用的是同一个接口。作者实测对比：

| | v1.x test mode | v2.0.0 停原厂 + `setfanspeed` |
|---|---|---|
| 原厂服务 | 一直跑，每 ~10 秒写一次 | 接管时停一次 |
| duty 保持 | MCU 锁一掉就被拒 | 稳定 |
| 原厂重启（开关屏） | 会重写自己的 duty | watchdog 再次停掉它 |
| 被抢后要做什么 | ~15 秒重建 test mode | 不用——没有竞争者 |

现在模块在接管时停掉 `pxrfanservice`（`setprop ctl.stop pxrfanservice`；模块进程在
`u:r:magisk:s0`，本机 SELinux 是 Permissive，实测可用），再用 `setfanspeed` 写 duty。
**没有 MCU 锁，就没有可丢的东西，也没有要重建的东西。**

实机验证：停掉原厂后 duty 80% 稳定保持 90 秒（12600–12900 RPM）；30%、0% 立即响应；
开关屏不会把原厂拉回来；满载时模块在原厂全程停着的情况下走完 0% → 25% → 88%，
并稳定在 88% / ~13400 RPM。

**停不掉或接口被拒时自动回退。**
如果 `pxrfanservice` 停不掉、或者 `setfanspeed` 被拒，模块自动退回 v1.x 的 test mode 通路，
保证任何时候都有东西在管风扇。当前用的通路记在 `state/ctrl_mode`（`vendor` / `test`），
`action.sh status` 会显示。新增配置键 `VENDOR_STOP`（默认 `1`），设成 `0` 可强制回到旧行为。

**新增 `watchdog.sh`：风扇绝不会被丢下不管。**
停了原厂就意味着守护一旦崩掉，风扇会停在最后的 duty 上而没人管。`watchdog.sh` 每 5 秒检查一次，
专门补上守护自身 `EXIT` trap 管不到的情况——`service.sh` 被 `kill -9` 打死。它会重启
`pxrfanservice`、清掉接管标记，然后退出。

实机验证：`kill -9` 打死守护后，watchdog 在约 5 秒内把原厂拉了回来
（`watchdog: service.sh is gone but fan is still owned, restoring vendor`），风扇回到原厂自己的
duty（50% / ~8550 RPM），接管标记被清掉。系统在模块接管期间把原厂拉起来时，watchdog 也会
再停一次。

其余退出路径本来就会恢复原厂：`action.sh disable`、卸载（`stop.sh`）、连续
`MAX_FAIL_STREAK` 次写失败后放弃、守护的 `EXIT` trap。

**`stop.sh` 现在也会杀 watchdog。**
以前卸载只杀守护，watchdog 会残留；它看到接管标记没了最多 5 秒后自己退出，现在改成显式杀掉。

### Fixed

**watchdog 会把手动固定顶掉。**
`action.sh set` 和 `action.sh cycle` 都会**故意**停掉 `service.sh`（否则守护会按温度把
用户要的固定值覆盖掉）。但 v2.0.0 新加的 watchdog 看到「接管标记还在、守护没了」就当成
守护崩溃，于是把风扇交回原厂 —— 固定值只维持了几秒。实测：`action.sh set 60` 打印
「已固定 duty=60%」，风扇到 60% / ~9300 RPM，几秒后 watchdog 把原厂拉回来，duty 掉回 0%。

现在用新的 `state/hold` 标记区分这两种情况：`set` / `cycle` 在停守护**之前**写下它，
watchdog 就知道守护是故意停的，改为守住这个 duty 而不是交回原厂；原厂服务被系统拉起来时
也会再停一次，duty 被抢走就写回去。实机验证：`set 60` 稳定保持 60% / ~9350 RPM；手动重启
原厂服务后被再次停掉并补写了 duty（`watchdog: held duty 60 lost (fan at 0), re-asserting`）。
`cycle` 同样守住它切到的档位，`action.sh enable` 会清掉这个标记并恢复温控。

**`pkill -f` 可能误杀用户自己的 shell。**
`action.sh` 和 `stop.sh` 原来用 `pkill -f "$SVC"` 作兜底。这是子串匹配，任何命令行里
**提到**这个路径的进程都会被杀 —— 包括执行命令的那条 `adb shell`。实测两次：shell 被
SIGTERM（exit 143），`pkill -9` 那次直接被 SIGKILL（exit 137）。

现在改成按进程 argv 匹配：只有当脚本路径是进程自己的参数时才杀（真正的守护符合，
只是「提到」这个路径的 shell 不符合）。实机验证通过。

### 极限温度压力测试

作者设备（PICO A8110）8 线程满载、每 5 秒采样一次，126 个采样点、约 11 分钟：

| 项 | 结果 |
|---|---|
| duty | 连续 108 个采样点稳在 88%（过热档） |
| RPM | 13300–13407 |
| CPU（最热热区） | 峰值 94.6–95.4°C —— **已过 PICO 自己的 90°C 告警线** |
| 皮肤模型 | 稳态 ~50.3°C |
| 充电 IC | ~49.7°C |
| 原厂服务 | 全程 `stopped`，`PxrFanService` 根本没运行过（日志只有 2 行） |
| 守护 / watchdog PID | 全程不变（15180 / 8705），两个进程一次都没重启 |
| 硬件 duty vs 模块意图 | 126 个采样点里只有 1 个不一致，且是升档过程中的瞬态 |
| 档位阶梯 | 单调无抖动：安静 → 空闲 → 很热 → 过热 |

还在满载中反复开关屏（`input keyevent 26`，实测 `mWakefulness` 在 Awake/Asleep 之间真的翻转），
每次开关屏 duty 都保持 88% —— 因为停掉原厂后，原厂那条「reset 路径」根本不存在了。

**一个需要知道的传感器特性（不是 bug）**：CPU 热区读数是**逐核**的，最热的核一空闲，读数
会在 5 秒内掉 40+°C（实测 +42.5°C / −43.6°C）。所以负载突变时 duty 会在 0%↔88% 之间跳 ——
那是**读数本身在跳**，不是模块在抖。判断稳不稳要看**同样负载下**档位是否单调。

### Added

- 新配置键 `VENDOR_STOP`（0/1，默认 1）。
- 新文件 `watchdog.sh`，`customize.sh` 会一并安装并加执行权限。
- `action.sh status` 现在会显示当前控制方式（`厂商服务已停 + setfanspeed` 或
  `MCU test mode (回退)`），以及实时的 `vendor=running|stopped`。
- `--selftest` 新增 [15]：控制方式 → duty 命令的映射（`vendor` → `setfanspeed`，
  `test` → `setfantestspeed`）。

### 未改动

温度侧一切照旧：三路温度源（皮肤 / 充电 IC / CPU-SoC）、档位阶梯与各档 duty、回滞、
熄屏压档、RPM 闸门、升档平滑、配置校验。README 里的档位、阈值和实测 RPM 数据没有变化。

### 升级提示

- 刷 release zip 会整个替换模块目录，包括 `config.cfg`。自定义过的先备份。
- 升级后模块会先退出 v1.x 可能残留的 MCU test mode 再接管，否则 `setfanspeed` 会被拒。

## v1.7.0

2026-11-02，收到 v1.6 用户反馈（VirtualDJ）：CPU 90°C 时风扇只有 8500 RPM，升速太慢，
体感比旧版更差。

### Fixed

**只看皮肤模型，不看 CPU。**
`zone86` 是虚拟模型量，明显滞后：同一份 dump 里最热 CPU 热区 83.7°C，而它只有 73.8°C。
用户实测 CPU 90°C 时风扇仅 8500 RPM，正好是皮肤 63–65°C 对应的 WARM 55% 档。而 PICO 的 `ChipsetWarnManager` 在 90°C（`0x15f90`）就告警，
读的正是 zone 1–4/7–10/11。现在把 CPU 热区取最大值作为第三温度源（默认
78/81/84/87/90°C → 25/55/65/78/88%），档位 = 皮肤/充电 IC/CPU 三者最高档；CPU 90°C
时给 88%（约 13600 RPM），78°C 就开始升速。

降档要求三路都凉下来（CPU 回滞 2°C）；熄屏压档的「真烫」豁免也加入 CPU ≥ 87°C。
坏节点/负值自动跳过。`CPU_ENABLE=0` 可退回 v1.6 的双源行为。

**`action.sh restart` 每次都误报「重启失败」。**
`service.sh` 原来要等 `boot_completed` + `STARTUP_GRACE`（45 秒）才写 `state/service.pid`，
而 `action.sh restart` 只等 8 秒，于是手动重启必然打印失败、其实进程正在启动。本版实机测试
时踩到；现在 pid 在宽限期之前注册，restart 约 1 秒即可确认。

**单核尖峰会把档位一次性顶上去。**
多源取最大后，最热的核能在 1 秒内从 70°C 跳到 82°C，而原来升档是跨阈值立即执行，
于是负载没变的情况下档位会在一分钟内走 25% → 55% → 78% → 88% 再掉回来。现在
升档要求连续 `UPSHIFT_CONFIRM` 个循环（默认 2，约 5 秒）都高于当前档位；降档和回滞
不变，开机后的第一次决策不做平滑，`UPSHIFT_CONFIRM=1` 可恢复立即升档。

**`log()` 的兜底输出会污染函数返回值。**
`/system/bin/log` 不存在时兜底用 echo 写 stdout，而 `$(pick_tier)`、`$(get_rpm)` 这类
调用把 stdout 当返回值，于是档位名会变成 `PicoFanTC: ...`，档位比较全部静默失效。
现在兜底改写 stderr。这是跑自检时暴露出来的。

**配置文件校验是黑名单，`|` / `>` 可注入。**
旧逻辑只拦 `$`、反引号、`;`、`&`，`T0=1|reboot` 会走到 `eval` 并把右侧当管道执行——
用户可编辑文件即 root 任意命令。改成按类型白名单：数值键只允许数字和前置负号，
`CPU_ZONES` 只允许数字和逗号，其它整行丢弃。

**`config.cfg` 不是普通文件时守护会挂死。**
`[ -r ]` 对目录也为真，而 `tr -d '
' < 目录` 会一直循环（EISDIR）。实测设备上留下
两个 100% CPU 的 `tr`，`--dumpcfg` 永不返回。现在两个脚本都先用 `[ -f ]` 判断。

### Added

- 新键 `CPU_ENABLE`、`CPU_ZONES`、`CPU0..CPU4`、`CPU_HYSTERESIS`、`UPSHIFT_CONFIRM`。
- `--selftest` 新增 [13]：zone 取最大、坏节点跳过、CPU 触发过热、CPU 回滞、
  `CPU_ENABLE=0`、熄屏豁免；新增 [14]：升档确认、尖峰作废、降档不等、关闭开关。
- `action.sh status` 同时显示皮肤/充电 IC/CPU 三路温度。
- 控制循环日志改为三路温度摘要（`skin 65C chg 45C cpu 88C`）。

### 实测数据（本机，PICO A8110）

| 热区 | 温度 |
|---|---|
| cpu-0-0-usr (zone1) | 83.7°C |
| cpu-1-3-usr | 84.5°C |
| cpuss-1-usr | 82.9°C |
| gpuss-max-step (zone25) | 81.8°C |
| skin-msm-therm-usr (zone86) | 73.8°C |

同一时刻皮肤仍低 10°C 左右，这正是 v1.6 在 CPU 90°C 时只给 55% 的原因。

### 实机验证（2026-11-02，A8110）

- 设备 mksh 下 `sh -n`、`--dumpcfg`、`--selftest`（含 [13]）全部通过。
- 8 核满载：最热 CPU 热区 94–95°C → OVERHEAT 88%，RPM 12465→13656；同一窗口皮肤只有
  52–57°C，v1.6 两源逻辑会停在 IDLE 25%（约 4800 RPM）——用户反馈的问题原始复现并修正。
- 撤负载：CPU 87°C → VERYHOT 78% / 12220 RPM，随后逐档回落；熄屏时 CPU 85°C、皮肤
  58°C 仍按设计压到 IDLE 25%。
- 醒着、VR 桌面运行：CPU 最高 79–82°C → IDLE 25%。逐秒采样显示 cluster 0 在 67–70°C，
  `cpu-1-3-usr`（zone 10）会尖峰到 82°C，所以最大值通常由单核决定 —— 这也是加升档
  平滑的原因。

---

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

**6. `--selftest` 的阶梯用例在夹具就绪前读取了设备真实 mWakefulness。**
设备当时在睡眠态 → 命中新增的熄屏压档 → 中间档位被压成 IDLE
（`63000 -> IDLE`、`67000 -> IDLE`），只有皮肤 ≥ T4 的用例豁免才对。
现在自检先把夹具置为 `Awake` 再跑。真机复验：
`63000->WARM / 65000->HOT / 67000->VERYHOT / 69000->OVERHEAT`，
回滞 `66199->HOT`、`64199->WARM`。模块运行逻辑不受影响。

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

### 鲁棒性测试（2026-11-02）

隔离测试台（假 MCU 工具、假温度节点、假 getprop/setprop/dumpsys、独立 state 目录）
95 项全部通过：

- 配置模糊：空文件、垃圾行、注入载荷、极端值、非单调阈值、`CPU_ZONES` 畸形/40 项/前导零、
  CRLF、行内注释、重复键、`config.cfg` 被换成目录。
- 传感器模糊：皮肤/充电 IC/CPU 热区缺失、空、`-22`、非数字、999999；自动退回其余源或
  报无数据，不崩。
- 工具生命周期：持续失败（达到 `MAX_FAIL_STREAK` 后放弃并交还原厂）、挂起（看门狗强杀、
  循环存活）、乱输出、双实例（第二个退出）、陈旧 pid（被替换）。
- 真机故障注入：满载时 `setfantestmode 0`（原厂接管到 50%，模块重下发被拒后重建
  test mode，32 秒恢复 88%）；`kill -9` 守护后 `action.sh restart` 立即恢复。

---

> 升级提示：皮肤阈值已重标定为 57/63/65/67/69（旧 41/47/50/53/56 在本机会让风扇整天满转）。若你改过 `config.cfg`，请对照新默认值合并。
