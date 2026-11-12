#!/system/bin/sh
SKIPUNZIP=0

ui_print "- 安装 uid_guard 名单注入器"

set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0755 "$MODPATH/service.sh" 2>/dev/null
chmod 0755 "$MODPATH/customize.sh" 2>/dev/null
[ -f "$MODPATH/ko/uid_guard_cfg.ko" ] && chmod 0644 "$MODPATH/ko/uid_guard_cfg.ko"

if [ ! -f "$MODPATH/ko/uid_guard_cfg.ko" ]; then
	ui_print "! 未找到 ko/uid_guard_cfg.ko"
	ui_print "! 模块可以安装，但不会生效：请用打了 0014 补丁的内核树编译后放入 ko/"
fi

ui_print "- 编辑 pkgs.conf 后重启（或执行 service.sh）即可生效"
