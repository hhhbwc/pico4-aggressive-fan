# PICO 4 Aggressive Fan Control (更激进的风扇转速)

**English** | [中文](#中文) | [Русский](#русский)

---

A Magisk module that replaces PICO 4's stock fan curve with a skin-temperature stepped curve, one tier higher. Uses GD32 MCU test mode to bypass the stock 35% duty lock — the vendor service (`pxrfanservice`) stays running untouched.

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

| Skin temp | duty | Measured RPM |
|---|---|---|
| < 47°C | 45% | 7599 |
| 47–50°C | 55% | 8972 |
| 50–53°C | 65% | 10287 |
| 53–56°C | 78% | 11815 |
| ≥ 56°C | **hand back to stock policy** | vendor decides |

The last tier deliberately hands control back to the stock firmware: when it gets genuinely hot, exiting test mode, restarting the vendor service, and restoring its thermal-protection logic is safer than this module holding a fixed duty. You can change it to a fixed 90% instead — see "Tuning" below.

Thresholds and tiers are variables at the top of `service.sh`; change them and reboot the module.

### Usage

After install, the module takes over the fan automatically on boot.

Manual control (Magisk Manager "Action" button, or from shell):

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"   # status
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"   # enable
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"  # restore stock
```

The switch state is written to `state/enabled` and survives reboot.

To restore stock behaviour: disable or uninstall the module. `stop.sh` exits test mode, restarts the vendor service, and returns the fan to stock control.

### Real-time fan status

```sh
su -c '/system/bin/gd32ipdclient_test getfaninfo'
# duty=55 rpm=8530 rpm_target=9000 mode=duty mode
```

### Tuning

Edit the top of `service.sh`:

```sh
TIER_IDLE="45"       # < 47°C
TIER_WARM="55"       # 47-50°C
TIER_HOT="65"        # 50-53°C
TIER_VERYHOT="78"    # 53-56°C

T1=47000   # idle -> warm
T2=50000   # warm -> hot
T3=53000   # hot -> very hot
T4=56000   # very hot -> hand back to vendor
LOOP_INTERVAL=5      # loop interval (seconds)
STARTUP_GRACE=45     # how long to wait after boot before taking over
```

To make the overheat tier hold a fixed 90% instead of handing back to the vendor, change `exit_test_mode` to `set_duty 90` in the `main` loop's overheat branch, and remove the `TIER_OVERHEAT` exit logic.

### Notes

1. **Root required.** `gd32ipdclient_test` talks to a root-only binder service; a plain shell cannot drive it.
2. **Unofficial method.** Uses PICO's factory test program; no public interface is exposed. Firmware updates may change the paths or parameters. The scripts degrade gracefully if the tool or the temp node is missing, but they will not force-lock the fan — if they cannot get control, they exit and let the vendor take over.
3. **Vendor service always runs.** It is never killed. Its high-temp protection logic re-activates at the overheat tier. Under normal temperatures you will just be cooler.
4. **Fan speed ceiling:** duty=100% measures ~12500 RPM. Noise rises noticeably above duty ~85%.
5. **Uninstall restores stock.** No manual cleanup needed; `stop.sh` exits test mode and restarts the vendor service.
6. **Auto-takeover on reboot** (unless you disabled it with `action.sh disable` previously). On reboot the module checks the `state/enabled` and `state/in_test` flags to handle power-loss and abnormal-exit residual state.

### Files

| File | Purpose |
|---|---|
| `module.prop` | Magisk module metadata |
| `customize.sh` | Set permissions at install |
| `service.sh` | Main loop: stepped fan control by temperature |
| `stop.sh` | Exit test mode and restore stock policy on uninstall |
| `action.sh` | Manual enable/disable / status |

### Credit

The core locking mechanism (`setfantestmode`) was discovered via [Seva167/PicoFanControl](https://github.com/Seva167/PicoFanControl). That project does manual speed control only (min 50%, no temperature feedback, does not handle the unlock path). This module adds skin-temperature stepped control, full 0–100% range, overheat handback, and automatic boot takeover via Magisk.

### Troubleshooting

#### EDL 9008 not visible on Windows

This module does not flash the device — it runs on a rooted system via Magisk. So EDL is only needed if you want to back-flash a stock boot image, install Magisk into a partition, or recover a bricked device. If you do need EDL:

- The PICO 4 in EDL mode enumerates as USB **VID:PID 05c6:9008** (Qualcomm 9008, "Android Bootloader").
- Stock Windows does not ship an INF for this. The device shows as "Unknown device" or under the wrong class, and flashing tools (QFIL, EDLFlash, Firehose) cannot see the port.
- Fix: rebind the port to **WinUSB** using [zadig.exe](https://zadig.akeo.ie/). Open zadig, *Device → List All Devices*, find `05c6:9008`, install WinUSB.
- A helper script is included: `powershell -ExecutionPolicy Bypass -File .\diag_windows_edl.ps1` lists any EDL-class device and the driver bound to it; add `-Fix` to attempt a rebind.

If you cannot see the port at all even after rebind, try a different USB cable / port, or re-enter EDL with `fastboot oem edl` (requires unlocked bootloader and root).

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

| 皮肤温度 | duty | 实测 RPM |
|---|---|---|
| < 47°C | 45% | 7599 |
| 47–50°C | 55% | 8972 |
| 50–53°C | 65% | 10287 |
| 53–56°C | 78% | 11815 |
| ≥ 56°C | **交回原厂策略** | 由原厂决定 |

最后一档故意把控制权还给原厂：温度真的过高时，退出测试模式、重启 vendor 服务、恢复原厂降频保护逻辑，比本模块死守一个 duty 安全。要改成固定 90% 也可以，见下方「调整」。

阈值和档位都在 `service.sh` 顶部的变量里，改完重启模块即可生效。

### 使用方法

安装后模块开机自动接管风扇。

手动控制（Magisk 管理器的「操作」按钮，或直接进 shell）：

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"   # 看当前状态
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"   # 开启本模块温控
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"  # 恢复原厂温控
```

开关状态会写入 `state/enabled`，重启后按上次选择恢复。

恢复出厂行为：禁用或卸载模块即可，`stop.sh` 会自动退出测试模式、重启 vendor 服务，把风扇还给原厂。

### 查看风扇实时状态

```sh
su -c '/system/bin/gd32ipdclient_test getfaninfo'
# duty=55 rpm=8530 rpm_target=9000 mode=duty mode
```

### 调整阈值和档位

编辑 `service.sh` 顶部：

```sh
TIER_IDLE="45"       # < 47°C
TIER_WARM="55"       # 47-50°C
TIER_HOT="65"        # 50-53°C
TIER_VERYHOT="78"    # 53-56°C

T1=47000   # idle -> warm
T2=50000   # warm -> hot
T3=53000   # hot -> very hot
T4=56000   # very hot -> 交回原厂
LOOP_INTERVAL=5      # 循环间隔（秒）
STARTUP_GRACE=45     # 开机后等多久再接管
```

想让过热档也固定成 90% 而不是交回原厂，把 `main` 循环里过热分支的 `exit_test_mode` 改成 `set_duty 90`，并去掉 `TIER_OVERHEAT` 相关的退出逻辑。

### 注意事项

1. **需要 root**。`gd32ipdclient_test` 走的是 root-only 的 binder 服务，普通 shell 调不动。
2. **非官方方案**。走的是出厂测试程序 `gd32ipdclient_test`，PICO 没暴露公开接口。理论上固件升级后路径或参数可能变。脚本对工具缺失和温度节点缺失有降级处理，但不会强行锁住风扇——拿不到控制权就退出，让原厂接手。
3. **vendor 服务始终运行**，不会被杀掉。它的高温保护逻辑在过热档会重新生效。日常温度下你只会更凉快。
4. **风扇转速上限**：duty=100% 实测 ~12500 RPM。duty 超过 ~85% 噪音明显上升。
5. **卸载即恢复**。不用手动清理，`stop.sh` 会退出测试模式并重新拉起 vendor 服务。
6. **重启后自动接管**（除非你之前用 action.sh disable 关过）。模块重启时会先检查 `state/enabled` 和 `state/in_test` 标志，处理掉掉电、异常退出的残留状态。

### 文件清单

| 文件 | 作用 |
|---|---|
| `module.prop` | Magisk 模块元信息 |
| `customize.sh` | 安装时设置权限 |
| `service.sh` | 主循环：按温度分档控风扇 |
| `stop.sh` | 卸载时退出测试模式、恢复原厂策略 |
| `action.sh` | 手动开关 / 状态查询 |

### 致谢

核心锁定机制（`setfantestmode`）是通过 [Seva167/PicoFanControl](https://github.com/Seva167/PicoFanControl) 发现的。该项目只做手动调速（最低 50%、无温度反馈、不处理解锁路径）。本模块增加了皮肤温度分档控制、0–100% 全范围、过热交回、以及通过 Magisk 开机自动接管。

### 故障排查

#### Windows 上找不到 EDL 9008 端口

本模块不刷设备——它是 Magisk 模块，跑在已 root 的系统上。所以只有在你想要回刷官方 boot 镜像、把 Magisk 装到分区、或恢复变砖设备时才会用到 EDL。如果你确实需要 EDL：

- PICO 4 进 EDL 模式后枚举为 USB **VID:PID 05c6:9008**（Qualcomm 9008，"Android Bootloader"）。
- Windows 默认不附带这个 VID 的 INF。设备显示成「未知设备」或归到错误的类别下，刷机工具（QFIL、EDLFlash、Firehose）看不到这个端口。
- 解决：用 [zadig.exe](https://zadig.akeo.ie/) 把端口重绑定为 **WinUSB**。打开 zadig，*设备 → 列出所有设备*，找到 `05c6:9008`，安装 WinUSB。
- 仓库里附了辅助脚本：`powershell -ExecutionPolicy Bypass -File .\diag_windows_edl.ps1` 列出所有 EDL 类设备和它们当前绑定的驱动；加 `-Fix` 参数可尝试自动重绑定。

如果重绑后还是看不到端口，换 USB 线/换 USB 口试试，或者用 `fastboot oem edl` 重新进 EDL（需要先解锁 bootloader 且有 root）。

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

| Т-ра кожи | duty | Измеренные RPM |
|---|---|---|
| < 47°C | 45% | 7599 |
| 47–50°C | 55% | 8972 |
| 50–53°C | 65% | 10287 |
| 53–56°C | 78% | 11815 |
| ≥ 56°C | **возврат заводской политики** | решает vendor |

Последняя ступень намеренно возвращает управление заводской прошивке: когда становится по-настоящему жарко, выход из тестового режима, перезапуск vendor-сервиса и восстановление заводской логики термозащиты безопаснее, чем удержание фиксированного duty этим модулем. Можно изменить на фиксированные 90% — см. «Настройка» ниже.

Пороги и ступени — переменные в начале `service.sh`; измените и перезапустите модуль.

### Использование

После установки модуль автоматически перехватывает вентилятор при загрузке.

Ручное управление (кнопка «Action」в Magisk Manager или из shell):

```sh
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh status"   # статус
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh enable"   # включить
su -c "sh /data/adb/modules/pico4_fan_tempcontrol/action.sh disable"  # вернуть заводское
```

Состояние переключателя записывается в `state/enabled` && переживает перезагрузку.

Для возврата к заводскому поведению: отключите или удалите модуль. `stop.sh` выйдет из тестового режима, перезапустит vendor-сервис и вернёт вентилятор заводскому управлению.

### Статус вентилятора в реальном времени

```sh
su -c '/system/bin/gd32ipdclient_test getfaninfo'
# duty=55 rpm=8530 rpm_target=9000 mode=duty mode
```

### Настройка

Редактируйте начало `service.sh`:

```sh
TIER_IDLE="45"       # < 47°C
TIER_WARM="55"       # 47-50°C
TIER_HOT="65"        # 50-53°C
TIER_VERYHOT="78"    # 53-56°C

T1=47000   # idle -> warm
T2=50000   # warm -> hot
T3=53000   # hot -> very hot
T4=56000   # very hot -> возврат vendor
LOOP_INTERVAL=5      # интервал цикла (секунды)
STARTUP_GRACE=45     # сколько ждать после загрузки
```

Чтобы последняя ступень держала фиксированные 90% вместо возврата vendor, замените `exit_test_mode` на `set_duty 90` в ветке перегрева главного цикла и удалите логику выхода `TIER_OVERHEAT`.

### Примечания

1. **Требуется root.** `gd32ipdclient_test` общается с root-only binder-сервисом; обычный shell его не двигает.
2. **Неофициальный метод.** Используется заводская тестовая программа `gd32ipdclient_test`; публичного интерфейса нет. Обновления прошивки могут изменить пути или параметры. Скрипты gracefully деградируют при отсутствии инструмента или узла температуры, но не принудительно блокируют вентилятор — при невозможности получить управление они выходят и отдают контроль vendor.
3. **Vendor-сервис всегда работает.** Он никогда не убивается. Его логика защиты от перегрева активируется снова на последней ступени. При обычных температурах вы просто будете холоднее.
4. **Потолок оборотов:** duty=100% даёт ~12500 RPM. Шум заметно растёт выше duty ~85%.
5. **Удаление возвращает заводское.** Ручная очистка не нужна; `stop.sh` выходит из тестового режима и перезапускаet vendor-сервис.
6. **Автоперехват при перезагрузке** (если вы не отключали через `action.sh disable` раньше). При перезагрузке модуль проверяет флаги `state/enabled` и `state/in_test`, чтобы обработать остаточное состояние после сбоя питания или аномального завершения.

### Файлы

| Файл | Назначение |
|---|---|
| `module.prop` | Метаданные Magisk-модуля |
| `customize.sh` | Установка прав при установке |
| `service.sh` | Главный цикл: ступенчатое управление по температуре |
| `stop.sh` | Выход из тестового режима и возврат заводской политики при удалении |
| `action.sh` | Ручное включение/выключение / статус |

### Благодарности

Ключевой механизм блокировки (`setfantestmode`) обнаружен через [Seva167/PicoFanControl](https://github.com/Seva167/PicoFanControl). Тот проект выполняет только ручное управление скоростью (минимум 50%, без обратной связи по температуре, без обработки пути разблокировки). Этот модуль добавляет ступенчатое управление по температуре кожи, полный диапазон 0–100%, возврат при перегреве и автоматический перехват при загрузке через Magisk.

### Устранение неполадок

#### Порт EDL 9008 не виден в Windows

Этот модуль не прошивает устройство — это Magisk-модуль, работающий в root-системе. Так что EDL нужен только если вы хотите переписать заводской boot-образ, установить Magisk в раздел или восстановить «кирпич». Если EDL нужен:

- PICO 4 в режиме EDL отображается как USB **VID:PID 05c6:9008** (Qualcomm 9008, "Android Bootloader").
- Стандартная поставка Windows не содержит INF для этого VID. Устройство показывается как «Неизвестное устройство» или в неправильном классе, и прошивочные утилиты (QFIL, EDLFlash, Firehose) не видят порт.
- Решение: перепривязать порт к **WinUSB** через [zadig.exe](https://zadig.akeo.ie/). Откройте zadig, *Устройство → Список всех устройств*, найдите `05c6:9008`, установите WinUSB.
- В репозитории есть вспомогательный скрипт: `powershell -ExecutionPolicy Bypass -File .\diag_windows_edl.ps1` — выводит все EDL-устройства и их текущие драйверы; флаг `-Fix` пытается перепривязать автоматически.

Если порт так и не появляется после перепривязки, попробуйте другой USB-кабель/порт или повторите вход в EDL через `fastboot oem edl` (нужны разблокированный bootloader и root).

---

## Open Source / 开源 / Открытый исходный код

This project is open source under the **MIT License**. See [LICENSE](LICENSE).

Forks, issues, and pull requests are welcome. The code targets a rooted PICO 4 (SM8650 / kona, model A8110); other PICO hardware may differ in the GD32 MCU firmware and is not tested.

本项目以 **MIT 许可证**开源。欢迎 fork、提 issue、提交 PR。代码针对越狱的 PICO 4（SM8650 / kona，型号 A8110）开发；其他 PICO 机型的 GD32 MCU 固件可能不同，未测试。

Проект распространяется по лицензии **MIT**. Fork, issues и pull requests приветствуются. Код написан для PICO 4 с root (SM8650 / kona, модель A8110); прошивки GD32 MCU других моделей PICO могут отличаться и не тестировались.
