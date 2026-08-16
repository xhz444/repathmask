# PkgMask — 已装应用「存在性伪装」内核模块

PkgMask 是一个 KernelSU 模块（arm64 LKM），用于封死 Android 共享存储上最常用的
**已装应用探测侧信道**：

```
mkdir /sdcard/Android/data/com.abc.de
```

- 包**未安装**时，`/sdcard/Android/data` 父目录不可写 → **EACCES**（Permission denied）
- 包**已安装**时，FUSE/MediaProvider 的包名重定向对已存在目标返回 **ENOENT**（No such file or directory）

任何 App（无需任何权限）都可以靠这个 errno 差异推断你装没装某个包。PkgMask 对你
指定的包名目录做完整伪装，使「已安装」呈现出与「真实不存在」**完全一致**的画像：

| 操作 | 真实不存在的返回 | PkgMask 对隐藏路径的返回 |
| --- | --- | --- |
| stat / statx / access / readlink / open（读） | ENOENT | **ENOENT** |
| 目录列举（getdents64） | 条目不可见 | **条目被过滤** |
| mkdirat / open(O_CREAT) / openat2(O_CREAT) | EACCES | **EACCES** |
| linkat / symlinkat / rename 目标 | EACCES | **EACCES** |
| unlinkat / rename 源 | ENOENT | **ENOENT** |

被隐藏的包**自身**不受任何影响（属主 UID 自动豁免），adb shell / 系统关键 UID 默认
豁免（可配）。

