// SPDX-License-Identifier: GPL-2.0-only
/*
 * uid_guard_cfg - 把 base uid 名单注入内置的 uid_guard
 *
 * 本模块只做“传参”：把 module_param 里的逗号分隔 uid 列表交给
 * kernel/user.c 中的 uid_guard_set()。
 *
 * 参数权限写 0，因此不会生成 /sys/module/uid_guard_cfg/parameters/uids。
 *
 * 为什么用一次性 kprobe 找函数地址而不是直接链接：
 * GKI 开了 CONFIG_TRIM_UNUSED_KSYMS，它在链接 vmlinux 之后、编译 obj-m
 * 模块之前就生成导出符号裁剪表。uid_guard_set 只被本模块引用，那一刻还
 * 不存在任何引用者，于是 __ksymtab 条目被裁掉，函数本身仍在 .text 里，
 * 但模块 insmod 时会报 “Unknown symbol uid_guard_set (err -2)”。
 * register_kprobe() 成功即拿到入口地址，随后立即注销，不留常驻探测点，
 * 因此在被裁剪的内核上也能完成注入。
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kstrtox.h>
#include <linux/kprobes.h>
#include <linux/types.h>

#define UID_GUARD_CFG_MAX	256

static char uids_param[1024] = "";
module_param_string(uids, uids_param, sizeof(uids_param), 0);
MODULE_PARM_DESC(uids, "逗号分隔的 base uid 列表");

typedef int (*uid_guard_set_fn)(const u32 *uids, u32 count);

static uid_guard_set_fn uid_guard_resolve_set(void)
{
	struct kprobe kp = {
		.symbol_name = "uid_guard_set",
	};
	uid_guard_set_fn fn;

	if (register_kprobe(&kp)) {
		pr_err("uid_guard_cfg: symbol uid_guard_set not found\n");
		return NULL;
	}

	fn = (uid_guard_set_fn)(void *)kp.addr;
	unregister_kprobe(&kp);

	return fn;
}

static int __init uid_guard_cfg_init(void)
{
	u32 list[UID_GUARD_CFG_MAX];
	uid_guard_set_fn set_fn;
	char *p = uids_param;
	int n = 0;
	int ret;

	while (*p && n < UID_GUARD_CFG_MAX) {
		char token[16];
		unsigned int val;
		int len = 0;

		while (*p == ',' || *p == ' ' || *p == '\t' || *p == '\n')
			p++;
		if (!*p)
			break;

		/* 先切出单个 token：kstrtouint() 要求整个字符串都是数字，
		 * 直接把 "10238,10239" 传进去会在逗号处失败。 */
		while (*p && *p != ',' && *p != ' ' && *p != '\t' && *p != '\n') {
			if (len < (int)sizeof(token) - 1)
				token[len++] = *p;
			p++;
		}
		token[len] = '\0';

		if (!len)
			continue;

		if (kstrtouint(token, 0, &val)) {
			pr_warn("uid_guard_cfg: ignoring unparsable entry '%s'\n", token);
			continue;
		}

		list[n++] = val;
	}

	if (!n) {
		pr_info("uid_guard_cfg: list is empty, staying disabled\n");
		return 0;
	}

	set_fn = uid_guard_resolve_set();
	if (!set_fn)
		return 0;

	ret = set_fn(list, n);
	pr_info("uid_guard_cfg: injected %d base uids, ret=%d\n", n, ret);

	return 0;
}

static void __exit uid_guard_cfg_exit(void)
{
}

module_init(uid_guard_cfg_init);
module_exit(uid_guard_cfg_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("uid_guard base uid list injector");
