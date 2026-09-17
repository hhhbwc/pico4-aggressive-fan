# Changelog

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
assignment——

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
