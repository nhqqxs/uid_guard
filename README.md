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
.github/workflows/build-ko.yml         独立构建 .ko（官方 GKI，不打补丁，产物在 Actions 里）
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

## 与 fgetpriority 的区别

`fgetpriority` 是同类方案的另一套实现（LKM）：它在运行期把内核 text 里的
`bl find_user` 改成跳到自己的 hook，对**所有** app 之间的 `PRIO_USER` /
`IOPRIO_WHO_USER` 查询一律返回 `-ESRCH`。两者解决同一个问题，但代价差别很大：

| 维度 | fgetpriority（LKM） | uid_guard（本补丁） |
|---|---|---|
| 注入方式 | 运行期改内核 text；`bl` 跨模块超出 ±128MB 时回退 kprobe | 编译期改 `find_user()` 函数体 |
| 判定 | **全量门控**：所有 app 之间一律 ESRCH | **名单驱动**：只隐藏 `pkgs.conf` 里的 uid |
| 运行态指纹 | 整机第三方 app 全部"不存在"，检测方会看到"没有任何第三方 app 在运行" | 名单外保持真实，与 PackageManager 视图一致 |
| 系统组件 | `AID_SYSTEMUI`(10139) 这类 10000+ 的系统 AID 会被一起打死 | 不在名单，完全不受影响 |
| 多用户 | 先 `% 100000` 再比较，**跨用户同 app 会因取模相等被放行**（漏洞） | 内核里已是全局 kuid，名单按 base uid 归一化，所有用户副本一起隐藏 |
| 引用计数 | 必须手工 `free_uid()` 归还 `find_user()` 的引用，否则泄漏 | 直接返回 NULL，不取引用 |
| 稳定性 | 部分 callsite 打补丁失败不回滚；`rmmod` 可能留下指向已释放模块代码的 `bl` | 静态编译，无运行期修改 |
| 名单 | 无（全量），无法排除特定 app | `pkgs.conf`，改完重启或跑一次 `service.sh` 即可生效 |
| 加载痕迹 | `/proc/modules` 多一个模块；加载 OOT 模块会置 taint 位（可能被 app 读到） | 无模块、无 text patch；只剩"自编内核"本身的指纹 |
| 前提 | 任何 root 设备（免自编内核） | 需要自编内核 |

**为什么"全量"反而更差**：检测方的判据是"PackageManager 里装了 N 个第三方 app，
但 uid 活性扫描显示 0 个在运行"——这是不可能事件，比"某个 app 仍在跑"更容易被判定
为环境被篡改。此外 `SystemUI` 的 AID 是 10139，落在 fgetpriority 的门控区间内，探测
它也会得到 `-ESRCH`，即"系统 UI 不在运行"，同样是铁证。

uid_guard 只做"减法"：命中的 uid 看起来"没安装/没运行"，其余（含 `SystemUI`、其他
未隐藏的 app、root 侧）保持真实，跨视图自洽，因此没有这类可指纹化的异常。

唯一例外是**免自编内核**：fgetpriority 能装在任何 root 设备上，而 uid_guard 需要内核
源码。只要设备有可编的内核分支，uid_guard 在稳定性、隐蔽性、可维护性上都更好。

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

Actions 页面手动运行 `Build uid_guard_cfg.ko` 即可，不需要填任何版本参数——它会自动
取最新的 `common-android12-5.10-*` 分支。

它**不给内核打补丁**，只做两件事：编一次内核拿到 `Module.symvers`，再用
`make M=src modules` 编出 `.ko`。之所以能不打补丁，是因为模块用一次性 kprobe 按名字
查找 `uid_guard_set`，编译期不引用该符号——补丁只需要打在目标内核上。

`Module.symvers` 由 `modpost` 阶段产出，官方 GKI 只发 `Image` 不发符号表，所以首次
构建仍要编一次内核（约 30 分钟）；结果会按 manifest 分支缓存，之后基本就是同步源码
加编模块，几分钟完成。勾 `force_rebuild_kernel` 可以强制重编。

> **适用范围**：同 KMI（android12-5.10）内的任意 5.10.x GKI 内核，含自编内核。
>
> 原因是 GKI 保证 KMI 内 `module_layout` 等符号的 CRC 稳定，而 vermagic 里的版本号
> 部分会被 `same_magic()` 跳过——`CONFIG_MODVERSIONS=y` 时它用
> `strcspn(magic, " ")` 跳过 `UTS_RELEASE`，只比对
> `SMP preempt mod_unload modversions aarch64`。所以用 5.10.198 的树编出来的 `.ko`
> 在 5.10.272 上也能加载，SUSFS/BakaSU、伪装 UTS release 的自编内核同样适用。

### 3. 打包并刷入

```sh
sh build_module_zip.sh <内核构建目录>/dist/uid_guard_cfg.ko
# 产出 uid_guard_<version>.zip
```

1. 先刷内核（含补丁的 AK3 / boot 镜像）；
2. 再刷 `uid_guard_*.zip`；
3. 编辑 `/data/adb/uid_guard/pkgs.conf`；
4. 重启；或直接 `su -c sh /data/adb/modules/uid_guard/service.sh` 立即生效。

## pkgs.conf

**实际读取的名单是 `/data/adb/uid_guard/pkgs.conf`**，不在模块目录里。
刷入新版本会整包替换 `/data/adb/modules/uid_guard`，放在里面的配置必然被
默认值覆盖，所以名单被挪到了模块目录之外：升级、卸载重装都不会动它。

模块目录里的 `module/pkgs.conf` 只作首次安装的初始模板。安装时
`customize.sh` 按三种情况处理：

| 情况 | 行为 |
|---|---|
| 外部名单已存在 | 原样保留，不动 |
| 旧版名单在模块目录里 | 复制到外部（自动迁移，无需手动搬） |
| 两者都没有 | 用模板生成默认名单 |

`service.sh` 里也做了同样的兜底：外部名单不存在且模块内有模板时会自动
复制一次，因此即使绕过安装器直接替换文件也能正常迁移。

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
