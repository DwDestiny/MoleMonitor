---
title: "MoleMonitor Sources"
type: module
last_updated: 2026-10-11
---

# Sources

自有 Swift 源码。先读 [AGENTS.md](AGENTS.md)。架构、口径和设计决定见 [PROJECT.md](../docs/PROJECT.md)。

## 目录结构

| 目录/文件 | 依赖 | 平台 | 职责 |
|---|---|---|---|
| `Core/` | 只依赖 Foundation | Linux 与 Mac | 健康规则、存储、状态文件、CLI 报告 |
| `App/` | AppKit、SwiftUI、UserNotifications、Combine、Darwin | 仅 Mac | 引擎、采样、通知、图标、状态卡 |
| `cli/` | 只依赖 Foundation 与 `Core/` | Linux 与 Mac | `molemonitor-cli` 入口 |
| `MoleMonitor.swift` | AppKit、SwiftUI | 仅 Mac | 入口分流和 App 生命周期 |
| `Sensors.swift` | IOKit | 仅 Mac | 只读电池、内存压力、SMC 温度与风扇。阶段 1 不引用，阶段 2 使用 |

## Core 文件

| 文件 | 职责 |
|---|---|
| `AppInfo.swift` | 版本号的唯一来源。`scripts/build.py` 读取它 |
| `Levels.swift` | 健康等级、值状态、带状态的测量值、UTC 日期工具、JSON 编解码器 |
| `DiskSample.swift` | 磁盘样本模型，按月 NDJSON 的追加、读取和清理 |
| `DiskGrowth.swift` | 1 天、5 天、30 天窗口的增长量与净变化，流量分段累加 |
| `DiskHealth.swift` | 磁盘等级与迟滞，通知决策与中文文案，`DiskAlertState` |
| `NetworkFilter.swift` | 物理网卡过滤，网速计算，路由消息解析，样本组装，引擎单步评估，通知预算，文件辅助函数 |
| `StatusFile.swift` | `status.json` 模型，原子写，容错读，新鲜度判断 |
| `StatusReport.swift` | `--status` 报告：状态加 `read_at`、`age_seconds`、`app_running`、`fresh`、`recomputed` |
| `DiskReport.swift` | `--disk-history` 的按日汇总 |
| `Brief.swift` | `--status --brief` 的一行中文 |
| `Paths.swift` | 数据目录与 `status.json` 路径，环境变量 `MOLEMONITOR_DATA_DIR` |
| `RingSeries.swift` | 固定容量环形缓冲，实时曲线用 |
| `CPULoad.swift` | 由两次每核 tick 算整机 CPU 百分比。计数器回退时返回空值 |
| `LiveSnapshot.swift` | 实时卡的数据：60 秒窗口，2 秒间隔，最多 32 个点，速率文字 |
| `DiskSeries.swift` | 30 天磁盘面积图的降采样序列和触发异常的增长段 |
| `PreviewScenario.swift` | `--preview` 与测试用的虚构数据。App 运行时不调用 |

## App 文件

| 文件 | 职责 |
|---|---|
| `Engine.swift` | `MonitorEngine`：一个 5 分钟 tick，睡眠与唤醒，写 `status.json`，`alert-state.json` 与 NDJSON。状态卡打开时启动 2 秒实时采样定时器，关闭时取消并清空缓冲 |
| `Sampler.swift` | 读磁盘容量、`sysctl` 网卡计数器、开机时间。只读 |
| `Notifier.swift` | `UNUserNotificationCenter` 授权与发送。无 App 包时报告 `unavailable` |
| `StatusIcon.swift` | 菜单栏图标绘制与缓存，无障碍文字 |
| `LiveSampler.swift` | 读 Mach 每核 CPU tick 与网卡计数器。状态卡打开时创建，关闭时释放 |
| `Panel.swift` | SwiftUI 状态卡，宽 340 pt，高度不超过 480 pt。磁盘趋势图（Swift Charts），实时卡，入场动画 |
| `UITestHarness.swift` | 界面回归测试代码。整个文件在 `#if UITEST` 内，只存在于 `scripts/build.py --ui-test` 的变体 |

## 入口模式

| 参数 | 行为 |
|---|---|
| 无参数 | 启动菜单栏 App |
| `--self-test` | 用合成磁盘历史检查增长量、磁盘等级和缺失值编码 |
| `--diagnose --seconds N` | 无界面运行引擎，输出状态 JSON。N 取 5 至 1800，默认 22。未设 `MOLEMONITOR_DATA_DIR` 时使用临时数据目录 |
| `--preview <绝对路径>` | 导出静态状态卡图（3 个等级，浅色与深色，共 6 张 PNG） |
| `--ui-test --ui-test-out <目录>` | 只存在于 `-D UITEST` 构建。运行界面回归，输出 `ui-report.json` 与截图 |

> **注意**：`App/` 和 `MoleMonitor.swift` 已通过 CI 回归门禁（macOS 虚拟机），但没有真机验收。`Sensors.swift` 的运行行为尚未验证。验证状态见 [VERIFICATION.md](../docs/VERIFICATION.md)，CI 说明见 [CI.md](../docs/CI.md)。

测试源码在 [Tests/](../Tests)：`CoreTests/` 测 Core，`CliTests/make_status/` 生成 CLI 测试数据。
