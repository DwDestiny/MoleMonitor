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
| `CurrentReadings.swift` | 当前读数和状态卡数据状态的值类型。空值表示未测得，不是零 |
| `HealthItems.swift` | 五个健康项、内存、温度、耗电和 swap 词汇、`ItemVerdict` |
| `HealthRules.swift` | CPU、内存、温度、耗电的判定规则与迟滞状态，纯函数 |
| `HealthAlerts.swift` | 判定对应的一句证据和一句给 Agent 的提示 |
| `HealthPipeline.swift` | 引擎的纯逻辑部分：每次评估得出五项判定、问题顺序和补全的读数 |
| `ProblemOrder.swift` | 灯、卡片、图标角标和提示共用的问题顺序 |
| `PanelLayout.swift` | 状态卡版面计划：区块顺序、三档高度（332、560、620）和压缩步骤 |
| `Prompt.swift` | “复制给 Agent”的中文提示文本与隐私文字脱敏 |
| `StatusExtras.swift` | `status.json` 的新增字段，App 与 `molemonitor-cli prompt` 之间的约定 |
| `AppUsage.swift` | 占用 App 的 CPU 与内存排行、窗口均值和单应用 CPU 规则的输入 |
| `TrendBuffer.swift` | 内存环形趋势缓冲，输出按间隙分段的序列和 2 小时 CPU 摘要 |
| `TrendStore.swift` | `trend.json` 的编码、原子写（0600）和容错读取 |
| `SleepStore.swift` | 睡眠掉电记录的小型持久化，重启后恢复 |
| `NotificationPlanner.swift` | 通知规则：按送达顺序决定要发的通知 |
| `MenuIconModel.swift` | 健康状态到菜单栏图标状态（姿态与角标）及无障碍文字的映射，不含绘制 |
| `DogArt.swift` | 比熊各部件、菜单栏头部和角标图形的贝塞尔路径数据，不含绘制 |
| `DogRig.swift` | 比熊动画数学：每帧的部件变换参数与变换后的图层列表 |

## App 文件

| 文件 | 职责 |
|---|---|
| `Engine.swift` | `MonitorEngine`：一个 5 分钟 tick，睡眠与唤醒，写 `status.json`，`alert-state.json` 与 NDJSON。状态卡打开时启动 2 秒实时采样定时器，关闭时取消并清空缓冲 |
| `Sampler.swift` | 读磁盘容量、`sysctl` 网卡计数器、开机时间。只读 |
| `Notifier.swift` | `UNUserNotificationCenter` 授权与发送。无 App 包时报告 `unavailable` |
| `StatusIcon.swift` | `StatusIconController`：把图标状态和提示文字应用到状态栏按钮，缓存图像 |
| `Clipboard.swift` | 把文本写入通用剪贴板，触控板上给一次轻触反馈 |
| `ProcessSampler.swift` | 用 libproc 读进程列表，输出 `ProcessSample` 与覆盖率。排名在 Core 的 `AppRanking` |
| `SystemSampler.swift` | 读每核 CPU tick、网卡计数器、内存压力和机器信息。取代旧的 `LiveSampler` |
| `DogView.swift` | 状态卡比熊视图。唯一可以用 `TimelineView` 的视图，调用方式 `DogView(input:size:)` |
| `DogShapes.swift` | 用 Core Graphics 绘制状态卡比熊和菜单栏模板图标，路径只建一次并缓存 |
| `GlyphPaths.swift` | 类别角标路径，菜单栏角标、气泡和卡片类别图标共用 |
| `DogGallery.swift` | `--dog-gallery` 导出所有静态姿态、菜单栏图标和角标的 PNG 图册 |
| `UITestDogChecks.swift` | 比熊动画门禁，输出 `dog-report.json`。整个文件在 `#if UITEST` 内 |
| `PanelModel.swift` | 状态卡的数据与界面状态：`PanelData`、版面计划、手风琴、复制状态机。引擎适配器 `PanelEngineAdapter` 读取 `MonitorEngine` 的已发布属性，复制调用 `engine.prompt(scope:)` |
| `PanelRoot.swift` | 状态卡根视图：固定的头部、滚动的中部、固定的底栏。按版面计划渲染，不排序。入场动画 |
| `PanelHero.swift` | 头部：比熊、标题、灯列（安静模式与问题模式） |
| `PanelProblem.swift` | 问题卡、问题行、其余正常行、证据区 |
| `PanelCharts.swift` | 图表：问题曲线（2 小时粗段加 5 分钟细段）、迷你线、磁盘 30 天图 |
| `PanelApps.swift` | 占用 App 行、证据列表、折叠行 |
| `PanelMore.swift` | “更多”折叠行及展开内容 |
| `PanelFooter.swift` | 按钮样式、复制按钮、授权行、底栏 |
| `PanelTokens.swift` | 颜色、字号、动效、尺寸令牌，格式化函数，灯，流式布局 |
| `PanelPreview.swift` | `--preview` 渲染 28 张静态图 |
| `UITestPanelChecks.swift` | 状态卡的界面门禁 M2 至 M6、M11 至 M14、M19、N1、N2。整个文件在 `#if UITEST` 内 |
| `UITestHarness.swift` | 界面回归测试代码（检查 A 至 L）。整个文件在 `#if UITEST` 内，只存在于 `scripts/build.py --ui-test` 的变体 |

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
