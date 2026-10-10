---
title: "MoleMonitor · Claude 接手说明"
type: handoff
last_updated: 2026-10-11
---

# Claude 接手说明

当前交接的是可构建的 macOS 只读监控开发版，真实菜单栏交互和长期运行仍待验收。项目同步到 Linux VPS 后，可以继续方案讨论、源码修改和文档工作；Swift/AppKit/IOKit 构建、传感器读取与 App 的运行检查必须在 Apple Silicon Mac 上完成。Linux 静态检查不能替代这些结果。

## 已确定的范围

- 菜单栏显示 CPU、内存占用和上下行网速；展开后显示磁盘余量、内存压力、电池百分比、充电与外接电源状态、循环次数、CPU 与电池温度、风扇 RPM。
- 按应用归并进程，提供 CPU 和内存 RSS 两种前五名排行。每应用耗电排行已退出本版范围，不以 CPU 占用估算耗电。
- App 只负责监控。需要清理时另由 Agent 按具体授权调用完整 Mole CLI；本项目只下载独立状态采集器，没有安装完整清理 CLI。
- 不增加清理按钮、自动删除、sudo、特权 helper、SMC 写入或风扇控制；当前没有安装到 Applications、设置登录启动、公证或发布二进制 Release。

产品与架构真源是 [PROJECT.md](PROJECT.md)，协作规则是根 [AGENTS.md](../AGENTS.md)。已有实现约束优先，新增产品行为先明确范围。

## 代码与第三方来源

| 文件 | 接手时关注的职责 |
|---|---|
| `Sources/MoleMonitor.swift` | AppKit/SwiftUI 菜单栏、NDJSON 解析、应用排行、时间有效性、采集子进程恢复与退出 |
| `Sources/Sensors.swift` | 只读 AppleSmartBattery、内存压力 sysctl、AppleSMC 温度与风扇读取 |
| `scripts/fetch_status.py` | 固定官方 Mole V1.59.1 的 `status-darwin-arm64`，校验 SHA-256 后原子保存缓存 |
| `scripts/build.py` | 编译 arm64 macOS 14 目标、组装 App、复制许可证、对构建副本做 ad-hoc 签名 |

本项目没有复制、修改或编译 Mole 的 Go 源码，运行的是官方预编译的独立状态采集进程。自有 Swift 实现负责界面、进程管理、应用排行和补充传感器；SMC 协议与传感器键参考 SMCKit 和 Stats，保留 MIT 归属。上游版本与哈希见 [Vendor/NOTICE.md](../Vendor/NOTICE.md)。

当前自有代码采用 GPL-3.0-only。这是本项目已做出的许可证选择，不能仅凭“通过 CLI 调用 Mole”推断必须使用 GPL。接手不变更许可证；如果以后讨论 MIT 等方案，需单独判断代码与分发边界。向外分发捆绑 Mole 的 App 前，还需准备同版本对应源码及明确取得方式。

## 验证基线与下一步

2026-10-10 的 macOS 验证包括构建、协议自检、签名、首次无缓存构建和无效缓存拒绝；90 秒无界面诊断取得 44 帧，受控坏 JSON、分片和后端失响应后恢复采集，已知关联进程退出后无残留。资源采样 CPU 均值约 0.49%、峰值 RSS 37.9 MiB，只覆盖该次无界面运行，不证明长期耗电或完整 GUI 成本。完整口径见 [VERIFICATION.md](VERIFICATION.md)。原始系统快照和诊断图片保留在 Mac 的忽略目录，未作为公开源码或 VPS 开发材料分发。

后续优先完成以下检查，并将真实结果写入验证文档：

1. 在 Mac 上检查菜单栏展开/关闭、CPU/RSS 排行切换、退出、深浅色与屏幕空间适配。
2. 验证实际睡眠/唤醒、过期状态、采集重启与重复子进程；覆盖 Wi-Fi、VPN、路由切换和断网恢复。
3. 检查可见 App 的长期 CPU/内存与电池影响，再验证其他芯片、无电池/无风扇设备和 macOS 14。

传感器失败、缺失与过期继续显示不可用；有效风扇 0 RPM 表示停止，不能与失败混为一谈。应用 CPU 以单核 100% 为口径，多进程归并可超过 100%；RSS 可能重复计入共享页，CPU 温度是选定可读传感器的均值。

## 可用命令

Linux VPS 可以进行 Python 语法检查，以下检查仅解析源码、不执行下载和构建：

```bash
python3 - <<'PY'
import ast
from pathlib import Path
for path in sorted(Path('scripts').glob('*.py')):
    ast.parse(path.read_text(), filename=str(path))
    print(f'Python syntax OK: {path}')
PY
git diff --check
```

Mac 上从项目根目录执行：

```bash
python3 scripts/build.py
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test
codesign --verify --deep --strict dist/MoleMonitor.app
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --diagnose --seconds 22
```

可见 App 检查、安装、登录启动、公证与发行均按用户具体授权范围执行；已有明确授权不重复询问。修改完成后通过可审查的 Git 提交交接回 Mac；合并前检查两边未提交改动，不用目录整包覆盖对方工作。

## Git 与交接边界

公开仓库是 [DwDestiny/MoleMonitor](https://github.com/DwDestiny/MoleMonitor)，初次公开源码提交为 `1564253a6b459ebb0bad0a51f08c67a463dfdf68`。本次新增 Claude 入口与交接说明，保留原代码和历史。具体同步提交、文件哈希与两端路径见本机/VPS 的 `local-notes/` 收据；该目录不进入公开 Git。

这次交接是一次文件同步，未建立持续双向同步，未向活动 Claude/TUI 注入消息。VPS 上修改后需要明确地用 Git 或再次受控同步带回 Mac；不要将文件一致性称为 App 功能验收。
