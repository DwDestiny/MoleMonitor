---
title: "MoleMonitor Sources"
type: module
last_updated: 2026-10-13
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
| `PanelLayout.swift` | v2 面板版面计划：行顺序、异常项和面板高度（436 pt，台式机 396 pt）。异常区固定 36 pt，异常数量不改变高度 |
| `PanelRowText.swift` | 主列全部文字的唯一来源：行状态（点、名称、读数）、异常条、底栏、异常区的一行、迷你曲线数据。缺失、统计中、过期和测得的零值显示不同 |
| `PanelWindowGeometry.swift` | 面板窗口的纯几何：菜单栏图标位置和屏幕可见区得出窗口框（侧栏关闭与打开）、动效常量、点击策略 |
| `HoverIntent.swift` | 侧栏悬停意图状态机（W06 的 Core 部分）：静止 350 ms 打开，快速移动重新计时，固定后忽略指针。无时钟、无定时器，调用方传入时间 |
| `SidebarContent.swift` | v2 侧栏内容规划：范围、图表数据（线、柱、时间带、读数文字）、统计、排行表、记录分组、脚注 |
| `RollupStore.swift` | 5 分钟汇总文件 `rollup-YYYY-MM.ndjson` 的聚合、追加、读取、清理，供 24 小时与 7 天曲线。只存数字与枚举 |
| `EventLog.swift` | `events.json`：问题段记录、原子写、上限，`EventTracker` 把等级变化转为记录。只存 App 显示名 |
| `InterfaceRates.swift` | 两次网卡计数器读数得出每个物理网卡的速率与累计量。物理网卡取自 `NetworkFilter.isPhysical`，VPN 不重复计入 |
| `MemoryBreakdown.swift` | 内存拆分（App、联动、压缩，已用与可用）、`PressurePercent.from(level:)`、磁盘三元组 `DiskCapacity`。空值表示未测得 |
| `CapacityText.swift` | 容量文字的唯一格式化器：总量、已用、可用，一个单位，已用加可用等于总量（W19）。磁盘用十进制 GB，内存用二进制 GB |
| `Prompt.swift` | “复制给 Agent”的中文提示文本与隐私文字脱敏 |
| `StatusExtras.swift` | `status.json` 的新增字段，App 与 `molemonitor-cli prompt` 之间的约定 |
| `AppUsage.swift` | 占用 App 的 CPU 与内存排行、窗口均值和单应用 CPU 规则的输入 |
| `TrendBuffer.swift` | 内存环形趋势缓冲，输出按间隙分段的序列和 2 小时 CPU 摘要 |
| `TrendStore.swift` | `trend.json` 的编码、原子写（0600）和容错读取 |
| `SleepStore.swift` | 睡眠掉电记录的小型持久化，重启后恢复 |
| `NotificationPlanner.swift` | 通知规则：按送达顺序决定要发的通知 |
| `MenuIconModel.swift` | 健康状态到菜单栏图标状态（姿态与角标）及无障碍文字的映射，不含绘制 |
| `MenuRunner.swift` | 菜单栏奔跑图标（v3）：姿态（站立、奔跑 4 帧）、侧视比熊剪影的基本图形、奔跑迟滞（≥35% 开始，连续 2 个 tick <25% 停止）、三档速度、动效条件、提示文字后缀 |
| `DogArt.swift` | 比熊各部件、菜单栏头部和角标图形的贝塞尔路径数据，不含绘制 |
| `DogRig.swift` | 比熊动画数学：每帧的部件变换参数与变换后的图层列表。`DogRig.bubbleLayers` 单独给出关注气泡的图层（位图比熊用） |
| `DogArtPose.swift` | 位图比熊的选图：`DogArtPose`（8 个姿态）与 `DogArtSelector`（平滑、迟滞、最短保持 4 秒，无定时器，由调用方逐个数据点推进）。规则见 [DESIGN.md 4.9](../docs/DESIGN.md#49-位图阶段) |
| `BubbleCopy.swift` | 面板标题文案的唯一来源：`BubbleInput` 到 `BubbleText`（主行、证据、等级）。标题 17 pt、内容宽 320 pt，每行不超过 18.4 em，最多 2 行，长句在逗号处换行。采集中写“正在检查，已完成 N/6 项”。类型名沿用 Bubble*，气泡本身已删除（U10） |
| `HeroLogic.swift` | 标题块的纯逻辑：`HeroFacts`（从判定与读数取文案输入和证据）、`HeroProgress`（6 项读数到齐几项）、`HeroBrain`（标题文本，数字 30 秒内不变）。比熊动作、点按、彩蛋已删除（U10） |

## App 文件

| 文件 | 职责 |
|---|---|
| `Engine.swift` | `MonitorEngine`：一个 30 秒 tick，睡眠与唤醒，写 `status.json`，`alert-state.json` 与 NDJSON。状态卡打开时启动 2 秒实时采样定时器，关闭时取消并清空缓冲 |
| `Sampler.swift` | 读磁盘容量、`sysctl` 网卡计数器、开机时间。只读 |
| `Notifier.swift` | `UNUserNotificationCenter` 授权与发送。无 App 包时报告 `unavailable` |
| `StatusIcon.swift` | `StatusIconController`：菜单栏图标的唯一所有者。CPU 不忙时显示站立帧，没有图标计时器；CPU 忙时用 1 个计时器播放 4 帧奔跑（4、6、8 fps）。健康标记（黄 ▲、红 ■）不动。Reduce Motion、锁屏、显示器睡眠、图标隐藏、低电量模式时回到站立帧并停止计时器。绘制在 `MenuRunnerShapes.swift` |
| `MenuRunnerShapes.swift` | `MenuRunnerRenderer`：菜单栏比熊剪影的矢量绘制（实心、空心、标记）；`MenuRunnerFrameCache`：按姿态、状态、深浅、倍率缓存帧位图 |
| `Clipboard.swift` | 把文本写入通用剪贴板，触控板上给一次轻触反馈 |
| `ProcessSampler.swift` | 用 libproc 读进程列表，输出 `ProcessSample` 与覆盖率。排名在 Core 的 `AppRanking` |
| `SystemSampler.swift` | 读每核 CPU tick、网卡计数器、内存压力和机器信息。取代旧的 `LiveSampler` |
| `DogShapes.swift` | 用 Core Graphics 绘制状态卡比熊和菜单栏模板图标，路径只建一次并缓存 |
| `GlyphPaths.swift` | 类别角标路径，菜单栏角标、气泡和卡片类别图标共用 |
| `GlyphGrids.swift` | 菜单栏图标的角标、数据标记和告警字形在 1x 下的 alpha 栅格（`UITestIconChecks.swift` 用它们做异或矩阵）。从已删除的 `DogGallery.swift` 保留下来 |
| `UITestIconChecks.swift` | 菜单栏图标门禁 W08（9 个场景对手写期望表，浅深色头部墨迹与角标颜色，五态两两异或）和门禁 A 的辅助函数 `headInkCheck`。整个文件在 `#if UITEST` 内 |
| `UITestWindowChecks.swift` | 窗口门禁 W03（打开速度、无白闪）、W05（侧栏窗口动效）、W06（窗口内悬停意图）、W10（Esc 层级与关闭）。整个文件在 `#if UITEST` 内 |
| `PanelModel.swift` | 状态卡的数据与界面状态：`PanelData`、版面计划、手风琴、复制状态机。引擎适配器 `PanelEngineAdapter` 读取 `MonitorEngine` 的已发布属性，复制调用 `engine.prompt(scope:)` |
| `PanelRoot.swift` | 面板根视图：主列（352 pt：英雄区、六行、异常区、底栏）和打开时的侧栏（320 pt）。按版面计划渲染，不排序。入场动画：每次启动一次完整入场，之后淡入 |
| `PanelWindow.swift` | `PanelWindow`：自定义 `NSPanel`，取代 `NSPopover`。窗口放在菜单栏图标下，开关动效，点击与按键，事件监视器（只在显示时存在），侧栏窗口动画，侧栏悬停规则。无周期定时器，延迟调用是可取消的任务。实现 `PanelChrome`，调用 `PanelPinning` |
| `PanelChrome.swift` | 窗口与内容之间的两个协议：`PanelChrome`（窗口服务内容）、`PanelPinning`（内容服务窗口）。只有协议，无 AppKit 类型 |
| `PanelRows.swift` | 主列的六行：状态点、名称与说明、右对齐读数、80 × 24 pt 迷你曲线。行高 40 pt |
| `PanelAnomaly.swift` | 主列的异常区：固定 36 pt 的一行（安静、统计中、过期或异常摘要） |
| `PanelSidebar.swift` | 侧栏列（320 pt）：标题、范围控件、图表、统计、容量区、排行、脚注、异常记录。只在侧栏打开时构建，关闭即释放 |
| `PanelHero.swift` | 标题块 320 × 64 pt：一句话，`PanelType.lead`（17 pt），最多 2 行。背后是预渲染的状态光（352 × 96 pt，黄 10%、红 12%、深色 16%，正常无光，等级变化 400 ms 交叉淡变）。采集中超过 0.5 s 才显示标题。签名 `PanelHero(data:quiet:)` |
| `PanelCharts.swift` | 数字过渡修饰器和面板共用的小工具。侧栏图表用 `Path` 手绘，不用 Swift Charts（W07） |
| `PanelFooter.swift` | 底栏：一个主按钮 `btn.copy`（复制提示词或巡检请求）和“…”按钮及其 `NSMenu`（菜单项标识符 `menu.*`）。按钮样式 |
| `PanelTokens.swift` | 颜色、字号、动效、尺寸令牌（含 `rowFill`、`rowBackground`、`rowBar`），格式化函数，灯，流式布局 |
| `PanelPreview.swift` | `--preview` 渲染静态图：主列 28 张（7 个场景，浅深两种外观，满数据与空数据，352 pt 宽，2 倍），侧栏各项加异常记录，在 `multi` 场景上 |
| `UITestPanelChecks.swift` | 面板界面门禁 M4 至 M6、M11 至 M14、M19（无占位文本）、N1、N2，W16（关闭零成本，U10 起在本文件），以及 W01、W02（取代 M2、M3、M22）、W07、W09、W19、W22。整个文件在 `#if UITEST` 内 |
| `UITestHarness.swift` | 界面回归测试代码（检查 A 至 L）和登记检查的运行器。整个文件在 `#if UITEST` 内，只存在于 `scripts/build.py --ui-test` 的变体 |

## 入口模式

| 参数 | 行为 |
|---|---|
| 无参数 | 启动菜单栏 App |
| `--self-test` | 用合成磁盘历史检查增长量、磁盘等级和缺失值编码 |
| `--diagnose --seconds N` | 无界面运行引擎，输出状态 JSON。N 取 5 至 1800，默认 22。未设 `MOLEMONITOR_DATA_DIR` 时使用临时数据目录 |
| `--preview <绝对路径前缀>` | 导出静态面板图（主列 28 张加侧栏图，PNG） |
| `--ui-test --ui-test-out <目录>` | 只存在于 `-D UITEST` 构建。运行界面回归，输出 `ui-report.json` 与截图 |

> **注意**：`App/` 和 `MoleMonitor.swift` 已通过 CI 回归门禁（macOS 虚拟机），但没有真机验收。`Sensors.swift` 的运行行为尚未验证。验证状态见 [VERIFICATION.md](../docs/VERIFICATION.md)，CI 说明见 [CI.md](../docs/CI.md)。

比熊的序列帧与位图素材（`Resources/DogSprites/`、`Resources/DogArt/`）已于 2026-10-18 删除（U10）。`scripts/build.py` 不再复制资源，包内没有 `Contents/Resources/DogArt`。

测试源码在 [Tests/](../Tests)：`CoreTests/` 测 Core（含 `DogArtPoseTests.swift`、`BubbleCopyTests.swift`、`HeroLogicTests.swift`、`HoverIntentTests.swift`），`CliTests/make_status/` 生成 CLI 测试数据。
