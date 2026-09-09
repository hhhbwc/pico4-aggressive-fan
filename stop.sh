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
TOOL="/system/bin/gd32ipdclient_test"

if [ -f "$STATE_DIR/in_test" ]; then
    $TOOL setfantestmode 0 >/dev/null 2>&1
    setprop sys.pxrfanservice.state 2 2>/dev/null
fi

# Belt and braces: make sure the vendor service is up even if the flag is
# stale or missing, so an uninstall can never leave the fan with nobody in
# control of it.
if [ "$(getprop init.svc.pxrfanservice 2>/dev/null)" != "running" ]; then
    setprop sys.pxrfanservice.state 1 2>/dev/null
fi

rm -rf "$STATE_DIR" 2>/dev/null

/system/bin/log -t "PicoFanTC" "module stopped, vendor fan policy restored" 2>/dev/null

exit 0
