---
title: "MoleMonitor · CI 回归门禁"
type: ci
last_updated: 2026-10-18
---

# CI 回归门禁

GitHub Actions 在每次改动源码或脚本的提交后构建 App，并运行回归检查。结果是回归门禁，不是真机验收。工作流文件是 [build-mac.yml](../.github/workflows/build-mac.yml)。

## 工作流做什么

工作流 `build-mac` 只有一个作业 `build-test`，运行在 `macos-15`。步骤按顺序执行：

| 步骤 | 内容 |
|---|---|
| 1. Toolchain | 输出系统版本、芯片、Xcode 和 `swiftc` 版本 |
| 2. Core and CLI tests | `scripts/test_core.py`（4968 条断言，输出同时写入 `$RUNNER_TEMP/core-tests.log`）与 `scripts/test_cli.py`（124 项检查） |
| 3. Build app | `python3 scripts/build.py`，输出 `dist/` |
| 4. Build UI test variant | `python3 scripts/build.py --ui-test`，输出 `dist-uitest/` |
| 5. Acceptance and UI regression gate | `python3 scripts/ci_acceptance.py`，检查项见 [scripts/README.md](../scripts/README.md) |
| 6. Upload | 上传 artifact `molemonitor-ci`，保留 3 天，即使前面步骤失败也上传 |

触发条件：推送到任意分支（`branches: ["**"]`）且改动了 `Sources/`、`Tests/`、`scripts/`、`Vendor/` 或工作流文件（`Resources/` 路径已随比熊素材删除，U10），或手动触发（`workflow_dispatch`）。

## 成本与免费额度

| 约束 | 值 | 依据 |
|---|---|---|
| 运行器 | `macos-15` | 公开仓库使用标准运行器免费。`macos-14` 将于 2026-11-02 退役，因此不用 |
| 作业数 | 1 | 不加多系统或多版本矩阵 |
| 超时 | `timeout-minutes: 30` | 防止卡死后占用运行器。2026-10-13 从 20 改为 30，原因见下文“UI 测试总时长” |
| 触发 | 路径过滤，无 `schedule` | 文档改动不触发。不做定时运行 |
| 并发 | `cancel-in-progress: true`，分组按分支 | 同一分支的新提交取消旧运行。不同分支的运行互不取消 |
| 权限 | `contents: read` | 工作流不写仓库 |

> **警告**：不要把仓库改为私有，除非先复核计费。私有仓库的 macOS 运行器按分钟计费，并且倍率高于 Linux。改为私有后，本工作流会开始产生费用。

> **警告**：不要给 `build-mac.yml` 加 `schedule`，不要加多系统矩阵，不要去掉超时。这些改动会增加用量。

免费额度和退役日期来自 GitHub 的公开说明。额度规则可能变化。改动工作流前，先到 GitHub 文档复核。

## 如何读结果

1. 列出最近的运行：`gh run list --workflow build-mac.yml`。
2. 实时跟踪一次运行：`gh run watch`。
3. 查看失败步骤的日志：`gh run view <run-id> --log-failed`。
4. 下载 artifact：`gh run download <run-id> -n molemonitor-ci`。如果省略 `<run-id>`，`gh` 会让你选择。

日志中每个检查输出一行 `PASS`、`FAIL` 或 `SKIP`。最后一行是 `ACCEPTANCE PASSED` 或 `ACCEPTANCE FAILED`。`SKIP` 不是通过，也不是失败，日志末尾会集中列出。

artifact 的内容：

| 文件 | 内容 |
|---|---|
| `preview-<场景>-<外观>[-empty].png` | 28 张静态状态卡图：7 个场景（allGreen、collecting、stale、cpuYellow、diskRed、powerYellow、multi）各有 light 与 dark，各有完整数据与 `-empty`（无历史）两种 |
| `status.json` | 22 秒无界面采样写出的状态文件 |
| `ui-*.png` | `--ui-test` 的窗口截图。`ui-m-<场景>-<light|dark>.png` 是各场景的真实弹窗截图 |
| `ui-report.json` | `--ui-test` 的报告：各项状态、数值、主线程间隔统计 |

## UI 测试总时长

`scripts/ci_acceptance.py` 给整个 `--ui-test` 运行 420 秒的总时间预算（`ui_budget`）。超过预算时，脚本终止进程，并报告 `FAIL  UI test finished within 420 s`。这个预算是运行时长上限，不是质量阈值。

| 日期 | 预算 | 作业超时 | 原因 |
|---|---|---|---|
| 2026-10-13 之前 | 170 s | 20 分钟 | v1 门禁约 40 项，main 上实测 151.6 s |
| 2026-10-13 起 | 420 s | 30 分钟 | v2 新增约 20 个门禁（W02 至 W22，例如 W05 单项约 10.6 s）。run 38338270673 在 170 s 时只跑到 W06，W07、W10、W13 至 W22 与 K 都没有运行。上一次完整作业用时 16.3 分钟，UI 测试占 170 s，新预算下预计全程约 20 分钟 |

