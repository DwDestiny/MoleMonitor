---
title: "MoleMonitor · Claude 接手说明"
type: handoff
last_updated: 2026-10-18
---

# Claude 接手说明

MoleMonitor 的功能代码已经写完，面板 v2 已实现并合并到 `main`（提交 `3dae2ad`）。面板 v3（体检单）在分支 `v3/design` 上实现，尚未合并到 `main`。`Sources/Core/` 与 CLI 在 Linux 上测试。`Sources/App/` 在 CI 的 macOS 虚拟机上构建并通过回归门禁，但没有在用户的 Mac 上人工验收。Linux VPS 可以继续阅读、设计、改源码和写文档。AppKit、SwiftUI、UserNotifications、IOKit 的真机检查必须在 Apple Silicon Mac 上完成。

面板与菜单栏图标的设计真源是 [DESIGN_V3.md](DESIGN_V3.md)。DESIGN_V3.md 没写到的内容（数据、规则、提示词正文）以 [DESIGN_V2.md](DESIGN_V2.md) 为准。[DESIGN.md](DESIGN.md) 中被取代的章节已有标记，数据层与提示词规则仍有效。产品范围与数据口径见 [PROJECT.md](PROJECT.md)。如果文档冲突，以 DESIGN_V3.md 与 [VERIFICATION.md](VERIFICATION.md) 为准。

## 当前状态

