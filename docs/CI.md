---
title: "MoleMonitor · CI 回归门禁"
type: ci
last_updated: 2026-10-12
---

# CI 回归门禁

GitHub Actions 在每次改动源码或脚本的提交后构建 App，并运行回归检查。结果是回归门禁，不是真机验收。工作流文件是 [build-mac.yml](../.github/workflows/build-mac.yml)。

## 工作流做什么

工作流 `build-mac` 只有一个作业 `build-test`，运行在 `macos-15`。步骤按顺序执行：

| 步骤 | 内容 |
|---|---|
| 1. Toolchain | 输出系统版本、芯片、Xcode 和 `swiftc` 版本 |
| 2. Core and CLI tests | `scripts/test_core.py`（4171 条断言）与 `scripts/test_cli.py`（116 项检查） |
| 3. Build app | `python3 scripts/build.py`，输出 `dist/` |
| 4. Build UI test variant | `python3 scripts/build.py --ui-test`，输出 `dist-uitest/` |
| 5. Acceptance and UI regression gate | `python3 scripts/ci_acceptance.py`，检查项见 [scripts/README.md](../scripts/README.md) |
| 6. Upload | 上传 artifact `molemonitor-ci`，保留 3 天，即使前面步骤失败也上传 |

触发条件：推送到任意分支（`branches: ["**"]`）且改动了 `Sources/`、`Tests/`、`scripts/`、`Vendor/`、`Resources/`（含 `Resources/DogSprites/`）或工作流文件，或手动触发（`workflow_dispatch`）。

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
| C | 入场动画在推进 | 用窗口截图或图层数值，确认完整入场动画在推进并最终稳定。截图时刻为 0 到 900 ms 的 8 帧。窗口与入场强制关闭 RM，狗与气泡跟随系统设置 |
| D | 实时数据流入面板 | 面板模型中的趋势点数递增，相邻截图的像素有变化 |
| E | 主线程流畅度 | 120 Hz 定时器测主线程间隔：要求 p95 小于 40 ms，max 小于 250 ms |
| F | 悬停交互 | 合成鼠标悬停到磁盘图上，图的像素发生变化 |
| G | 按钮交互与降级文案 | 授权状态为“未决定”时，授权按钮可点。其他状态时，降级文案符合预期 |
| H | 关闭 | 按 Esc 在 400 ms 内关闭，实时定时器停止，缓冲清空，视图控制器被释放 |
| I | 再次打开 | 第二次打开比第一次更快稳定（150 ms 淡入），实时采样重新启动，定时器共 2 个。动效状态与 C 相同。原因：CI 虚拟机报告 RM 打开，RM 下完整入场也是 150 ms 淡入，两次打开无法区分 |
| J | 深浅色 | 浅色与深色外观的截图都非空白，且彼此不同 |
| K | 退出 | 点击“退出”按钮，进程以退出码 0 结束，`status.json` 在退出时被写入 |
| L | 关闭面板零成本 | 关闭 3 秒后，实时采样为关，只剩 1 个定时器（5 分钟 tick），缓冲为空，CPU 小于 5% 单核 |
| M1 | 场景互不相同 | 7 个场景的预览图两两不同（sha256） |
| M2 | 问题优先排序 | 区块的纵向顺序等于 `ProblemOrder`，灯的顺序与区块一致 |
| M3 | 高度分档 | 弹窗高度为 332（安静）、560（单项或双项问题）、620（多项问题） |
| M4 | 刷新与展开不改高度 | 10 次刷新、点击行、展开占用 App 与更多后，弹窗高度变化为 0 |
| M5 | 对比度 | 浅色与深色下，正文对比度不低于 4.5，灯与曲线不低于 3 |
| M6 | 大字号 | 字号放大到 1.25 倍后，`PanelSlots.all` 中没有文字被截断 |
| M11 | 焦点环 | 第一响应者不是 NSControl，`btn.quit` 周围 4 pt 内没有焦点环像素 |
| M12 | 冷启动首帧 | 首个 `chart.cpu` 折线像素在 300 ms 内出现 |
| M13 | 复制 | 复制的文字等于 PromptBuilder 的文字，不含家目录与用户名，按钮显示“已复制”后在 1.5 秒（误差 0.3 秒）内恢复 |
| N1 | 真实引擎复制 | 引擎驱动的面板，复制文字等于 `PromptBuilder` 对引擎输入的结果，长度不超过 3000，不含家目录与用户名，含“磁盘” |
| N2 | 打开即有历史 | 用 `trendSeed` 模拟重启后恢复的 2 小时趋势，面板打开的同一刻模型已有不少于一半的种子点 |
| M14 | 菜单栏图标状态 | 7 个场景下，`MenuIconModel` 与 `AppDelegate` 交给 `StatusIconController` 的姿态和角标等于手写期望表。图标是 24 pt 宽的模板图像，提示文字等于无障碍文字，问题项顺序等于 `ProblemOrder`，不同状态的图像互不相同 |
| M19 | 面板里比熊真实渲染（默认路径，现为位图比熊） | 7 个场景的浅色与深色截图里，比熊区域的非背景像素，动态比熊不少于区域的 1%，静态灰比熊（统计中、数据过期）不少于 1.5%，且都至少 12 种颜色。无障碍树不含占位文字。源码与发布二进制不含 `SKELETON` 字符串 |
| M19V | 面板里矢量比熊真实渲染 | 关闭位图开关（`DogView.useBitmapArt = false`），对 7 个场景的浅色与深色测矢量比熊，门槛与 M19 相同 |
| M20 | 位图比熊随数据点变化 | 真实面板内，空闲 3 秒位图视图的 body 评估为 0。测试注入 5 个数据点（CPU 95、热状态 serious、磁盘红、清除问题加 CPU 20、统计中），姿态依次为冲刺、喘气、关注、走、灰化，且每步狗区域像素有变化 |
| M21 | 问题模式比熊（G2 第 1 轮） | diskRed 与 multi，浅色与深色。比熊框宽 ≥ 64 pt，框顶距面板顶 ≥ 6 pt。气泡包围框与比熊身体（alpha ≥ 8）包围框不相交，相距 ≥ 2 pt。最高墨迹距面板顶 ≥ 6 pt。姿态为关注 |
| M22 | 浅深色折叠问题卡（G2 第 1、2 轮） | multi，浅色与深色各验。3 张折叠问题行的底与面板底色相差 ≤ 20，色相（通道最大差）≤ 4，左缘 3 pt 色条与本级灯色相差 ≤ 30 并比另一级更近。第一张问题卡有淡底（色相 ≥ 6） |