UI 测试每个门禁结束时先输出一行 `GATE <编号> <状态> <毫秒> ms <名称>`，再输出完整说明。脚本逐行读取输出，把 `GATE ` 行和 `registered check ` 行立即打印到 CI 日志（前缀 `ui-test: `）。因此，如果运行再次超时，日志的最后一行 `GATE` 就是最后一个结束的门禁。

> **注意**：不要用提高预算的方法掩盖单个门禁变慢。如果某个门禁明显变慢，先修这个门禁，再考虑预算。

## `--ui-test` 各项

`--ui-test` 运行测试变体里的真实 `NSStatusItem`、`NSPopover` 与引擎。它用合成事件做交互，使用预置的红色磁盘历史和临时数据目录。

| 项 | 名称 | 检查内容 |
|---|---|---|
| A | 状态栏与图标 | 菜单栏按钮有图标，红色磁盘等级时图标是模板图像，角标为磁盘，姿态为喘气，无障碍文字含“磁盘” |
| B | 打开 | 点击后状态卡显示，窗口可见，实时采样在 1.5 秒内启动，定时器共 2 个，冷启动首次打开的主线程最长间隔小于 600 ms |
| C | 入场动画在推进 | 用窗口截图或图层数值，确认完整入场动画在推进并最终稳定。截图时刻为 0 到 900 ms 的 8 帧。窗口与入场强制关闭 RM，狗与气泡跟随系统设置。原因：CI 虚拟机把系统“减少动态效果”报告为打开，不强制关闭时入场退化为淡入，测不到推进 |
| D | 实时数据流入面板 | 面板模型中的趋势点数递增，相邻截图的像素有变化 |
| E | 主线程流畅度 | 120 Hz 定时器测主线程间隔：要求 p95 小于 40 ms，max 小于 250 ms |
| F | 悬停交互 | 合成鼠标悬停到磁盘图上，图的像素发生变化 |
| G | 按钮交互与降级文案 | 授权状态为“未决定”时，授权按钮可点。其他状态时，降级文案符合预期 |
| H | 关闭 | 按 Esc 在 400 ms 内关闭，实时定时器停止，缓冲清空，视图控制器被释放 |
| I | 再次打开 | 第二次打开比第一次更快稳定（150 ms 淡入），实时采样重新启动，定时器共 2 个。动效状态与 C 相同。原因：CI 虚拟机报告 RM 打开，RM 下完整入场也是 150 ms 淡入，两次打开无法区分 |
| J | 深浅色 | 浅色与深色外观的截图都非空白，且彼此不同 |
| K | 退出 | 点击“退出”按钮，进程以退出码 0 结束，`status.json` 在退出时被写入 |
| L | 关闭面板零成本 | 关闭 3 秒后，实时采样为关，只剩 1 个定时器（5 分钟 tick），缓冲为空，CPU 小于 5% 单核 |
| M1 | 场景互不相同 | 28 个主列预览两两不同（sha256），stale 满数据与空数据的两对除外（v3） |
| M2 | 问题优先排序（v2：由 W02 取代，见下文） | 区块的纵向顺序等于 `ProblemOrder`，灯的顺序与区块一致 |
| M3 | 高度分档（v2：由 W02 取代。v3 高度随问题行数变化，见“v3 门禁改动”） | 弹窗高度为 332（安静）、560（单项或双项问题）、620（多项问题） |
| M4 | 刷新与展开不改高度 | 10 次刷新、点击行、展开占用 App 与更多后，弹窗高度变化为 0 |
| M5 | 对比度 | 浅色与深色下，正文对比度不低于 4.5，灯与曲线不低于 3 |
| M6 | 大字号 | 字号放大到 1.25 倍后，`PanelSlots.all` 中没有文字被截断 |
| M11 | 焦点环 | 第一响应者不是 NSControl，`btn.copy`、`btn.more`、`row.0` 周围 4 pt 内没有焦点环像素。collecting 场景 `btn.copy` 必须不存在（v3） |
| M12 | 冷启动首帧 | diskRed 场景磁盘问题行 `row.disk.spark` 的线条像素在 300 ms 内出现（v3） |
| M13 | 复制 | 复制的文字等于 PromptBuilder 的文字，不含家目录与用户名，按钮显示“已复制”后在 1.5 秒（误差 0.3 秒）内恢复 |
| N1 | 真实引擎复制 | 引擎驱动的面板，复制文字等于 `PromptBuilder` 对引擎输入的结果，长度不超过 3000，不含家目录与用户名，含“磁盘” |
| N2 | 打开即有历史 | 用 `trendSeed` 模拟重启后恢复的 2 小时趋势，面板打开的同一刻模型已有不少于一半的种子点 |
| M14 | 菜单栏图标状态 | 7 个场景下，`MenuIconModel` 与 `AppDelegate` 交给 `StatusIconController` 的姿态和角标等于手写期望表。v3 改写见“v3 门禁改动”：非模板图，标记只按等级区分 |
| M19 | 面板无占位文本 | 无障碍树（allGreen 与 diskRed 两个场景）不含骨架占位文本。原 M19 的比熊像素检查已删除，见“已删除的门禁” |
| M22 | 浅深色折叠问题卡（G2 第 1、2 轮。v2：由 W02 取代，见下文） | multi，浅色与深色各验。3 张折叠问题行的底与面板底色相差 ≤ 20，色相（通道最大差）≤ 4，左缘 3 pt 色条与本级灯色相差 ≤ 30 并比另一级更近。第一张问题卡有淡底（色相 ≥ 6） |

