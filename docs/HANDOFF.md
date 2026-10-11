---
title: "MoleMonitor · Claude 接手说明"
type: handoff
last_updated: 2026-10-11
---

# Claude 接手说明

当前交接的是可构建的 macOS 只读监控开发版，真实菜单栏交互和长期运行仍待验收。项目同步到 Linux VPS 后，可以继续方案讨论、源码修改和文档工作；Swift/AppKit/IOKit 构建、传感器读取与 App 的运行检查必须在 Apple Silicon Mac 上完成。Linux 静态检查不能替代这些结果。

## 已确定的范围

> **注意**：2026-10-11 产品方向已调整。`Sources/` 与 `scripts/` 里的代码尚未改动，仍是第一版（Go 采集器方案）。目标设计见 [PROJECT.md](PROJECT.md)。

新方向的要点：

- 工具只监测与预警，不做清理。清理由用户的 agent 按具体授权调用 Mole CLI。
- 菜单栏显示 CPU（小狗）、内存（方块点）、温度（水滴点）的健康等级。磁盘或睡眠掉电为红时，图标组右上角加红色角标。
- 磁盘、网速与流量、前 5 名应用放在状态卡里。电池循环次数和每应用耗电排行都不做。
- 磁盘短期大量增长、内存泄漏等严重问题发系统通知。问题消失后不发通知，界面和 CLI 也不显示"已恢复"。
- 提供独立 CLI 小二进制读取状态。
- 删除 Mole Go 采集器、`fetch_status.py`、`ps` 采样和 1 Hz 界面定时器。
- 不增加清理按钮、自动删除、sudo、特权 helper、SMC 写入或风扇控制。当前没有安装到 Applications、设置登录启动、公证或发布二进制 Release。

第一版代码的现有行为（尚未改动）：

- 菜单栏显示 CPU、内存占用和上下行网速。
- 展开后显示磁盘余量、内存压力、电池百分比、充电状态、循环次数、CPU 与电池温度、风扇 RPM。
- 按应用归并进程，提供 CPU 和内存 RSS 两种前五名排行。

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

2026-10-10 的 macOS 验证针对第一版代码：构建、协议自检、签名、首次无缓存构建和无效缓存拒绝。90 秒无界面诊断取得 44 帧。受控坏 JSON、分片和后端失响应后恢复采集，已知关联进程退出后无残留。资源采样 CPU 均值约 0.49%，峰值 RSS 37.9 MiB。这些结果只覆盖该次无界面运行，不证明长期耗电或完整 GUI 成本，也不适用于新方向的代码。完整口径见 [VERIFICATION.md](VERIFICATION.md)。原始系统快照和诊断图片保留在 Mac 的忽略目录，未作为公开源码或 VPS 开发材料分发。

下一步按 [PROJECT.md](PROJECT.md) 的阶段计划执行：

1. 阶段 1：删除 Go 采集器，实现磁盘采样、`status.json`、CLI 小二进制和磁盘通知。
2. 阶段 2：实现 CPU、内存、泄漏检测、前 5 名应用和网速与流量。
3. 阶段 3：实现温度与热状态，自绘比熊。
4. 阶段 4：实现睡眠掉电与通知。

每个阶段的"只能在 Mac 上做"项和验收标准见 [PROJECT.md](PROJECT.md) 的阶段计划与验证项。真实结果写入验证文档，新增记录不覆盖旧记录。

数据口径在新方向中的变化：缺失、失败、过期与测得的 0 继续分开表示。应用 CPU 继续使用单核 100% 的口径。网速只合计物理网卡，不重复计入 VPN。

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