## 比熊门禁（`--dog-gallery <目录> --dog-checks`）

比熊块的各项写入 `dog-report.json`。矢量路径的项（`DogView.useBitmapArt = false`）门槛不变，位图项是新增的。含义与位图阶段的取舍见 [DESIGN.md 4.9.4](DESIGN.md#494-门禁变化)。

| 项 | 检查内容 |
|---|---|
| DA、DB、DC、DE | 矢量路径：卡片打开的帧数与成本、关闭后无回调、步态切换腿速、Reduce Motion 无帧。位图路径不适用 DC（没有腿部动画）与 DA 的 60 至 80 帧（没有时间线） |
| DD | 菜单栏切换帧数与时长，与比熊无关 |
| DF | 发布二进制不含测试代码，含 `DogBitmapProbe` 与 `UITestBitmapChecks` 的检查，UI 变体含探针（正控） |
| BA | 位图卡片打开 3 秒与关闭 3 秒，body 评估与矢量帧都为 0 |
| BB | Reduce Motion 下 4 次姿态切换都不附加淡变，对照组都附加 |
| BC | 8 个文件加载，320 × 240，缺目录无崩溃并回退矢量，开关路由正确 |
| BD | 72 × 54 pt 下 7 个姿态两两异或比例，21 对，门槛 0.20 |
| BE | 非背景像素占比，灰化不少于 1.5%，其余不少于 1%，至少 12 种颜色 |
| BF | 8 个姿态的地面阴影：中心 y 与脚底线相差 ≤ 2 px（72 × 54 下），中心 x 与比熊中心相差 ≤ 2 px，宽度比 0.68 至 0.82，冲刺更窄（< 0.65）更淡 |
| BS | 4 张联系表（`bitmap-sheet-light.png`、`bitmap-sheet-dark.png` 与带阴影的两张）已写出 |

另外，`ci_acceptance.py` 检查 `Contents/Resources/DogArt` 内 8 个文件与源文件逐字节相同，并审计 `DogBitmapView.swift` 的非注释代码不含 `Timer`、`TimelineView`、`Canvas`、`CADisplayLink`、`DispatchSource`、`asyncAfter`。

最新全绿运行（run 38115054435）的实测数字见 [VERIFICATION.md](VERIFICATION.md) 条目 3。位图阶段的运行见条目 4。G2 第 1 轮修订（M21、M22、BF）的运行见条目 5。

## v2 门禁登记表

面板 v2 新增门禁 W01 至 W22（见 [DESIGN_V2.md](DESIGN_V2.md) 13.3）。登记表在 `scripts/ci_acceptance.py` 的 `GATES` 列表中。每条登记有 4 个字段：编号、名称、状态、来源。

| 状态 | 含义 | 对 CI 的影响 |
|---|---|---|
| `active` | 门禁运行，必须通过。报告里缺这一项算失败 | 失败则 CI 失败 |
| `pending` | 已登记，未激活 | 不使 CI 失败。汇总列为“未激活”，不算通过 |

| 来源 | 结果读取位置 |
|---|---|
| `ui` | `ui-report.json` 中编号相同的项 |
| `dog` | `dog-report.json` 中编号相同的项 |
| `core` | 工作流步骤 “Core and CLI tests”。`ci_acceptance.py` 没有读取器，因此不能设为 `active` |
| `script` | 后续步骤的脚本。同样不能设为 `active` |

旧门禁（A 至 L、M2 至 M22、N1、N2、DA 至 DE、BA 至 BF）全部登记为 `active`，行为不变。

输出末尾的汇总行格式如下：

```
GATE REGISTRY: <通过> passed / <失败> failed / <未激活> inactive (未激活)
INACTIVE gates (未激活, not passed, not failed): W01 ...; W02 ...
```

`ACCEPTANCE PASSED` 前出现一次 `ui` 来源的汇总。`DOG ANIMATION CHECKS PASSED` 前出现一次全部来源的汇总。

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

1. 工作包的检查已合并，并在 CI 的 `ui-report.json` 或 `dog-report.json` 中报告该编号。
2. WP-F 把 `GATES` 中该条的 `status` 改为 `active`。
3. 运行 `python3 scripts/ci_acceptance.py --self-test`。该命令在任何系统上都能运行，检查登记表本身。
4. 推送并确认 CI 全绿。

> **注意**：不要用降低阈值的方式让门禁通过。`pending` 门禁报告的结果只显示为 `INFO`，不计入通过，也不使 CI 失败。

## 局限

- 虚拟机是软件渲染。结果不代表真机 GPU 帧率，也不代表动画是否丝滑。
- 主线程间隔只能证明没有长阻塞。冷启动首次打开有一次约 215 至 440 ms 的卡顿。
- 美观、字体、间距、Retina 表现和真实菜单栏位置需要人看。
- 虚拟机里无人点击系统授权框。授权框是否真实弹出，要在 Mac 上确认。
- 部分项依赖窗口截图或辅助功能树。虚拟机里读不到时，该项标为 `skipped`，不算通过。
- 只覆盖 `macos-15` 和 arm64。macOS 14 与其他芯片未验证。
- 虚拟机的 CPU、内存、磁盘数字不能外推到真机。

真机待验清单见 [HANDOFF.md](HANDOFF.md) 的“下一步”。
