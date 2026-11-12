#!/system/bin/sh
# uid_guard 名单注入器
#
# 每次开机把 pkgs.conf 里的包名解析成 base uid，交给内核补丁的
# uid_guard_set()。名单为空 / 解析失败时保持功能关闭（fail-open），
# 不会退化成“全量隐藏”。

MODDIR=${0%/*}
CONF="$MODDIR/pkgs.conf"
LOG="$MODDIR/last_boot.log"
KO="$MODDIR/ko/uid_guard_cfg.ko"
PLIST=/data/system/packages.list

[ -f "$KO" ] || KO="$MODDIR/uid_guard_cfg.ko"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] uid_guard boot" > "$LOG"

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

if ! insmod "$KO" uids="$LIST" 2>>"$LOG"; then
	if command -v ksud >/dev/null 2>&1; then
		ksud insmod "$KO" uids="$LIST" 2>>"$LOG" ||
			echo "insmod failed (ksud)" >> "$LOG"
	else
		echo "insmod failed" >> "$LOG"
	fi
fi

# 注入完成后可以选择卸载配置模块，进一步减少常驻痕迹。
# 注意：卸载后名单仍在（已经写进内核），下次改名单需要重新加载本模块。
# rmmod uid_guard_cfg 2>/dev/null

exit 0
