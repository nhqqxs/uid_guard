# uid_guard

屏蔽 Android 第三方 app 之间对 **uid 存在性** 的探测。

配套 HMA 一类“隐藏应用”工具使用：应用被隐藏后仍可能在后台运行，检测方（同为第三方
app）可以逐个 uid 调用 `getpriority(PRIO_USER)` / `ioprio_get(IOPRIO_WHO_USER)`，
用 `-ESRCH` 与有效 nice 值的差异反推“某个被隐藏的 app 还在跑”。本项目的内核补丁在
`find_user()` 这唯一汇聚点上做过滤，把这条侧信道关掉。

## 组成

```
patches/0014-all-all-uid-guard.patch   内核补丁（android12-5.10 ~ android17-6.18）
module/                                KernelSU / Magisk 模块（名单注入器）
src/uid_guard_cfg.c                    注入模块源码（只传参，不做 hook）
src/Makefile
build_module_zip.sh                    打包成可刷 zip
```

- **hook 在内核补丁里**：避免 text patch / kprobe 的 BL ±128MB 限制与回滚风险。
- **注入在模块里**：AK3 内核包保持通用可分发，名单不编进 `Image`，改名单不用重编内核。

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
git apply /path/to/patches/0014-all-all-uid-guard.patch
```

补丁适用于 `android12-5.10` 到 `android17-6.18`。想直接编内核，也可以把它放进
[`nhqqxs/GKI_BakaSU_SUSFS`](https://github.com/nhqqxs/GKI_BakaSU_SUSFS) 的
`custom_patches/` 目录。

### 2. 编译注入模块

内核树必须**已经完整构建过**（`Module.symvers` 存在），否则链接会报 `module_layout`
一类错误；只跑 `make modules_prepare` 不够。

```sh
cd src
make -C <GKI 内核树（common）> \
     M="$PWD" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     modules
```

### 3. 打包并刷入

```sh
sh build_module_zip.sh src/uid_guard_cfg.ko
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