## 已删除的门禁（U10，2026-10-18）

用户原话 U10：“还有这个比熊，动画的效果始终达不到我想要的效果，实在不好弄，我觉得可以删除，另外，关于状态栏，可以做成简单的静态、奔跑，以这种简单的帧动画来体现系统的状态”。面板里没有比熊，序列帧、位图静帧、图库和道具随之删除。下表列出每条被删除的门禁，写明旧数值和去向。没有一条门禁靠放宽阈值删除。

> **注意**：`--dog-gallery`、`--dog-checks`、`dog-report.json`、工作流步骤 “Dog gallery” 和 artifact 路径 `molemonitor-dog/` 全部删除。`Resources/DogArt`、`Resources/DogSprites` 与 `scripts/check_sprites.py` 删除，`scripts/build.py` 不再复制它们，也不再检查“8 个文件”。

| 编号 | 旧检查与旧数值 | 去向 |
|---|---|---|
| M19 | 7 个场景浅深截图里比熊区域非背景像素：动态不少于 1%，静态灰不少于 1.5%，至少 12 种颜色。另含无障碍树无占位文本 | 比熊像素部分删除。占位文本部分保留，编号 M19 不变，名称改为“面板无占位文本” |
| M19V | 关闭位图开关后，矢量比熊门槛同 M19 | 删除，矢量比熊不再出现在面板 |
| M20 | 空闲 3 秒位图视图 body 评估 0。注入 5 个数据点，姿态依次为冲刺、喘气、关注、走、灰化 | 删除 |
| M21 | 气泡包围框与比熊身体包围框相距 ≥2 pt，比熊框宽 ≥64 pt，框顶距面板顶 ≥6 pt | 删除，没有气泡和比熊 |
| DA | 卡片打开 3 秒内 60 至 80 帧 | 删除 |
| DB | 关闭后 3 秒内 0 个帧回调 | 删除。“关闭后无动画和计时器”由 W16 继续检查 |
| DC | 步态切换时腿速不超过 `DogGaitRules.maxLegRate` | 删除 |
| DD | 菜单栏切换最多 8 帧、最多 600 ms，之后无计时器 | 删除。菜单栏图标改为静态与奔跑，新检查由 P3 登记 W29、W30 |
| DE | Reduce Motion 下无帧、无计时器 | 删除。新检查由 P3 登记 W30 |
| DF | 发布二进制不含 `DogFrameProbe`、`UITestDogChecks`、`--dog-checks`、`DogBitmapProbe`、`UITestBitmapChecks`，UI 变体含探针 | 保留并改写：标记换成 `DogFrameProbe`、`UITestPanelChecks`、`UITestIconChecks`，UI 变体含 `DogFrameProbe`（正控）。输出文字改为 “RELEASE BINARY AUDIT” |
| BA | 位图卡片打开与关闭各 3 秒，body 评估与矢量帧为 0 | 删除 |
| BB | Reduce Motion 下 4 次姿态切换无淡变 | 删除 |
| BC | 8 个位图文件加载，每张 320 × 240 | 删除，`ci_acceptance.py` 改为检查包内没有 `DogArt` 与 `DogSprites`，源码树没有 `Resources/` |
| BD | 72 × 54 pt 下 7 个姿态两两异或比例 ≥0.20 | 删除 |
| BE | 非背景像素占比：灰化 ≥1.5%，其余 ≥1% | 删除 |
| BF | 地面阴影中心与脚底线相差 ≤2 px | 删除 |
| BS | 4 张联系表已写出（体积 >8000 字节） | 删除 |
| W04 | 注入 10 个数据点，300 ms 内动作与变体等于期望。CPU 从 5% 升到 95% 时步频单调、相差 ≤2%、倍率变化 ≤0.25 | 删除，没有动作。Core 测试 `DogActionTests` 一并删除 |
| W08 | 菜单栏五态。UI 部分（9 个场景、五态 XOR ≥0.20、字形 XOR ≥0.35、红圆盘 ≥0.30、角标对比 ≥3:1、宽 24 pt） | UI 部分保留，仍在 `UITestIconChecks.swift`，直到 P-icon 用 W29 替换。图库部分（`--dog-gallery` 导出的 `menu-metrics.json`、五态联系表）删除。辅助函数移到 `GlyphGrids.swift` |
| W11 | 条带：10 个动作 57 帧，每帧 320 × 240 px，条带 9 张，静止帧两两异或，缺文件降级 | 删除，素材与 `scripts/check_sprites.py` 一并删除 |
| W12 | 气泡与比熊不透明像素距离 ≥4 pt，气泡宽 ≤192 pt，≤2 行 | 删除。文案行宽改由 Core 单测 `BubbleCopyTests` 检查：17 pt、320 pt 内容宽，每行 ≤18.4 em，≤2 行（W13 的一部分） |
| W14 | 主线程每帧工作：打开 10 s 稳态 body 评估 ≤每 2 s 一次，比熊视图 draw 0，无 `CADisplayLink`。源码审计不含 `Timer`、`TimelineView` | 运行时部分删除。源码审计保留，范围是 `Panel*.swift`，不再含 `DogSpriteView.swift` |
| W15 | Reduce Motion：稳态 CA 动画数 0，侧栏展开无尺寸动画，气泡无缩放，对照组动画数 >0 | 删除（原检查依赖比熊图层）。动效退路的新检查由 P3 登记 |
| W17 | 打开 10 s 稳态进程 CPU 均值 ≤3% | 检查代码在已删除的精灵检查文件里，随之删除。**限值 3% 不变**，DESIGN_V3.md 第 8 章仍要求它，由 P3 在新文件里恢复 |
| W18 | 播放全部 10 个动作后精灵缓存 ≤8 MB，资源包 ≤4 MB | 删除，没有精灵。包体减少约 2.9 MB（`DogSprites` 2.5 MB 加 `DogArt` 0.4 MB） |
| W16（部分） | 关闭 3 s 后：精灵缓存 0 字节 | 只删这一条。其余不变：实时采样关、1 个引擎计时器、0 个 CA 动画、实时缓冲清空、进程 CPU <5%（最好的一个窗口）。检查代码移到 `UITestPanelChecks.swift`，输出值 `spriteBytesOpen` 删除 |
| W03（探针） | 点击到比熊区域就绪 ≤150 ms，首帧比熊墨迹 ≥1% | 探针对象由比熊区域改为标题块文字区域（`txt.hero.title`），门槛 ≤150 ms 与 ≥1% 不变，输出值改名为 `headlineReadyMs`、`headlineSharePercent` |
| W05（探针） | 侧栏漂移测量使用比熊区域做图块 | 图块改为标题块文字区域，门槛不变 |

