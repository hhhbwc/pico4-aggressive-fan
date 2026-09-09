#!/system/bin/sh
# Magisk module customise script
[ "$MODPATH" ] || exit 1

# Ensure the tool ships with the right permissions. Magisk may preserve the
# source timestamps but permissions must be enforced at install time.
chmod 755 "$MODPATH/service.sh" 2>/dev/null
chmod 755 "$MODPATH/stop.sh" 2>/dev/null
chmod 755 "$MODPATH/action.sh" 2>/dev/null

ui_print "- PICO 4 Fan Auto Temp Control v1.1.0"
ui_print "- 风扇自动温控模块已安装"

exit 0