> 内核核心提取自 [LKM-PathMask](https://github.com/Andrea-lyz/LKM-PathMask)
> commit `b2d98ef`（v2.7.0 的「写操作伪装不存在」特性），裁剪为单一用途并重写了
> 用户态控制层。许可证 GPL-2.0，原作者 Andrea-lyz。

---

## 工作原理（简）

- **读侧**：kretprobe 挂 `inode_permission` / `vfs_getattr` → 对隐藏 inode 返回
  ENOENT；由于 GKI 5.15+ 的 ThinLTO 会把这两个函数内联进调用方，另挂
  `__arm64_sys_{newfstatat,statx,faccessat2,readlinkat,openat,openat2}` 入口桩作为
  兜底（默认不挂 `faccessat`——它会被检测方做时间指纹，详见源码注释）；
  `__arm64_sys_getdents64` 返回后过滤隐藏条目。
- **写侧**（本模块核心）：kretprobe 挂
  `__arm64_sys_{mkdirat,unlinkat,renameat,renameat2,linkat,symlinkat}`，按
  「路径前缀匹配 + 创建类/删除类」把最终 errno 改写为 EACCES / ENOENT；
  `openat`/`openat2` 检查 `O_CREAT` 标志同样改写（openat2 通过
  `copy_from_user` 读 `struct open_how`）。
- 目标以 `(dev, inode)` 记录（读侧免疫路径别名），`kern_path`/`path_put` 通过
  kprobe 解析地址，兼容裁剪了导出符号的 OEM 内核；CFI 内核用 `__nocfi` 包装。
- UID 作用域：`scope_mode=allow` + 豁免表（系统 UID + 各隐藏包属主 + 用户自定义），
  由 `service.sh` 在加载时计算。

## 安装

### 1. 确认内核 KMI（LKM 必须与 KMI 精确匹配，加载失败的头号原因）

```sh
adb shell su -c uname -r
# 例: 6.1.99-android14-8-gxxxxxxx  →  android14-6.1
#     6.6.30-android15-8-gxxxxxxx  →  android15-6.6
```

默认 CI 只构建 `android14-6.1` 与 `android15-6.6`；需要其他 KMI 时编辑
`.github/workflows/build-lkm.yml` 的 matrix（支持 android12-5.10 ~ android16-6.12）。

### 2. 获取模块 zip

- Fork 本仓库 → Actions 自动构建 → 下载对应 KMI 的 `PkgMask-<kmi>.zip`
  （无 GKI 构建环境的推荐路径）；或
- 本地打包：拿到对应 KMI 的 `pkgmask.ko` 后
  `sh tools/package_ksu.sh <ko路径> <输出.zip>`

### 3. 刷入

KernelSU 管理器 → 模块 → 从本地安装 → 选 zip → 重启。APatch 用户同样兼容
（KSU 模块格式）。Magisk 用户需自行解决 WebUI（或直接改 conf 后执行 action）。

### 4. 配置

打开 KernelSU 管理器中本模块的 **WebUI**（三个页面）：

- **隐藏包名**：加入要隐藏的包（如 `com.abc.de`）→ 点「保存并热重载」
- **状态与日志**：加载状态、已解析目标数（应等于目标总数）、每包处理结果、
  服务日志与 dmesg
- **豁免设置**：受信任应用包名 / 额外 UID（系统 UID 默认 0 1000 1023 1053 2000，
  在模块目录 `system_uids.conf` 可改）

也可直接编辑 `/data/adb/pkgmask/*.conf` 后执行模块的「Action」按钮热重载，
配置存放在 `/data/adb/pkgmask/`，模块升级不丢失。

## 验证是否生效

假设隐藏了 `com.hidden.pkg`，另取一个已运行应用的 uid（如 10236）：

```sh
# 1) mkdir 探测：应得 Permission denied（EACCES），而不是 No such file or directory
adb shell su 10236 -c 'mkdir /sdcard/Android/data/com.hidden.pkg'
# 输出: mkdir failed, Permission denied   ← 伪装成功

# 2) stat：应得 ENOENT
adb shell su 10236 -c 'stat /sdcard/Android/data/com.hidden.pkg' 

# 3) 列举：列表中不应出现该包
adb shell su 10236 -c 'ls /sdcard/Android/data/'

# 4) 对照组：换一个确实未安装的包名，两者返回必须一致
adb shell su 10236 -c 'mkdir /sdcard/Android/data/com.not.installed'

# 5) 被隐藏包自身读写正常（打开该 App 验证其文件功能）
```

第 1、4 步输出完全一致（同为 EACCES）即伪装成立。

## OEM（非 GKI）内核本地编译

CI 产物基于 GKI 内核，OEM 定制内核大概率 modversion 不匹配（insmod 报
`Invalid module format` / `disagrees about version of symbol module_layout`）：

1. 取机型内核源码并完成一次内核编译（或厂商发布的标准内核构建产物，
   需 `Module.symvers` 与编译脚本链）。
2. 将 `kernel/` 目录复制出来，在该环境里：
   ```sh
   cd kernel
   make KDIR=/path/to/kernel/out CC=clang
   # （无 clang 时用 CC=gCC 的交叉工具链亦可）
   ```
3. `sh tools/package_ksu.sh kernel/pkgmask.ko out/PkgMask-local.zip` 打包刷入。

## 融合包（PathMask Fusion）

针对已有自编译 procguard 加载器（id=pathmask）的设备的合包方案：保留原有
procguard.ko 与 Scene 监视功能，叠加 PkgMask 的包名隐藏与 WebUI 控制层。

- 产物：`out/PathMask-Fusion-<kmi>.zip`，由
  `sh tools/package_fusion.sh <旧zip> [pkgmask.ko] [输出.zip]` 生成
- 安装：直接在 KernelSU 里刷入——它沿用 `id=pathmask`，会**原地升级**你现有模块，
  `/data/adb/pathmask` 里的状态与配置保留
- 组成：procguard.ko（原样）+ scene-debugfs-watch.sh（6.6 包原样，装了 Scene
  才启动）+ PkgMask 控制层（hide_packages.conf、WebUI、热重载、熔断）
- WebUI 状态页同时显示三者状态，右上角「复制诊断报告」一键收集全部排障信息

**激活路径隐藏**（融合包默认不含 pkgmask.ko，可先刷后补）：

1. 用与 procguard.ko 相同的内核源码树编译：
   ```sh
   cd kernel
   make KDIR=/path/to/<机型内核树>/out   # 6.1 手机一棵树、6.6 手机一棵树
   ```
2. 二选一：
   - `adb push kernel/pkgmask.ko /data/adb/modules/pathmask/pkgmask.ko`，
     打开 WebUI 点「保存并热重载」；
   - 或 `sh tools/package_fusion.sh <旧zip> kernel/pkgmask.ko` 重新打包刷入。

**关于 vermagic**：Android 内核开启 `CONFIG_MODVERSIONS`，加载时**忽略 vermagic
的版本号段**、只校验符号 CRC——所以 ddk/GKI 编的 ko（如 6.1.75）能加载到
6.1.141 的手机上，你的 `6.1.166-dirty` procguard 也能加载到 6.1.141 一加上，
这不是巧合而是设计。融合包只把 vermagic 差异作为诊断提示记录，不会据此拒绝
加载；若 insmod 报 `disagrees about version of symbol` 才真的需要用当前内核
源码树重编。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| WebUI 显示「已熔断」 | 连续 3 次 insmod 失败。多为 KMI 不匹配：核对 `uname -r` 与 zip 对应关系，换正确 zip 后在 WebUI 热重载（会自动重置熔断） |
| `Invalid module format` | KMI/符号版本不匹配，见上一节 |
| resolved < target 总数 | 部分 target 路径解析失败，看服务日志（多见于加载时该目录尚未创建，热重载一次即可） |
| 包显示 not-installed | 该包确实没有 `Android/data`/`obb` 目录（未安装或从未运行），无需隐藏 |
| 隐藏后该 App 自身异常 | 属主 UID 未解析到（状态页会标注），确认包已安装后热重载 |
| 误伤其他应用 | 把受影响应用加入豁免包名列表 |

## 已知限制

- 写侧按**绝对路径字符串**前缀匹配：Java 层 `File` API 均为绝对路径（本威胁模型
  全覆盖）；极少数 native 代码用 dirfd+相对路径探测不会被改写（读侧 inode 匹配
  仍会隐藏）。`/proc/*/mounts`、`mountinfo` 不过滤。
- 加载时已打开的 fd 不受影响（重启或重开应用后生效）。
- 隐藏包装卸载/目录结构变化后需热重载；开机自动处理一次。
- 多用户/工作资料（user 10+）为 best-effort：service.sh 会展开
  `/storage/emulated/<n>` 前缀，但某些定制 ROM 行为可能不同。
- 检测方仍可通过包管理器 API（`PackageManager`）查询——那是另一条战线，请配合
  Hide My Applist 之类的方案；本模块只负责文件系统侧信道。
- `faccessat` 默认不挂（防时间指纹）：意味着 `access(F_OK)` 探测读侧由
  inode_permission/getattr 层兜底，个别 ROM 若两者均被内联则该系统调用会漏出。
  如不介意可 `syscall_hooks=all` 手动 insmod。

## 风险与声明

- 仅供在**自己拥有的设备**上保护隐私使用。
- 内核级隐藏可能违反个别应用的条款（典型如游戏反作弊），由此产生的账号风险自负。
- kretprobe 有微量开销；内核模块 bug 可能导致不稳定，请保持可随时卸载（rmmod /
  管理器禁用）的退路。

## 致谢

- [Andrea-lyz/LKM-PathMask](https://github.com/Andrea-lyz/LKM-PathMask) —— 内核核心
  （读侧隐藏、写操作 errno 伪装、kprobe 符号解析、CFI 处理）的原始实现。
- [ylarod/ddk-min](https://github.com/ylarod/ddk) —— CI 使用的 GKI DDK 构建容器。

许可证：GPL-2.0（`kernel/pkgmask.c` 为 LKM-PathMask 衍生作品）。
