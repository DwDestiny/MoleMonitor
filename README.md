---
title: "MoleMonitor · 只读菜单栏监控"
type: project
last_updated: 2026-10-11
---

# MoleMonitor

> **方向调整（2026-10-11）**：MoleMonitor 的目标改为轻量的状态监测与预警工具，菜单栏以"小狗加两个点"显示 CPU、内存、温度的健康等级，并提供 CLI 读取状态。目标设计见 [docs/PROJECT.md](docs/PROJECT.md)，尚未实现。本页其余内容描述当前代码（第一版）。

MoleMonitor 是一个只读的 macOS 菜单栏监控工具，以 Swift/AppKit 和 SwiftUI 构建，复用 [Mole](https://github.com/tw93/Mole) 的状态采集器，并补充电池、内存压力、温度和风扇信息。

它只负责查看系统状态。清理可另行通过 Mole CLI 执行；应用没有清理入口、自动删除、风扇控制或特权 helper，也不需要 sudo。

## 功能

以下是第一版实现。

| 位置 | 内容 |
|---|---|
| 菜单栏 | CPU 占用、内存占用、上下行网络速率 |
| 展开面板 | CPU/内存概览、已用与总内存、内存压力、磁盘剩余空间 |
| 电池与散热 | 电池百分比、充电/外接电源状态、循环次数、CPU 温度、电池温度、风扇 RPM |
| 应用排行 | 按应用归并进程，切换 CPU 或内存占用前五名 |

当前不提供各应用耗电排行，不以 CPU 使用率估算能耗。缺失、过期或读取失败的指标保留不可用状态。

## 构建与运行

要求 Apple Silicon（arm64）、macOS 14+、Python 3，以及可用的 Xcode 或 Command Line Tools Swift 工具链。无需 Go 或 Homebrew。最低系统版本来自构建目标；目前仅在一台 Apple M5/macOS 27 设备上完成短时验证，其他芯片与系统版本尚未实测。

```bash
git clone https://github.com/DwDestiny/MoleMonitor.git
cd MoleMonitor
python3 scripts/build.py
```

首次构建会从 Mole 官方 `V1.59.1` release 下载 `status-darwin-arm64`，校验固定 SHA-256 后缓存到 `Vendor/mole-status`。下载需要网络；已有有效缓存时可复用。仓库不分发该二进制，也不安装完整的 Mole 清理 CLI。上游版本、哈希和第三方归属见 [Vendor/NOTICE.md](Vendor/NOTICE.md)。

构建产物是 `dist/MoleMonitor.app`。手动打开后，应用出现在菜单栏，可展开查看详情、切换排行或退出。构建脚本不会安装应用或设置登录启动。

仓库首发仅包含源码、构建脚本和文档，不上传 App 或诊断原件。应用使用本地 ad-hoc 签名，尚未公证；目前没有 GitHub Release 成品。

## 数据口径

- CPU 温度为按芯片家族选取的可读 CPU 传感器均值，不是最热核心温度。
- 应用 CPU 使用单核满载为 100% 的口径，归并多进程后可超过 100%。
- 应用内存为 RSS 合计，共享页可能重复计入，不能直接与活动监视器的内存值逐位比较。
- 网络沿用上游选定路由/隧道的聚合历史，避免 VPN 和物理承载流量双算。
- 内存压力来自系统标志，不由内存占用百分比推导。
- 成功读到的风扇 0 RPM 与无法取得风扇值分别处理。

Mole 采集器的采集范围比界面展示的指标广，因此常驻成本仍需进一步实测。传感器读取与进程排行在后台执行，界面更新在主线程。应用不读取完整进程命令参数。

## 验证状态

截至 2026-10-10，第一版已完成构建、协议检查、短时无界面采样、受控故障恢复和静态预览检查。一次 90 秒采样得到 44 帧；App 与采集进程的 CPU 采样均值约 0.49%，峰值 RSS 为 37.9 MiB。该测试没有创建可见 GUI，不能代表长期运行或电池影响。

真实菜单栏交互、完整 GUI 开销、睡眠唤醒、网络切换和其他设备兼容性仍待验证。完整范围见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。

可以在不打开菜单栏界面的情况下运行诊断：

```bash
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test
codesign --verify --deep --strict dist/MoleMonitor.app
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --diagnose --seconds 90
```

诊断支持 `--preview <绝对输出路径>`，在结束时导出使用当次数据生成的静态界面图；静态图不证明真实菜单栏操作通过。

## 项目结构

| 目录/文件 | 用途 |
|---|---|
| [Sources/](Sources/README.md) | 菜单栏界面、数据流适配、应用排行与只读系统指标 |
| [scripts/](scripts/README.md) | 下载、校验和本地构建 |
| [Vendor/NOTICE.md](Vendor/NOTICE.md) | 固定上游来源、校验值与第三方许可 |
| [docs/](docs/README.md) | 范围、架构、数据口径和脱敏验证摘要 |
| [AGENTS.md](AGENTS.md) | 开发协作约定 |
| [CLAUDE.md](CLAUDE.md) · [接手说明](docs/HANDOFF.md) | Claude 协作入口、当前状态与跨平台开发边界 |
| `dist/` | 可再生成的构建产物与诊断输出，不纳入版本管理 |

## 许可证与归属

MoleMonitor 采用 [GPL-3.0-only](LICENSE)。Mole 状态采集器来自 [tw93/Mole](https://github.com/tw93/Mole)，遵循其 GPL-3.0 许可证。SMC 协议和传感器键的实现参考 SMCKit 与 Stats，相关 MIT 许可证和归属保留在 `Vendor/`，并随构建产物打包。详见 [第三方说明](Vendor/NOTICE.md)。
