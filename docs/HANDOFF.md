---
title: "MoleMonitor · Claude 接手说明"
type: handoff
last_updated: 2026-10-11
---

# Claude 接手说明

阶段 1 的代码已经写完，状态卡已重做，并已加上 GitHub Actions 回归门禁。`Sources/Core/` 与 CLI 在 Linux 上测试。`Sources/App/` 在 CI 的 macOS 虚拟机上构建并通过回归门禁，但没有在用户的 Mac 上人工验收。项目在 Linux VPS 上可以继续设计、改源码和写文档。AppKit、SwiftUI、UserNotifications、IOKit 的真机检查必须在 Apple Silicon Mac 上完成。

## 当前状态

| 部分 | 状态 |
|---|---|
| 产品方向 | 只检测和预警，不做清理。设计真源是 [PROJECT.md](PROJECT.md) |
| `Sources/Core/` | 完成。Linux 上 353 条断言通过 |
| `Sources/cli/`（`molemonitor-cli`） | 完成。Linux 上 79 项检查通过。CI 虚拟机上 p50 8.1 ms，p95 11.8 ms |
| `Sources/App/`（Engine、Sampler、LiveSampler、Notifier、StatusIcon、Panel） | 已写完。状态卡已重做：磁盘 30 天趋势图，实时卡（网速与整机 CPU，60 秒窗口，每 2 秒采样，只在状态卡打开期间采样，实时点不落盘），入场动画，宽 340 pt。已通过 CI 回归门禁 |
| `Sources/App/UITestHarness.swift` | 界面回归测试代码。只在 `-D UITEST` 构建中存在 |
| `Sources/MoleMonitor.swift` | 入口分流：`--self-test`、`--diagnose`、`--preview`、正常 App |
| `Sources/Sensors.swift` | 保留的只读 SMC。阶段 1 不引用，阶段 2 使用 |
| `scripts/build.py` | 编译 App 和 CLI，ad-hoc 签名。`--ui-test` 构建测试变体。已在 CI 上运行 |
| `scripts/ci_acceptance.py`、`.github/workflows/build-mac.yml` | CI 回归门禁。最新全绿运行：Actions run 38115054435。说明见 [CI.md](CI.md) |
| 旧方案 | Go 采集器、`fetch_status.py`、1 Hz 界面定时器已删除 |

实时网速与 CPU 曲线是从阶段 2 提前的仅显示功能。CPU 的健康规则仍属阶段 2。

> **注意**：CI 结果是回归门禁，不是真机验收。不要写成“验收通过”。虚拟机是软件渲染，不能证明真机帧率、观感、菜单栏位置和通知授权框。见 [VERIFICATION.md](VERIFICATION.md) 条目 3。

## 范围

- 工具不增加清理按钮、自动删除、sudo、特权 helper、SMC 写入或风扇控制。
- 磁盘短期大量增长和剩余空间低发系统通知。问题消失后，不发通知，界面和 CLI 也不显示"已恢复"。
- 电池循环次数和每应用耗电排行都不做。
- 当前没有安装到 Applications、设置登录启动、公证或发布二进制 Release。
- 自有代码采用 GPL-3.0-only。接手时不变更许可证。

阶段 1 之后的计划：

1. 阶段 2：CPU 健康规则、内存、泄漏检测、前 5 名应用。实时网速与 CPU 曲线已提前完成。
2. 阶段 3：温度与热状态，自绘比熊。
3. 阶段 4：睡眠掉电。

阶段计划见 [PROJECT.md](PROJECT.md) 的第 10 节。

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

用户先在自己的 Mac 上过一遍，然后进入阶段 2。

1. 在 Mac 上运行 `python3 scripts/build.py`。
2. 如果编译失败，把完整编译错误粘贴回 Claude。Claude 在 VPS 上修改源码。
3. 运行 `--self-test`、`codesign --verify` 和 `--diagnose --seconds 22`。
4. 获得用户授权后，打开 `dist/MoleMonitor.app`。检查以下 5 项：
   - 点击菜单栏图标，状态卡打开。检查磁盘趋势图和实时卡。
   - 通知授权框是否弹出。
   - 动效手感：第一次打开的入场动画，之后的 150 ms 淡入。
   - 系统深色与浅色外观。
   - 菜单栏图标的外观和红色角标。
5. 按 [PROJECT.md](PROJECT.md) 第 11 节验证 V10、V11、V17、V19、V22。
6. 把结果写入 [VERIFICATION.md](VERIFICATION.md) 的新条目，不覆盖旧记录。
7. 真机检查完成后，开始阶段 2：CPU 健康规则、内存、泄漏检测、前 5 名应用。

## 代码与第三方来源

本项目不包含、不下载、不调用 Mole 的代码或二进制。SMC 协议与传感器键参考 SMCKit 和 Stats，保留 MIT 归属。归属见 [Vendor/NOTICE.md](../Vendor/NOTICE.md)。目录职责见 [Sources/README.md](../Sources/README.md)。

## Git 与交接边界

公开仓库是 [DwDestiny/MoleMonitor](https://github.com/DwDestiny/MoleMonitor)。具体同步提交、文件哈希与两端路径见本机 `local-notes/` 的收据。该目录不进入公开 Git。

两端通过 Git 提交交接。合并前检查两边未提交的改动。不要用目录整包覆盖对方工作。不要把文件一致性称为 App 功能验收。