## v3 门禁改动（2026-10-18，P3）

面板 v3 的设计改变了版面，因此一批 v2 门禁的期望值过时。本节为每条改动写一个条目：旧值、新值、理由。每条先查证原因，再改门禁。没有一条靠放宽阈值通过。引用的用户原话：

- U9：“我现在认为整体视觉需要大优化，可以一定程度损失一些性能，只要不过分就行了”。
- U10：“还有这个比熊，动画的效果始终达不到我想要的效果，实在不好弄，我觉得可以删除，另外，关于状态栏，可以做成简单的静态、奔跑，以这种简单的帧动画来体现系统的状态”。

基线是 v3/design 上的 CI run 39127149810。它的失败项都来自设计改变，没有回归。

### 改写的门禁

| 编号 | 旧值 | 新值 | 理由 |
|---|---|---|---|
| M3 预览高度 | 每个预览 436 pt（像素高 872）。所有预览同高 | 每个预览的期望高度来自 `PanelLayout.height` 的公式：全绿 264 pt，每个问题行加 64 pt 与 4 pt 间隙，最多 3 行。`scripts/ci_acceptance.py` 从 `PanelLayout.swift` 读取 `PanelMetrics`，按每个预览的问题数求值：allGreen、collecting、stale 为 264 pt，cpuYellow、diskRed、powerYellow 为 328 pt，multi 为 436 pt。同一场景的 4 个文件（浅、深、满数据、空数据）必须同高。预览是 2 倍像素，容差 2 px 不变 | U9、DESIGN_V3.md 3.3：高度随问题行数变化。run 39127149810 实测 528、656、872 px，等于 264、328、436 pt。Core 测试 `LayoutTests.swift` 用 `PreviewScenario` 固定每个场景的问题数和高度，因此脚本里的问题数表不会悄悄漂移 |
| M3 同高 | “每个预览同高” | 删除，由上一行的“同一场景同高”取代 | 高度随问题数变化是设计要求（DESIGN_V3.md 3.3 规则） |
| W02（含别名 M2、M3、M22）高度 | 公式 12 + 64 + 8 + 项数 × 40 + 12 + 36 + 12 + 40 + 12 = 436 pt | 公式按 3.3 逐项写出：正常行 28 pt 两列，问题行 64 pt 加 4 pt 间隙，最多 3 行。同时与 `PanelLayout.height` 与 `plan.height` 比较，差值 ≤0.01 pt | 同上。旧公式是 v2 的固定高度 |
| W02 底色 | 只有第 1 个问题行有等级底色，其余行无色 | 前 `problemRowCount` 个问题行都有各自等级的底色（浅色 6%、深色 10%，容差 30 不变）。其余行无色（色相差 ≤4 不变） | DESIGN_V3.md 5.1：所有问题行都有底色。run 39127149810 的 multi 里内存与电池行有底色，旧检查误报 |
| W22 右缘 | 所有行的数值右缘相差 ≤0.5 pt | 分三组：问题行、正常行左列、正常行右列，每组右缘相差 ≤0.5 pt。问题行右缘等于正常行右列右缘（±0.5 pt）。等宽数字检查不变 | DESIGN_V3.md 5.2：正常行分两列，左列数值止于 160 pt，右列止于 328 pt。旧检查要求单一右缘，v3 版面不可能满足 |
| M1 / W01 两两不同 | 28 个主列预览两两不同（sha256） | 同上，但“stale 满数据”与“stale 空数据”（浅、深各一对）允许相同。这两个文件仍必须与其余 26 个文件不同。`scripts/ci_acceptance.py` 与 `stepW01` 都按此执行 | 查证：stale 面板没有问题行，没有曲线，记录行只写过期文字（DESIGN_V3.md 5.3），正常行的数值取自当前读数而不是趋势。满数据与空数据的差别（趋势、App、睡眠记录）只出现在侧栏，因此主列像素相同。collecting 的两个版本不同（满数据时 CPU 与电池有数值），所以不豁免。阈值没有改 |
| M11 焦点环 | 对 `btn.copy`、`btn.more`、`row.0` 取框，缺一个框就失败 | collecting 场景改为断言 `btn.copy` 不存在（按钮隐藏）。其余场景和对象不变，焦点环像素必须为 0，第一响应者不是 NSControl | 查证：不是回归。run 39127149810 的失败原因只有“collecting: no frame for btn.copy”。DESIGN_V3.md 5.4 和 5.5 规定采集中隐藏主按钮。日志里的 “ring pixels 0” 是通过的数值。`PanelRows.swift`、`PanelFooter.swift`、`PanelAnomaly.swift` 没有改 |
| M12 首帧曲线 | 目标 `row.cpu.spark`（场景 allGreen），300 ms 内有 ≥30 个线条像素 | 目标 `row.disk.spark`（场景 diskRed 的磁盘问题行），阈值不变：300 ms，≥30 个线条像素 | DESIGN_V3.md 5.1、5.2：只有问题行有曲线，正常项是静区 |
| M14 菜单栏图标状态 | 图标必须是模板图（仅无角标时），不同状态的图像两两不同，五态按分项区分 | 所有状态都是非模板图。normal、collecting、stale 三态与 caution、alert 两态的图像互不相同。caution 与 alert 的标记在标记框里都存在，形状不同（至少 4 个像素不同）。normal 的标记框为空。标记颜色符合令牌，主体墨色等于 `labelColor`（容差沿用 W08）。同一等级同一图像：cpuYellow 与 powerYellow 相同，diskRed 与 multi 相同。宽 24 pt、提示文字等于无障碍文字、问题项顺序不变 | U10、DESIGN_V3.md 4.2：图标是比熊剪影，非模板图，标记只按等级区分（黄色三角，红色方块），不再按分项区分。run 39127149810 的失败项是“isTemplate is false”和“cpuYellow 与 powerYellow 同图”，两者都是新设计的预期行为 |
| W16 | 关闭 3 s 后：实时采样关、1 个引擎计时器、0 个 CA 动画、缓冲空、CPU <5%（最好的一个窗口） | 以上全部不变，另加：0 个图标计时器。检查前用 `cpuTick(5)` 三次使 CPU 为不忙状态 | DESIGN_V3.md 第 8 章：CPU 不忙时 0 个图标计时器。没有放宽任何一项 |