| 部分 | 状态 |
|---|---|
| 产品方向 | 只读 macOS 14+ 菜单栏健康哨兵。只检测和预警，不做清理 |
| 状态卡 | 自定义 `NSPanel` 窗口，体检单版式。主列 352 pt 宽，高度随问题行数变化：全绿 264 pt，1 个问题行 344 pt，3 个问题行 468 pt（最大）。结构：64 pt 标题块（一句话，面板里没有比熊）、72 pt 问题行（整行等级底色加行内曲线）、两列 28 pt 正常行、记录行、底部复制按钮。点击或悬停一行，右侧展开 320 pt 的侧栏。设计见 [DESIGN_V3.md](DESIGN_V3.md) |
| 数据层 | 引擎每 30 秒采样一次，内存保存 2 小时环形缓冲，每 5 分钟写 `trend.json`，另写 5 分钟汇总文件 `rollup-YYYY-MM.ndjson` 与 `events.json`（异常记录）。设计见 [DESIGN.md 第 6 章](DESIGN.md#6-数据层规格)和 [DESIGN_V2.md 第 12 章](DESIGN_V2.md) |
| 健康规则 | CPU、内存、温度、磁盘、耗电五项都已实现。占用 App 前 5 名已实现 |
| 提示词 | 状态卡有“复制排查提示词”按钮（无问题时为“复制日常巡检提示词”），生成不超过 3000 字的排查提示词。CLI 命令是 `molemonitor-cli prompt`。提示词禁止 `mo optimize`、`mo uninstall` 和非 dry-run 清理。删除、卸载、清理、结束进程前须经用户确认 |
| 面板里的比熊 | 已删除（U10，2026-10-18）。面板没有比熊、气泡、舞台、序列帧和位图。已删除的门禁见 [CI.md](CI.md)「已删除的门禁（U10）」 |
| 菜单栏图标 | 比熊侧视剪影，矢量绘制。静态 1 帧，CPU 达到 35% 起 4 帧奔跑（35% 至 60% 为 4 fps，60% 至 85% 为 6 fps，85% 以上为 8 fps）。CPU 低于 25% 且连续 2 个 30 秒 tick 后回到静态。黄色 ▲ 表示留意，红色 ■ 表示异常。采集中与过期是空心轮廓。奔跑时才有一个图标计时器 |
| 素材 | v3 起没有 AI 生成素材，许可风险消失。见 [ASSETS.md](ASSETS.md) |
| `Sources/Core/` | 完成。Linux 上 5074 条断言通过 |
| `Sources/cli/`（`molemonitor-cli`） | 完成。Linux 上 124 项检查通过 |
| `Sources/App/` | 完成，通过 CI 回归门禁。文件划分见 [Sources/README.md](../Sources/README.md) |
| `Sources/App/UITest*.swift` | 界面回归测试代码。只在 `-D UITEST` 构建中存在 |
| `Sources/Sensors.swift` | 保留的只读 SMC |
| `scripts/build.py` | 编译 App 和 CLI，ad-hoc 签名。`--ui-test` 构建测试变体 |
| CI | `.github/workflows/build-mac.yml`，单作业，30 分钟上限，UI 测试预算 420 s。说明见 [CI.md](CI.md) |
| 旧方案 | Go 采集器、`fetch_status.py`、1 Hz 界面定时器已删除 |

> **注意**：CI 结果是回归门禁，不是真机验收。不要写成“验收通过”。虚拟机是软件渲染，不能证明真机帧率、观感、菜单栏位置和通知授权框。见 [VERIFICATION.md](VERIFICATION.md) 条目 3 至 6。

## 范围

- 工具不增加清理按钮、自动删除、sudo、特权 helper、SMC 写入或风扇控制。
- 问题消失后，工具不发恢复通知，界面和 CLI 也不显示“已恢复”。
- 电池循环次数和每应用耗电排行都不做。
- 当前没有安装到 Applications、设置登录启动、公证或发布二进制 Release。
- 自有代码采用 GPL-3.0-only。接手时不变更许可证。

## 已完成

| 项 | 内容 |
|---|---|
| 阶段 1 | 磁盘采样、`status.json`、CLI、磁盘通知、CI 回归门禁 |
| 阶段 2 | CPU 与内存规则、占用 App 前 5 名、实时网速与整机 CPU 曲线 |
| 阶段 3 | 温度与热状态规则、自绘比熊、菜单栏图标动画 |
| 阶段 4 | 睡眠掉电与整机耗电规则 |
| 状态卡重设计 | 问题优先版面、2 小时趋势、复制给 Agent |
| 面板 v2 | NSPanel 窗口、侧栏、序列帧比熊、菜单栏五态、气泡。门禁 W01 至 W22。比熊部分已被 U10 取代 |
| 位图比熊 | 8 张位图、淡入、地面阴影、门禁 BA 至 BF。已被 U10 取代，素材与门禁已删除 |
| 面板 v3 | 体检单版式：标题块、72 pt 问题行、两列正常行、爪印章、重做的侧栏与 7 天异常记录页、菜单栏静态与奔跑图标。设计见 [DESIGN_V3.md](DESIGN_V3.md)，在分支 `v3/design` 上，CI 回归门禁全绿 |

## 未做

| 项 | 说明 |
|---|---|
| 真机动画手感与 CPU | 菜单栏奔跑图标与面板反馈动效已实现。CI 虚拟机是软件渲染，真机帧率和 CPU 须用户测 |
| 合并 v3 | 分支 `v3/design` 尚未合并到 `main`，由协调者决定 |
| 真机验收 | 见下文“下一步”的清单 |
| 安装、登录启动、公证、Release | 按用户具体授权执行 |
| 电池基线耗电 | 延后，两周使用后再决定 |

## 可用命令

在 Linux 或 Mac 上测试 Core 与 CLI。命令需要 `swiftc`。Linux VPS 的编译器是 `~/.local/bin/swiftc-local`，脚本会自动查找。

```bash
python3 scripts/test_core.py
python3 scripts/test_cli.py
git diff --check
```

在 Mac 上，从项目根目录运行：

```bash
python3 scripts/build.py
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test
codesign --verify --deep --strict dist/MoleMonitor.app
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --diagnose --seconds 22
dist/MoleMonitor.app/Contents/Helpers/molemonitor-cli --status --brief
dist/MoleMonitor.app/Contents/Helpers/molemonitor-cli prompt
```

构建界面测试变体，输出到 `dist-uitest/`：

```bash
python3 scripts/build.py --ui-test
```

在 arm64 macOS 上运行本地回归门禁。先运行 `python3 scripts/build.py` 和 `python3 scripts/build.py --ui-test`。脚本在 Linux 或 Intel Mac 上直接退出。运行时，状态卡会在屏幕上显示约 30 秒。

```bash
python3 scripts/ci_acceptance.py
```

在 CI 上查看运行结果：

```bash
gh run list --workflow build-mac.yml
gh run watch
gh run download -n molemonitor-ci
```

可见 App 检查、安装、登录启动、公证与发行按用户具体授权执行。CI 的 `--ui-test` 在虚拟机上显示状态卡，这不改变这条规则。

## 下一步

用户在自己的 Mac 上构建并验收。

### 构建

1. 在 Mac 上打开终端，进入项目根目录。
2. 运行 `python3 scripts/build.py`。
3. 如果编译失败，把完整编译错误粘贴回 Claude。Claude 在 VPS 上修改源码。
4. 运行 `dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test`。
5. 运行 `codesign --verify --deep --strict dist/MoleMonitor.app`。
6. 运行 `dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --diagnose --seconds 22`。
7. 获得用户授权后，打开 `dist/MoleMonitor.app`。

### 真机验收清单

按下表逐项检查。把结果写入 [VERIFICATION.md](VERIFICATION.md) 的新条目，不覆盖旧记录。

| 编号 | 检查项 |
|---|---|
| 1 | 爪印章手感：点击“复制排查提示词”或按 ⌘C 后，印章落定的节奏，1500 ms 后的淡出，Reduce Motion 下直接出现 |
| 2 | 菜单栏奔跑观感：35% 起奔跑，4、6、8 fps 三档速度，停止的迟滞，在真实壁纸上的轮廓，黄 ▲ 与红 ■ 角标 |
| 3 | 状态光的深色观感：黄级与红级的顶部渐变，状态变化时的 400 ms 淡变，浅色外观没有状态光 |
| 4 | 侧栏打开动画：窗口加宽的流畅度，新内容从被悬停行淡入并上移 |
| 5 | 实时点跳步：状态卡打开期间，2 秒采样到达时线端圆点的 200 ms 跳步 |
| 6 | 灰度应用图标：Dock 与菜单栏以外的灰度外观下，图标仍可辨认 |
| 7 | 72 pt 问题行在真实弹窗里的观感：等级底色、行内曲线、17 pt 数值的层次，浅色与深色外观 |
| 8 | 真实通知授权框，以及点击通知后展开状态卡 |
| 9 | 状态卡打开与关闭时，Activity Monitor 里的 CPU 和闲置 CPU。CI 虚拟机是软件渲染，不能外推 |
| 10 | “复制排查提示词”按钮的真实剪贴板路径 |
| 11 | 真实电池行（台式机没有电池） |
| 12 | Reduce Motion（系统设置 → 辅助功能 → 显示） |
| 13 | 提示词里的系统命令 `pmset`、`sysctl`、`vm_stat`、`ps` 在真机上的输出与权限（V23），耗电阈值（V24） |

PROJECT.md 第 11 节的验证项（例如 V10、V11、V17、V19、V22）也仍需真机结果。

## 代码与第三方来源

本项目不包含、不下载、不调用 Mole 的代码或二进制。SMC 协议与传感器键参考 SMCKit 和 Stats，保留 MIT 归属。归属见 [Vendor/NOTICE.md](../Vendor/NOTICE.md)。目录职责见 [Sources/README.md](../Sources/README.md)。

## Git 与交接边界

公开仓库是 [DwDestiny/MoleMonitor](https://github.com/DwDestiny/MoleMonitor)。具体同步提交、文件哈希与两端路径见本机 `local-notes/` 的收据。该目录不进入公开 Git。

两端通过 Git 提交交接。合并前检查两边未提交的改动。不要用目录整包覆盖对方工作。不要把文件一致性称为 App 功能验收。
