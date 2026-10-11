---
title: "MoleMonitor · Claude 接手说明"
type: handoff
last_updated: 2026-10-11
---

# Claude 接手说明

阶段 1 的代码已经写完。`Sources/Core/` 与 CLI 已在 Linux 上测试。`Sources/App/` 与 `scripts/build.py` 尚未在 Mac 上编译或运行。项目在 Linux VPS 上可以继续设计、改源码和写文档。AppKit、SwiftUI、UserNotifications、IOKit 的构建与运行检查必须在 Apple Silicon Mac 上完成。Linux 的静态检查不能替代这些结果。

## 当前状态

| 部分 | 状态 |
|---|---|
| 产品方向 | 只检测和预警，不做清理。设计真源是 [PROJECT.md](PROJECT.md) |
| `Sources/Core/` | 完成。Linux 上 294 条断言通过 |
| `Sources/cli/`（`molemonitor-cli`） | 完成。Linux 上 79 项检查通过，耗时 p50 约 11 ms，p95 约 16 ms |
| `Sources/App/`（Engine、Sampler、Notifier、StatusIcon、Panel） | 已写完。只做过 Linux 桩类型检查，未在 Mac 上编译或运行 |
| `Sources/MoleMonitor.swift` | 入口分流：`--self-test`、`--diagnose`、`--preview`、正常 App。未在 Mac 上编译 |
| `Sources/Sensors.swift` | 保留的只读 SMC。阶段 1 不引用，阶段 2 使用 |
| `scripts/build.py` | 已重写：不下载，编译 App 和 CLI，ad-hoc 签名。未在 Mac 上运行 |
| 旧方案 | Go 采集器、`fetch_status.py`、1 Hz 界面定时器已删除 |

> **注意**：在 Mac 上首次构建之前，不要把 `Sources/App/` 写成已验证。第一版的验证记录只属于已废弃的旧方案，见 [VERIFICATION.md](VERIFICATION.md)。

## 范围

- 工具不增加清理按钮、自动删除、sudo、特权 helper、SMC 写入或风扇控制。
- 磁盘短期大量增长和剩余空间低发系统通知。问题消失后，不发通知，界面和 CLI 也不显示"已恢复"。
- 电池循环次数和每应用耗电排行都不做。
- 当前没有安装到 Applications、设置登录启动、公证或发布二进制 Release。
- 自有代码采用 GPL-3.0-only。接手时不变更许可证。

阶段 1 之后的计划：

1. 阶段 2：CPU、内存、泄漏检测、前 5 名应用、网速与流量。
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

可见 App 检查、安装、登录启动、公证与发行按用户具体授权执行。

## 下一步

1. 在 Mac 上运行 `python3 scripts/build.py`。
2. 如果编译失败，把完整编译错误粘贴回 Claude。Claude 在 VPS 上修改源码。
3. 构建成功后，运行 `--self-test`、`codesign --verify` 和 `--diagnose --seconds 22`。
4. 运行 `python3 scripts/test_core.py` 和 `python3 scripts/test_cli.py`，确认 Mac 上同样通过。
5. 按 [PROJECT.md](PROJECT.md) 第 11 节验证 V10、V11、V17、V19、V22，并在 Mac 上测 CLI 耗时。
6. 把结果写入 [VERIFICATION.md](VERIFICATION.md) 的新条目，不覆盖旧记录。

## 代码与第三方来源

本项目不包含、不下载、不调用 Mole 的代码或二进制。SMC 协议与传感器键参考 SMCKit 和 Stats，保留 MIT 归属。归属见 [Vendor/NOTICE.md](../Vendor/NOTICE.md)。目录职责见 [Sources/README.md](../Sources/README.md)。

## Git 与交接边界

公开仓库是 [DwDestiny/MoleMonitor](https://github.com/DwDestiny/MoleMonitor)。具体同步提交、文件哈希与两端路径见本机 `local-notes/` 的收据。该目录不进入公开 Git。

两端通过 Git 提交交接。合并前检查两边未提交的改动。不要用目录整包覆盖对方工作。不要把文件一致性称为 App 功能验收。
