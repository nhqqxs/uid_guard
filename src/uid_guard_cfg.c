// SPDX-License-Identifier: GPL-2.0-only
/*
 * uid_guard_cfg - 把 base uid 名单注入内置的 uid_guard
 *
 * 本模块只做“传参”：把 module_param 里的逗号分隔 uid 列表交给
 * kernel/user.c 中的 uid_guard_set()，不改内核 text、不注册 kprobe。
 *
 * 参数权限写 0，因此不会生成 /sys/module/uid_guard_cfg/parameters/uids。
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kstrtox.h>
#include <linux/types.h>

#if defined(__has_include)
#if __has_include(<linux/uid_guard.h>)
#include <linux/uid_guard.h>
#define UID_GUARD_HAVE_HEADER 1
#endif
#endif
#ifndef UID_GUARD_HAVE_HEADER
/* 未打 0014 补丁的内核树：本地声明，链接/加载由内核侧符号决定 */
extern int uid_guard_set(const u32 *uids, u32 count);
#endif

#define UID_GUARD_CFG_MAX	256

static char uids_param[1024] = "";
module_param_string(uids, uids_param, sizeof(uids_param), 0);
MODULE_PARM_DESC(uids, "逗号分隔的 base uid 列表");

static int __init uid_guard_cfg_init(void)
{
	u32 list[UID_GUARD_CFG_MAX];
	char *p = uids_param;
	int n = 0;
	int ret;

	while (*p && n < UID_GUARD_CFG_MAX) {
		unsigned int val;

		while (*p == ',' || *p == ' ' || *p == '\t' || *p == '\n')
			p++;
		if (!*p)
			break;

		if (kstrtouint(p, 0, &val))
			break;

		list[n++] = val;

		while (*p && *p != ',' && *p != ' ' && *p != '\t' && *p != '\n')
			p++;
	}

	if (!n) {
		pr_info("uid_guard_cfg: 名单为空，保持功能关闭\n");
		return 0;
	}

	ret = uid_guard_set(list, n);
	pr_info("uid_guard_cfg: 注入 %d 个 base uid，ret=%d\n", n, ret);

	return 0;
}

static void __exit uid_guard_cfg_exit(void)
{
}

module_init(uid_guard_cfg_init);
module_exit(uid_guard_cfg_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("uid_guard base uid list injector");
