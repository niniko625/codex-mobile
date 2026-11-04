# Ubuntu Runtime Supply Chain

> 审计日期：2026-11-04
> 审计者：Codex（自动审计）

---

## 1. Rootfs

| 属性 | 值 |
|------|-----|
| **来源** | termux/proot-distro GitHub Release |
| **版本** | v4.18.0 |
| **codename** | noble (Ubuntu 24.04.1 LTS) |
| **architecture** | aarch64 |
| **格式** | tar.xz |
| **主 URL** | `https://ghfast.top/https://github.com/termux/proot-distro/releases/download/v4.18.0/ubuntu-noble-aarch64-pd-v4.18.0.tar.xz` |
| **备用源** | `gh-proxy.com`、GitHub 直连、`ghproxy.net`（按顺序自动回退） |
| **文件大小** | 64,133,552 bytes |
| **SHA-256** | `91acaa786b8e2fbba56a9fd0f8a1188cee482b5c7baeed707b29ddaa9a294daa` |
| **license** | Ubuntu 基础系统 — 各包独立许可证（主要是 GPL/APL）；proot-distro 打包脚本为 GPLv3 |
| **再分发** | GitHub Release asset，public 可下载 |
| **包含 bash** | ✅ `/usr/bin/bash` |
| **包含 apt** | ✅ `/usr/bin/apt`, `/usr/bin/apt-get` |
| **包含 sh** | ✅ `/usr/bin/sh` |
| **总文件数** | 12,684 |
| **已验证** | ✅ HTTP 200，SHA256 匹配，内容检查通过 |

## 2. Proot Loader

| 属性 | 值 |
|------|-----|
| **来源** | Termux package mirror（清华 / 中科大 / 北外 / 官方） |
| **包名** | proot |
| **版本** | 5.1.107.102 |
| **architecture** | aarch64 |
| **格式** | .deb (ar + tar.xz) |
| **主 URL** | `https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main/pool/main/p/proot/proot_5.1.107.102_aarch64.deb` |
| **文件大小** | 103,028 bytes |
| **SHA-256** | `10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030` |
| **license** | GPLv2 |
| **包含文件** | `usr/bin/proot`、`usr/libexec/proot/loader`、`usr/libexec/proot/loader32` |
| **已验证** | ✅ HTTP 200，SHA256 已更新（manifest 已修正），内容检查通过 |

> **注意**：旧版 `5.1.107.89` 已从官方 pool 和国内镜像删除，会稳定返回 HTTP 404。
> manifest 已升级到 `5.1.107.102`，并使用清华、中科大、北外与官方四个源。

> **断点续传**：下载器会保留 `.part` 文件，并在重试或切换镜像时发送
> HTTP `Range` 请求，从已有字节继续下载；完成后才原子重命名为目标文件。

## 3. Fake SysData

| 属性 | 值 |
|------|-----|
| **实现** | `lib/runtime/sysdata_setup.dart` |
| **设计原理** | proot 读取 `/proc` 时透明重定向到带 `.` 前缀的 fake 文件（如 `.stat`、`.loadavg`）。本模块在 rootfs 解压后创建这些文件。 |
| **当前创建的文件** | `.loadavg`、`.stat`、`.uptime`、`.version`、`.vmstat`、`.sysctl_entry_cap_last_cap`、`.sysctl_inotify_max_user_watches` |
| **Android 兼容性** | 纯 Dart 实现，CPU 核心数取自 `Platform.numberOfProcessors` |
| **security** | 只创建文本文件，无敏感信息。后续可考虑权限校验。 |
| **Phase 1 验证** | 暂未实机验证。需要等 proot + rootfs 启动后根据实际错误补充。 |

## 4. Artifact Manifest（当前）

```json
{
  "ubuntu_rootfs": {
    "version": "24.04",
    "codename": "noble",
    "arch": "aarch64",
    "url": "https://ghfast.top/https://github.com/termux/proot-distro/releases/download/v4.18.0/ubuntu-noble-aarch64-pd-v4.18.0.tar.xz",
    "mirrors": ["https://gh-proxy.com/https://github.com/...", "https://github.com/...", "https://ghproxy.net/https://github.com/..."],
    "sha256": "91acaa786b8e2fbba56a9fd0f8a1188cee482b5c7baeed707b29ddaa9a294daa",
    "size": 64133552,
    "format": "tar.xz"
  },
  "proot": {
    "version": "5.1.107.102",
    "arch": "aarch64",
    "url": "https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main/pool/main/p/proot/proot_5.1.107.102_aarch64.deb",
    "sha256": "10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030",
    "size": 103028,
    "format": ".deb (ar + tar.xz)"
  }
}
```

## 5. License 风险

| 组件 | License | 风险等级 |
|------|---------|---------|
| Ubuntu rootfs 各包 | 混合（GPL / APL / MIT / BSD） | 🟡 低 — 系统库正常使用 |
| termux/proot-distro 打包脚本 | GPLv3 | 🟡 低 — 仅参考概念，未复制脚本 |
| termux/proot | GPLv2 | 🟡 低 — 来自 Termux 官方仓库，随 APK 分发 |
| SysDataSetup (Dart) | Apache 2.0 (本项目) | ✅ 无风险 — 原创纯 Dart 实现 |
| OperitTerminalCore | 未确定 | ⛔ 不复制其代码 |

## 6. 架构决策

```
APP 默认 Runtime = Ubuntu 24.04 ARM64 + proot
```

- ✅ rootfs URL 已验证
- ✅ proot .deb 已验证  
- ✅ SHA256 已修正
- ✅ 基础文件（bash/apt/sh）已确认存在
- ✅ Termux 兼容架构
- ⚠️ 实机 proot 启动尚未验证（Phase 1 执行）

## 7. 代码迁移方案

### 可复用代码
- `lib/runtime/artifact_manager.dart` — 下载 + SHA256 + 解压逻辑
- `lib/runtime/ubuntu_runtime_installer.dart` — Ubuntu 安装器（440 行，主要逻辑已实现）
- `lib/runtime/sysdata_setup.dart` — fake /proc 创建
- `lib/runtime/runtime_environment.dart` — 环境变量构建
- `lib/runtime/runtime_manifest.dart` — 已有 rootfs + proot 条目
- `lib/runtime/runtime_manager.dart` — 编排器

### 需修正
- `runtime_manifest.dart`: proot SHA256 需更新

### 需废弃（不删除，标记 deprecated）
- `lib/runtime/runtime_installer.dart` — .deb 单包安装器
- node/git/python 相关的 .deb artifact 条目（保留但标记 deprecated）

### Phase 1 实施计划

```
1. 修正 manifest SHA256                               ← 本次完成
2. UbuntuRuntimeInstaller 实机调试（rootfs/proot/sysdata）
3. PTY 启动 proot → Ubuntu bash
4. 验证: uname -a / cat /etc/os-release / echo hello
5. 通过 Terminal UI 进入 Ubuntu shell
```

> 下阶段：Phase 1 — 实机 rootfs 解压 + proot 启动验证