### 新增的门禁

| 编号 | 检查 | 来源 | 理由 |
|---|---|---|---|
| W24 | 全绿 6 项面板高度 ≤290 pt。运行时取真实窗口高度，必须等于 `PanelLayout.height`（264 pt）。脚本另检查 allGreen 的 4 个预览，像素高 ÷ 2 ≤290 | UI 与预览 | U9、DESIGN_V3.md 3.3 |
| W25 | 圆角取值只有 8 pt 与全圆。运行时：对问题行和主按钮的角做像素探测，距角 1 pt 处必须是空的，距角 2.5 pt 处必须有填充（半径落在 6.83 至 8.54 pt 内）。源码审计：`PanelRows`、`PanelAnomaly`、`PanelFooter`、`PanelHero`、`PanelRoot` 里每个 `cornerRadius:` 的值是 `PanelRadius.control`，且 `PanelRadius` 只有值 8 | UI 与源码审计 | DESIGN_V3.md 2、5.4 |
| W26 | 界面字符串不含“ · ”。源码审计扫描 `Sources/**/*.swift` 的字符串字面量。`Sources/Core/Prompt.swift` 永久排除（提示词正文，DESIGN_V3.md 9.2） | 源码审计 | DESIGN_V3.md 9.2 |
| W27 | 17 pt 字只出现在标题块。源码审计：`PanelType.lead`、`PanelType.leadMono` 只在 `PanelHero.swift`（标题块）、`PanelSidebar.swift` 和 `PanelWindow.swift`（侧栏标题）使用。`PanelType.rowValue` 只在 `PanelRows.swift` 的 `ProblemRowView` 里使用。`Panel*.swift` 里没有字面量 `size: 17` | 源码审计 | DESIGN_V3.md 4.1、5.1：全绿面板只有标题块是 17 pt |
| W28 | 同一等级的问题行有同一底色。运行时在 multi（两个红色行）与 cpuYellow 取每个问题行上缘的像素，同级各行的通道差 ≤3，浅色与深色各验 | UI | DESIGN_V3.md 5.1 |

W27 只做源码审计，没有运行时部分。原因：运行时无法按字号区分像素。全绿截图的字号由 W02 的字号集合检查（≤4 种）补充。

### W26 待清理清单

