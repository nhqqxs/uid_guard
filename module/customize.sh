#!/system/bin/sh
SKIPUNZIP=0

ui_print "- 安装 uid_guard 名单注入器"

set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0755 "$MODPATH/service.sh" 2>/dev/null
chmod 0755 "$MODPATH/customize.sh" 2>/dev/null
[ -f "$MODPATH/ko/uid_guard_cfg.ko" ] && chmod 0644 "$MODPATH/ko/uid_guard_cfg.ko"

# 名单不再放在模块目录里。
#
# 刷入新版本时 /data/adb/modules/uid_guard 会被整包替换，放在里面的
# pkgs.conf 必然被默认值覆盖。改存到 /data/adb/uid_guard/pkgs.conf 之后，
# 升级、卸载重装都不会碰它，模块目录里的 pkgs.conf 只作为初始模板。
MODID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" 2>/dev/null | head -n 1)
[ -n "$MODID" ] || MODID=uid_guard

USERDIR=/data/adb/uid_guard
USER_CONF="$USERDIR/pkgs.conf"
LEGACY_CONF="/data/adb/modules/$MODID/pkgs.conf"

mkdir -p "$USERDIR" 2>/dev/null

# 三种情况：已有外部名单（保留）> 旧版把名单放在模块目录里（迁移）> 都没有（用默认）
if [ -f "$USER_CONF" ]; then
	ui_print "- 保留已有名单: $USER_CONF"
elif [ -f "$LEGACY_CONF" ]; then
	if cp -f "$LEGACY_CONF" "$USER_CONF" 2>/dev/null; then
		ui_print "- 已把旧名单迁移到: $USER_CONF"
	else
		ui_print "! 旧名单迁移失败，将使用默认名单"
	fi
else
	if cp -f "$MODPATH/pkgs.conf" "$USER_CONF" 2>/dev/null; then
		ui_print "- 已生成默认名单: $USER_CONF"
	else
		ui_print "! 无法创建 $USER_CONF，service.sh 会退回读取模块内默认名单"
	fi
fi

if [ ! -f "$MODPATH/ko/uid_guard_cfg.ko" ]; then
	ui_print "! 未找到 ko/uid_guard_cfg.ko"
	ui_print "! 模块可以安装，但不会生效：请用打了 0014 补丁的内核树编译后放入 ko/"
fi

ui_print "- 编辑 $USER_CONF 后重启（或执行 service.sh）即可生效"
