# uid_guard

屏蔽 Android 第三方 app 之间对 **uid 存在性** 的探测。

配套 HMA 一类“隐藏应用”工具使用：应用被隐藏后仍可能在后台运行，检测方（同为第三方
app）可以逐个 uid 调用 `getpriority(PRIO_USER)` / `ioprio_get(IOPRIO_WHO_USER)`，
用 `-ESRCH` 与有效 nice 值的差异反推“某个被隐藏的 app 还在跑”。本项目的内核补丁在
`find_user()` 这唯一汇聚点上做过滤，把这条侧信道关掉。

## 组成

```
patches/0014-5.10.0-5.10.999-uid-guard.patch   内核补丁（android12-5.10）
module/                                KernelSU / Magisk 模块（名单注入器）
src/uid_guard_cfg.c                    注入模块源码（与补丁内嵌的 drivers/misc 同源）
src/Makefile                           仅供独立 Kbuild 树参考（正常不需要）
build_module_zip.sh                    打包成可刷 zip
.github/workflows/build-ko.yml         独立构建（官方 GKI + 本补丁，产物在 Actions 里）
```

- **hook 在内核补丁里**：避免 text patch / kprobe 的 BL ±128MB 限制与回滚风险。
- **注入在模块里**：AK3 内核包保持通用可分发，名单不编进 `Image`，改名单不用重编内核。
- **注入器随内核构建**：补丁把它作为 `obj-m` 放进内核树，产物 `.ko` 在 `dist/` 里，vermagic 严格匹配。

## 原理

补丁只做一件事：`find_user()` 里三个条件同时成立时返回 `NULL`。

```c
if (unlikely(uid_guard_masked(uid)))
        return NULL;
```

1. 目标 uid 在注入名单里；
2. 调用者属于 app 侧（`uid >= 10000`，含 isolated 的 `90000+`）；
3. 目标不是调用者自己。

`find_user()` 是 `getpriority`/`setpriority` 的 `PRIO_USER` 与 `ioprio_get`/`ioprio_set`
的 `IOPRIO_WHO_USER` 的唯一汇聚点，所以一处判定即可覆盖四个系统调用。

**为什么不做“全量隐藏”**：如果对所有第三方 uid 都返回 `-ESRCH`，检测方会看到“整机
没有任何第三方 app 在运行”，而它自己明明在跑——这是不可能事件，比原问题更容易暴露。
所以名单之外的一切（系统域、`AID_SYSTEMUI` 10139 这类 10000+ 的系统组件、未隐藏的
app、未安装的 uid）都保持内核原始行为，跨视图一致性成立。

名单按 **base uid** 存储，判定时 `uid % 100000`，因此同一个包在主用户、工作资料里的
副本会一起生效。

## 快速开始

### 1. 打补丁

```sh
cd <GKI 内核树（common）>
git apply /path/to/patches/0014-5.10.0-5.10.999-uid-guard.patch
```

补丁当前只放开 `android12-5.10`（5.10.x）。想直接编内核，也可以把它放进
[`nhqqxs/GKI_BakaSU_SUSFS`](https://github.com/nhqqxs/GKI_BakaSU_SUSFS) 的
`custom_patches/` 目录。

### 2. 取出 `uid_guard_cfg.ko`

补丁已经把这个注入器放进内核树（`drivers/misc/uid_guard_cfg.c`，`obj-m` 无条件编入），
所以**不需要单独准备内核树**：内核构建完成后，`uid_guard_cfg.ko` 会出现在构建输出里
（GKI 的 `dist/`，或 Bazel 的 `bazel-bin/common/kernel_aarch64/`），vermagic 与内核严格一致。

```sh
find <内核构建目录> -name uid_guard_cfg.ko
```

之所以不用“外部模块 + `make M=`”：Kleaf/Bazel 构建没有传统 Kbuild 树，DDK 预构建的
内核又与自编内核的 vermagic 不一致（sublevel 一变就加载失败）。把注入器编进内核树，
是唯一能保证 vermagic 严格匹配的做法。

#### 或者：用本仓库的 Actions 构建

Actions 页面手动运行 `Build uid_guard_cfg.ko` 即可，可选填 manifest 月份与 tag 的 r 号；
它从官方 GKI 源码 + 本仓库补丁编出 `.ko` 并打包成模块 zip。

> **适用范围**：产物只匹配「官方 GKI + 本补丁」的内核。如果你用的是自编内核
> （SUSFS/BakaSU、自定义 defconfig、伪装 UTS release），大概率会因 vermagic 或
> `module_layout` CRC 不匹配而加载失败——那种情况请用上面的方式，在自己的内核构建里编。

### 3. 打包并刷入

```sh
sh build_module_zip.sh <内核构建目录>/dist/uid_guard_cfg.ko
# 产出 uid_guard_<version>.zip
```

1. 先刷内核（含补丁的 AK3 / boot 镜像）；
2. 再刷 `uid_guard_*.zip`；
3. 编辑 `/data/adb/modules/uid_guard/pkgs.conf`；
4. 重启；或直接 `su -c sh /data/adb/modules/uid_guard/service.sh` 立即生效。

## pkgs.conf

```text
# 每行一个包名，与 HMA 的隐藏列表保持一致
com.example.target_a
com.example.target_b

# 纯数字视为 base uid（包只装在 work profile 等查不到 uid 的场景）
1010234
```

- **只放第三方 app**。把 `AID_SYSTEMUI` 10139 之类的系统组件放进来，会制造“系统组件
  报告未运行”的不可能事件。
- 名单生效范围是 base uid，所有用户/工作资料里的同一包一起隐藏。
- 改完 `pkgs.conf` 重新执行 `service.sh` 即可，不需要重编、不需要重刷。

## 失败行为

名单为空、包名查不到、`insmod` 失败 → **保持关闭**（fail-open），不会退化成“全量
隐藏”。每次启动的结果写在 `/data/adb/modules/uid_guard/last_boot.log`，包含
`MISS pkg: …` 和最终注入的 uid 列表。

## 验证

```sh
# 注入结果
cat /data/adb/modules/uid_guard/last_boot.log

# 名单模块是否在跑
lsmod | grep uid_guard_cfg
```

- app 侧：`getpriority(PRIO_USER, <名单内 uid>)` 应返回 `-1 / ESRCH`；
- app 侧：`getpriority(PRIO_USER, <名单外第三方 uid>)` 应返回真实 nice 值；
- root 侧：同一扫描仍应看到所有真实 uid（证明系统域没被误伤）。

## 边界

本方案只关闭 **`PRIO_USER` / `IOPRIO_WHO_USER` 这一族 syscall 侧信道**，不处理：

- `PRIO_PROCESS` / `PRIO_PGRP` 与 `kill(pid, 0)` 等 **pid 存在性**探测；
- `/proc/net/*` 里 socket 的 uid 列；
- root / 无 seccomp 进程发起的探测（被有意放行，避免影响系统）；
- 内存扫描、内核态内省。

## 卸载

删除 `/data/adb/modules/uid_guard/` 后重启即可。内核补丁在名单为空时不生效，无需回刷
内核。

## License

GPL-2.0-only