W26 对下列文件暂时豁免。这些文件里的“ · ”由 P4 与 P6 清理。清理后 P6 从 `scripts/ci_acceptance.py` 的 `DOT_JOIN_PENDING` 里删除对应文件。运行 CI 时，日志会打印豁免命中数。

| 文件 | 命中行 | 负责 |
|---|---|---|
| `Sources/Core/HealthRules.swift` | 281、288、439、443 | P6（DESIGN_V3.md 9.2） |
| `Sources/Core/Brief.swift` | 33 | P6（DESIGN_V3.md 9.2） |
| `Sources/Core/PreviewScenario.swift` | 362 至 390 | P6（DESIGN_V3.md 9.2） |
| `Sources/Core/SidebarContent.swift` | 176、186、842 | P4（DESIGN_V3.md 9.2） |
| `Sources/App/PanelTokens.swift` | 372（网络流量文字） | P4。DESIGN_V3.md 9.2 没有列出，W26 新发现 |
| `Sources/Core/NotificationPlanner.swift` | 56、102（通知标题“ · 已持续 ”） | P6。DESIGN_V3.md 9.2 没有列出，W26 新发现 |

### 侧栏门禁

名称里带 side 或 sidebar 的预览与检查（W05、W07、M10b、`preview-side-*`）不在 P3 范围，本节没有改动。它们在 P4 之后的变化由 P4 处理。


## 侧栏门禁的 v3 改写（P4，2026-10-18）

依据：用户原话 U3「所有的这些东西，都应该你来定，你按照获奖标准来出，我只是作为你的甲方来验收」，[DESIGN_V3.md](DESIGN_V3.md) 第 6 节「删除三个统计块」与 1.4 节 X16、X3。

| 编号 | 旧检查与旧数值 | 新检查与新数值 | 理由 |
|---|---|---|---|
| W19 侧栏部分 | `cap.total`、`cap.used`、`cap.available` 三列，右边缘相距 96 pt（容差 0.5 pt） | `cap.bar` 与 `cap.line` 两个框存在，数字行不宽于容量条。单位一致、已用加可用等于总量、主列注释前缀、无障碍标签含三个数，这四项不变 | 三列数字是统计块（X3）。v3 改为一条中性容量条加一行数字 |
| W07 读数文本 | 读数文本含「·」 | 读数文本含「，」，且不含「·」 | DESIGN_V3.md 第 9 节第 2 条：界面字符串不用「 · 」拼接。读数改为「13:09，80%」 |

不放宽：数值一致性的四项检查保持原样。W07 的计时与求值次数限值不变。

## v2 门禁登记表

面板 v2 新增门禁 W01 至 W22（见 [DESIGN_V2.md](DESIGN_V2.md) 13.3）。登记表在 `scripts/ci_acceptance.py` 的 `GATES` 列表中。每条登记有 4 个字段：编号、名称、状态、来源。

| 状态 | 含义 | 对 CI 的影响 |
|---|---|---|
| `active` | 门禁运行，必须通过。报告里缺这一项算失败 | 失败则 CI 失败 |
| `pending` | 已登记，未激活 | 不使 CI 失败。汇总列为“未激活”，不算通过 |

| 来源 | 结果读取位置 |
|---|---|
| `ui` | `ui-report.json` 中编号相同的项 |
| `core` | 工作流步骤 “Core and CLI tests” 的日志，由环境变量 `MOLEMONITOR_CORE_LOG` 指向。映射见下文 |
| `script` | 后续步骤的脚本。没有读取器，因此不能设为 `active` |

旧门禁（A 至 L、M2 至 M22、N1、N2）全部登记为 `active`，行为不变。DA 至 DE、BA 至 BF、M19V、M20、M21 已删除（U10，见“已删除的门禁”）。M2、M3、M22 的结果由 W02 提供：脚本把 W02 的报告复制成这三个编号。W02 检查三件事：每个场景的行顺序与高度，只有最严重的一行有淡底色，其他行没有底色（浅色与深色各检查一次）。因此 W02 同时承担旧 M22 的语义。
一个编号可以报告两次（W06 有模型部分和窗口部分）。登记表只保留失败：后一次通过不会覆盖前一次失败。

输出末尾的汇总行格式如下：

```
GATE REGISTRY: <通过> passed / <失败> failed / <未激活> inactive (未激活)
INACTIVE gates (未激活, not passed, not failed): W01 ...; W02 ...
```

`ACCEPTANCE PASSED` 前出现一次 `ui` 来源的汇总。`RELEASE BINARY AUDIT PASSED` 前出现一次全部来源的汇总。

### v2 门禁的激活状态（2026-10-13，WP-F2）

激活依据：run 38341738663（分支 `v2/wp-d`，提交 `5f20c2a`）的日志。`ui` 来源的 18 项在该次运行里报告 `pass`，现已激活。W16 在之后新增检查并激活，`ui` 来源共 19 项。`core` 来源的 3 项由 `ci_acceptance.py` 读取 Core 测试日志，同样已激活。激活后的 CI 运行见 [VERIFICATION.md](VERIFICATION.md) 条目 7 和 8。

