#!/system/bin/sh
# uid_guard 名单注入器
#
# 每次开机把名单里的包名解析成 base uid，交给内核补丁的
# uid_guard_set()。名单为空 / 解析失败时保持功能关闭（fail-open），
# 不会退化成“全量隐藏”。

MODDIR=${0%/*}
LOG="$MODDIR/last_boot.log"
KO="$MODDIR/ko/uid_guard_cfg.ko"
PLIST=/data/system/packages.list

# 名单放在模块目录之外：刷入新版本会整个替换 /data/adb/modules/uid_guard，
# 放在里面的配置文件必然被覆盖。改成 /data/adb/uid_guard/pkgs.conf 之后，
# 升级、卸载重装都不会碰它。
USERDIR=/data/adb/uid_guard
USER_CONF="$USERDIR/pkgs.conf"
MOD_CONF="$MODDIR/pkgs.conf"

[ -f "$KO" ] || KO="$MODDIR/uid_guard_cfg.ko"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] uid_guard boot" > "$LOG"

# 首次运行（或从旧版升级上来）：把模块自带的名单搬到外部。
# customize.sh 里也会做一次，这里兜底——直接替换文件而不走安装器的情况
# （比如手动解压）也能正常迁移。
if [ ! -f "$USER_CONF" ] && [ -f "$MOD_CONF" ]; then
	mkdir -p "$USERDIR" 2>/dev/null
	if cp -f "$MOD_CONF" "$USER_CONF" 2>/dev/null; then
		echo "migrated default list -> $USER_CONF" >> "$LOG"
	fi
fi

CONF="$USER_CONF"
if [ ! -f "$CONF" ]; then
	CONF="$MOD_CONF"
	echo "user conf missing, fallback to $CONF" >> "$LOG"
fi

echo "conf=$CONF" >> "$LOG"

if [ ! -f "$KO" ]; then
	echo "MISS ko: $KO" >> "$LOG"
	exit 0
fi

if [ ! -f "$CONF" ]; then
	echo "MISS conf: $CONF" >> "$LOG"
	exit 0
fi

# 等 PackageManagerService 把 packages.list 写出来（最多约 60 秒）
i=0
while [ "$i" -lt 30 ]; do
	if [ -r "$PLIST" ] && [ -s "$PLIST" ]; then
		break
	fi
	i=$((i + 1))
	sleep 2
done

# 包名 -> base uid（user 0）
uid_of() {
	pkg="$1"

	if [ -r "$PLIST" ]; then
		u=$(awk -v p="$pkg" '$1 == p { print $2; exit }' "$PLIST" 2>/dev/null)
		if [ -n "$u" ]; then
			echo "$u"
			return 0
		fi
	fi

	if command -v pm >/dev/null 2>&1; then
		esc=$(echo "$pkg" | sed 's/[.]/\\./g')
		u=$(pm list packages -U --user 0 2>/dev/null |
			sed -n "s/^package:$esc uid:\\([0-9][0-9]*\\)\$/\\1/p" |
			head -n 1)
		if [ -n "$u" ]; then
			echo "$u"
			return 0
		fi
	fi

	return 1
}

LIST=""
while IFS= read -r line || [ -n "$line" ]; do
	line="${line%%#*}"
	line=$(echo "$line" | tr -d ' \t\r')
	[ -z "$line" ] && continue

	case "$line" in
	*[!0-9]*)
		u=$(uid_of "$line") || {
			echo "MISS pkg: $line" >> "$LOG"
			continue
		}
		;;
	*)
		u="$line"
		;;
	esac

	case ",$LIST," in
	*",$u,"*) ;;
	*) LIST="${LIST:+$LIST,}$u" ;;
	esac
done < "$CONF"

if [ -z "$LIST" ]; then
	echo "empty uid list, uid_guard stays off" >> "$LOG"
	exit 0
fi

echo "uids=$LIST" >> "$LOG"

# 允许重复执行：先卸载旧实例
if lsmod 2>/dev/null | grep -q '^uid_guard_cfg'; then
	rmmod uid_guard_cfg 2>/dev/null
fi

# 加载顺序：先 ksud 再 insmod。
#
# 5.10 GKI 开了 CONFIG_TRIM_UNUSED_KSYMS，uid_guard_set 只被本模块引用，
# 而裁剪表在模块编译前就生成，导致它的 __ksymtab 条目被裁掉。toybox 的
# insmod 因此在加载时报：
#   insmod: can't insert '...': unknown symbol in module, or unknown parameter
#   uid_guard_cfg: Unknown symbol uid_guard_set (err -2)
# 而 ksud insmod 同一条命令能成功（实测模块进入 Live、名单生效），所以把
# ksud 放在前面，避免每次开机都先留一条误导性的错误。
KSUD=""
for cand in "$MODDIR/../ksu/bin/ksud" /data/adb/ksu/bin/ksud /data/adb/ksud; do
	if [ -x "$cand" ]; then
		KSUD="$cand"
		break
	fi
done

loaded=0

if [ -n "$KSUD" ]; then
	if "$KSUD" insmod "$KO" uids="$LIST" 2>>"$LOG"; then
		loaded=1
		echo "loaded via ksud: $KSUD" >> "$LOG"
	else
		echo "ksud insmod failed: $KSUD" >> "$LOG"
	fi
else
	echo "ksud not found, falling back to insmod" >> "$LOG"
fi

if [ "$loaded" -eq 0 ]; then
	if insmod "$KO" uids="$LIST" 2>>"$LOG"; then
		loaded=1
		echo "loaded via insmod" >> "$LOG"
	else
		echo "insmod failed (both ksud and insmod)" >> "$LOG"
	fi
fi

# 把模块自己的日志落到文件里，便于确认名单是否真的进了内核
# （成功时应有 "注入 N 个 base uid，ret=0"；名单为空时会是 "名单为空，保持功能关闭"）
dmesg 2>/dev/null | grep "uid_guard_cfg" | tail -2 >> "$LOG"

# 注入完成后可以选择卸载配置模块，进一步减少常驻痕迹。
# 注意：卸载后名单仍在（已经写进内核），下次改名单需要重新加载本模块。
# rmmod uid_guard_cfg 2>/dev/null

exit 0
