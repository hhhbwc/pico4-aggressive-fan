# Contributing

This project is open source under the MIT License. Contributions are welcome.

## Issues

If you hit a bug, open an issue with:
- PICO 4 firmware version (`getprop ro.build.fingerprint`)
- Magisk version
- `su -c '/system/bin/gd32ipdclient_test getfaninfo'` output
- logcat snippet: `su -c 'logcat -d | grep -iE "PicoFanTC|gd32|FanControl"'`

## Pull requests

Targeted changes are preferred: threshold tweaks, tier additions, UI improvements. Big rewrites please open an issue first.

Run `sh -n service.sh stop.sh action.sh customize.sh` before pushing to confirm the shell scripts still parse.