| 状态 | 门禁 |
|---|---|
| `active`，来源 `ui`（12 项，U10 后） | W01、W02、W03、W05、W06、W07、W08、W09、W10、W16、W19、W22。W04、W11、W12、W14、W15、W17、W18 已删除 |
| `active`，来源 `core`（3 项） | W13、W20、W21 |
| `pending`（0 项） | 无 |

W08 的检查在 UI 测试变体里运行，因此来源从 `dog` 改为 `ui`。（W11 曾在这里登记，U10 删除。）

#### Core 门禁 W13、W20、W21

工作流步骤 “Core and CLI tests” 把 `scripts/test_core.py` 的输出写入 `$RUNNER_TEMP/core-tests.log`（`tee`）。步骤 “Acceptance and UI regression gate” 通过环境变量 `MOLEMONITOR_CORE_LOG` 把该文件交给 `ci_acceptance.py`。脚本读取日志里的 `== <套件>` 行和 `FAIL (line N)` 行。一个门禁只在以下条件都满足时通过：它的每个套件都出现在日志里，套件内没有 `FAIL` 行，日志有 `Result:` 行。套件不存在算失败，不算未激活。日志文件缺失时三个门禁都失败。

| 门禁 | 套件（`section` 名称） | 依据 |
|---|---|---|
| W13 | `BubbleCopyTests` | [DESIGN_V2.md](DESIGN_V2.md) 13.3：Core 单测（`BubbleCopy`），全部模板在最坏取值下 ≤24 宽度单位 |
| W20 | `PromptBuilder: structure (DESIGN_V2.md 8.4)`、`PromptBuilder: length and compression`、`Prompt: golden files` | 13.3：黄金样例 ≤3000 字符，第 4 节安全规则逐字存在 |
| W21 | `MemoryTests` | 13.3：压力百分比 77 到 23%，0 到 100%，100 到 0%，−1 与 101 为 nil |

> **注意**：测试程序只输出套件名，不输出每个套件的通过数。因此门禁读取“套件存在且没有失败断言”，不读通过数。在本机运行时，先运行 `python3 scripts/test_core.py | tee 日志文件`，再设置 `MOLEMONITOR_CORE_LOG=日志文件` 运行 `ci_acceptance.py`。

#### W16 关闭零成本

检查在 `Sources/App/UITestPanelChecks.swift`（U10 前在已删除的 `UITestSpriteChecks.swift`）。它打开夹具面板，送入 3 个数据点，然后关闭面板，并连续测量 3 s 窗口。下列条件在每个窗口里都必须成立，不重试取最好：

| 条件 | 值 |
|---|---|
| 实时采样定时器 | 关 |
| 引擎定时器 | 1 个（30 秒 tick） |
| 图标定时器 | 0 个（CPU 不忙，v3，DESIGN_V3.md 第 8 章） |
| Core Animation 动画 | 0 个（进程内除状态栏窗口外的全部窗口图层树） |
| 实时曲线缓冲 | 空 |

进程 CPU 是负载值，限值 5%（单核）。第一个窗口达标即停，否则最多测 3 个窗口，取最好一个。每个窗口的数值都写进 note。旧门禁 L 保留。

#### W06 窗口部分的计时（2026-10-13）

run 38344898067 的 W06 失败过一次：“快速扫过三行打开了侧栏”。原因：测试用 25 pt 步长和 10 ms 睡眠，名义速度 2.5 pt/ms。CI 虚拟机卡顿时睡眠被拉长到约 42 ms 以上，速度跌到限值 0.6 pt/ms 以下，扫过不再“快”。现在步长为 100 pt，并测量每步的实际间隔。run 38355826574 显示：换行那一步在 CI 虚拟机上约 100 ms，步长 60 pt 时最慢一步只有 0.62 pt/ms，三次扫过全部作废。产品没有打开侧栏（opened=false），所以步长改大到 100 pt，使这一步仍有 1.0 pt/ms。只要有一步的速度低于 0.9 pt/ms（限值 0.6 加 50% 余量），这次扫过作废并重做，最多 3 次。3 次都作废时，门禁报告“test environment too slow”并失败，不算通过。限值 0.6 pt/ms 和打开延迟不变。报告里的 `fastPassVoid` 记录作废次数。

#### W06 “停留 200 ms 不打开”的守卫（2026-10-13）

run 38365358267 的第一次运行里，W06 窗口部分失败：“opened before 200 ms”。原因：CI 虚拟机卡顿把 200 ms 睡眠拉长，真实停留时间超过打开延迟 350 ms，侧栏正确地打开了，测试却误判。这是测试时钟问题，不是产品问题。否定断言不能取最好一次，因此改用实际停留时间守卫，窗口部分和 UI 部分（`stepW06` 情形 1）规则相同：

1. 测量从指针移动到检查点的实际经过时间。
2. 如果经过时间大于等于 300 ms（350 ms 留 50 ms 余量），这次尝试作废。关闭侧栏，等 300 ms，重做，最多 3 次。
3. 如果经过时间小于 300 ms 且侧栏已打开，这是真失败，不重试。
4. 3 次都作废时，门禁报告 “test environment too slow: the 200 ms rest check was never run within 300 ms”并失败，不算通过。
5. 说明里写出每次尝试的实际经过时间，例如 “rest attempts 203/204 ms”。

