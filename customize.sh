#!/system/bin/sh
# Magisk module customise script
[ "$MODPATH" ] || exit 1

# ---------------------------------------------------------------------------
# 1) 行尾符归一化
#
# Android 的 sh 不把 CR 当空白字符，CRLF 的脚本会彻底失效：
#   tier=$(pick_tier)\r        -> tier="IDLE\r"
#   case "$tier" in IDLE) ...  -> 匹配不上，控制逻辑静默失效
# 实测 CRLF 版 service.sh 在设备上每行赋值都报 "inaccessible or not found"。
#
# Windows 上 git 默认 core.autocrlf=true 检出的就是 CRLF，直接从工作目录
# 打包很容易带进来（仓库里的 .gitattributes 只能保证 git 侧是 LF）。
# ---------------------------------------------------------------------------
norm_lf() {
    f="$1"
    [ -f "$f" ] || return 0
    if command -v tr >/dev/null 2>&1; then
        tr -d '\r' < "$f" > "$f.lf.tmp" 2>/dev/null && mv -f "$f.lf.tmp" "$f" 2>/dev/null
    elif [ -x "$MAGISKBIN/busybox" ]; then
        "$MAGISKBIN/busybox" tr -d '\r' < "$f" > "$f.lf.tmp" 2>/dev/null && mv -f "$f.lf.tmp" "$f" 2>/dev/null
    fi
    rm -f "$f.lf.tmp" 2>/dev/null
    return 0
}

for f in service.sh stop.sh action.sh watchdog.sh config.cfg customize.sh module.prop; do
    norm_lf "$MODPATH/$f"
done

# Ensure the tool ships with the right permissions. Magisk may preserve the
# source timestamps but permissions must be enforced at install time.
chmod 755 "$MODPATH/service.sh" 2>/dev/null
chmod 755 "$MODPATH/stop.sh" 2>/dev/null
chmod 755 "$MODPATH/action.sh" 2>/dev/null
chmod 755 "$MODPATH/watchdog.sh" 2>/dev/null

ui_print "- PICO 4 Fan Auto Temp Control v2.0.0"
ui_print "- 风扇自动温控模块已安装"
ui_print "- v2.0.0 重写控制方式：停掉 pxrfanservice，用厂商正常接口 setfanspeed 调速"
ui_print "- 不再和原厂抢 MCU test mode；停不掉时自动回退，watchdog 兜底恢复厂商"
ui_print "- 控制：三路温度取最高档 / 升档平滑 / 熄屏压档 / 回滞"
ui_print "- 详见 CHANGELOG.md"

exit 0
