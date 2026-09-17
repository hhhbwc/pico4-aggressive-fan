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

for f in service.sh stop.sh action.sh config.cfg customize.sh module.prop; do
    norm_lf "$MODPATH/$f"
done

# Ensure the tool ships with the right permissions. Magisk may preserve the
# source timestamps but permissions must be enforced at install time.
chmod 755 "$MODPATH/service.sh" 2>/dev/null
chmod 755 "$MODPATH/stop.sh" 2>/dev/null
chmod 755 "$MODPATH/action.sh" 2>/dev/null

ui_print "- PICO 4 Fan Auto Temp Control v1.3.0"
ui_print "- 风扇自动温控模块已安装"
ui_print "- 修复：标记文件误判致模块失灵 / RPM 升速永久自锁 / 回滞未实现"
ui_print "- 修复：disable 不持久 / 过热交回只维持 5 秒 / 无超时看门狗"
ui_print "- 详见 CHANGELOG.md"

exit 0