200 ms、350 ms 和 450 ms 的限值不变。

#### 源码审计

审计 `Panel*.swift`（包括 `PanelWindow.swift` 和其中 `#if UITEST` 的钩子；`DogSpriteView.swift` 已随 U10 删除），内容是不含 `Timer`、`TimelineView`。钩子不含这些词，因此不需要排除。

#### 已知未覆盖

| 内容 | 说明 |
|---|---|
| 真机项 | 帧率、观感、系统授权框等，见 [HANDOFF.md](HANDOFF.md) |

### 接入新门禁

工作包 B、C、D、E 只新增自己的检查文件，不改 F 拥有的文件。步骤如下：

1. 在自己的 `Sources/App/UITest*Checks.swift` 中写一个枚举，提供 `@MainActor static func register(into registry: UITestRegistry)`。
2. 在该文件中加一行注释：`// UITEST-REGISTER: <枚举名>`。
3. 在 `register` 中调用 `registry.add("W03", "open speed") { runner in ... }`。检查结束时用 `runner.record("W03", 名称, 是否通过, since: 起始时间, 说明)` 报告。编号用 W 门禁编号。
4. 检查结束时关闭面板。
5. 本机运行 `swiftc -parse` 检查文件语法。

`scripts/build.py --ui-test` 找到注释行，生成 `dist-uitest/generated/UITestRegistrants.generated.swift`，其中的 `uiTestRegisterAll` 调用每个 `register`。没有该文件或 `register` 为空时，构建不失败，也没有登记项。

检查的运行位置：`UITestHarness.swift` 的 `stepRegistered()` 在步骤 M 之后、步骤 K 之前按登记顺序运行。结果写入 `ui-report.json` 的 `items`。`info.registeredChecks` 列出已登记的编号。

### 激活门禁

1. 工作包的检查已合并，并在 CI 的 `ui-report.json` 中报告该编号为 `pass`。
2. WP-F 把 `GATES` 中该条的 `status` 改为 `active`。
3. 运行 `python3 scripts/ci_acceptance.py --self-test`。该命令在任何系统上都能运行，检查登记表本身。
4. 推送并确认 CI 全绿。

> **注意**：不要用降低阈值的方式让门禁通过。`pending` 门禁报告的结果只显示为 `INFO`，不计入通过，也不使 CI 失败。

## 延迟类门禁的重复测量

延迟类门禁衡量的是能力，不是卡顿。CI 虚拟机偶尔卡顿 100 ms 左右，单次测量会被污染。因此延迟类门禁最多测 3 次，只要有 1 次满足限值就通过。3 次都不满足则失败。限值不变。真回归每次都慢，所以仍会失败。报告的说明里写出每一次的数值，例如 `attempts 223/179/131 ms`。

适用范围：

| 门禁 | 重复的测量 | 每次尝试之间 |
|---|---|---|
| W03 | 点击到首个可见帧（限 150 ms）和比熊区域就绪（限 150 ms） | 关闭面板，等 300 ms |
| W05 | hover open、close、click open、click close 的窗口动效用时 | 把窗口恢复到动作之前的状态 |
| W06 UI 部分 | 情形 2：侧栏打开后切换到另一行（限 200 ms 加 20 ms 余量） | 回到第一行，等侧栏显示，再等 300 ms |

不适用的内容，每次都必须满足：

- 否定类断言：W06 的“停留 200 ms 不打开”“快速扫过三行不打开”，W03 的“无白闪”和“比熊在首帧里”，W05 的“主列不移动”和“高度不变”。
- 冷启动首帧 M12。冷启动不能重复。M12 的限值是 300 ms，正常范围是 199 至 221 ms。虚拟机卡顿时测到过 304 ms 和 316 ms。M12 保持现状，偶发的失败需要重跑。

原因：run 38338270673 之后，同一套代码在不同运行里，每次都有一个不同的计时门禁因虚拟机卡顿失败。

| 门禁 | 失败数值 | 限值 | 正常范围 |
|---|---|---|---|
| M12 | 304 ms 和 316 ms | 300 ms | 199 至 221 ms |
| W03 | 223 ms 和 179 ms | 150 ms | 93 至 130 ms |
| W05 click open | 252 ms | 250 ms | 208 至 224 ms |
| W06 UI 部分的切换 | 228 ms | 220 ms | 产品延迟 120 ms |

## 局限

- 虚拟机是软件渲染。结果不代表真机 GPU 帧率，也不代表动画是否丝滑。
- 主线程间隔只能证明没有长阻塞。冷启动首次打开有一次约 215 至 440 ms 的卡顿。
- 美观、字体、间距、Retina 表现和真实菜单栏位置需要人看。
- 虚拟机里无人点击系统授权框。授权框是否真实弹出，要在 Mac 上确认。
- 部分项依赖窗口截图或辅助功能树。虚拟机里读不到时，该项标为 `skipped`，不算通过。
- 只覆盖 `macos-15` 和 arm64。macOS 14 与其他芯片未验证。
- 虚拟机的 CPU、内存、磁盘数字不能外推到真机。

真机待验清单见 [HANDOFF.md](HANDOFF.md) 的“下一步”。
