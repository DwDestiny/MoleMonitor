---
title: "MoleMonitor · 只读菜单栏监控"
type: project
last_updated: 2026-10-11
---

# MoleMonitor

MoleMonitor 是 macOS 菜单栏上的轻量状态监测与预警工具。它只检测和预警，不做清理。清理由用户的 agent 调用 [Mole](https://github.com/tw93/Mole) CLI 完成。

> **注意**：阶段 1 的代码已经写完。`Sources/Core/` 与 CLI 已在 Linux 上测试。`Sources/App/` 已在 GitHub Actions 的 macOS 虚拟机上通过回归门禁（见 [docs/CI.md](docs/CI.md)），但尚未在用户的 Mac 上人工验收。完整目标设计见 [docs/PROJECT.md](docs/PROJECT.md)，验证范围见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。

## 功能

阶段 1 提供下表的功能。CPU、内存、温度的健康等级在阶段 2 与阶段 3 实现。

| 位置 | 内容 |
|---|---|
| 菜单栏 | 小狗符号加两个灰点。磁盘为红色时，图标右上角显示红色角标 |
| 状态卡 | 磁盘 30 天趋势图与增长量。实时卡：网速（上下行）与整机 CPU 折线，60 秒窗口，只在状态卡打开期间采样，不落盘。流量两行文字。未消除的提醒。通知授权状态。CLI 命令示例。退出 |
| 系统通知 | 磁盘短期大量增长，磁盘剩余空间低 |
| CLI | `molemonitor-cli` 读取状态，输出 JSON 或一行中文 |

本工具不显示电池循环次数，不提供每应用耗电排行，不以 CPU 使用率估算耗电。问题消失后，工具不发通知，界面和 CLI 也不显示"已恢复"。

## 构建

要求：Apple Silicon（arm64）、macOS 14 或更高版本、Python 3、Xcode 或 Command Line Tools 的 Swift 工具链。

构建不下载任何文件，不需要网络。从项目根目录执行：

```bash
git clone https://github.com/DwDestiny/MoleMonitor.git
cd MoleMonitor
python3 scripts/build.py
```

构建产物是 `dist/MoleMonitor.app`。App 包内的 `Contents/Helpers/molemonitor-cli` 是 CLI。构建脚本不安装 App，不设置登录启动。App 使用本机 ad-hoc 签名，尚未公证。目前没有 GitHub Release 成品。

## CLI 用法

CLI 只读文件，不加载 AppKit，不联网。示例：

```bash
dist/MoleMonitor.app/Contents/Helpers/molemonitor-cli --status
dist/MoleMonitor.app/Contents/Helpers/molemonitor-cli --status --brief
dist/MoleMonitor.app/Contents/Helpers/molemonitor-cli --disk-history --days 7
```

| 命令 | 输出 |
|---|---|
| `--status` | 完整状态 JSON |
| `--status --brief` | 一行中文摘要 |
| `--disk-history [--days N]` | 每天一行的磁盘真实已用与增长量。默认 30 天，最大 60 天 |
| `--schema` | 字段说明与口径说明 |
| `--version`、`--help` | 文本 |

| 退出码 | 含义 |
|---|---|
| 0 | 数据新鲜 |
| 2 | 参数错误 |
| 3 | 数据过期，或 App 没运行。CLI 仍输出最后的数据 |
| 4 | 没有任何记录 |

## 隐私与数据目录

数据目录是 `~/Library/Application Support/MoleMonitor/`。环境变量 `MOLEMONITOR_DATA_DIR` 可以改变该目录。文件权限是 0600。

| 文件 | 内容 |
|---|---|
| `status.json` | 当前完整状态 |
| `disk-YYYY-MM.ndjson` | 每 15 分钟一行：磁盘样本、网络累计字节、开机时间 |
| `alert-state.json` | 磁盘通知状态，用于避免重复通知 |

工具不联网，不读取进程命令参数，不记录序列号或凭据。完整落盘规则见 [docs/PROJECT.md](docs/PROJECT.md) 的 6.3 节。

## 验证状态

| 范围 | 状态 |
|---|---|
| `Sources/Core/`、CLI | 在 Linux 上通过测试：Core 353 条断言，CLI 79 项检查 |
| `Sources/App/` | 在 CI 的 macOS 虚拟机上构建并通过回归门禁（Actions run 38115054435）。不是真机验收 |
| 动画帧率、观感、真实菜单栏位置、通知授权框、网卡计数器的特殊场景 | 未验证，需要用户在自己的 Mac 上确认 |

详情见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。

## 项目结构

| 目录/文件 | 用途 |
|---|---|
| [Sources/](Sources/README.md) | Core 逻辑、App 界面与引擎、CLI |
| [Tests/](Tests) | Core 与 CLI 的测试源码 |
| [scripts/](scripts/README.md) | 本地构建、测试与 CI 回归门禁脚本 |
| [.github/workflows/build-mac.yml](.github/workflows/build-mac.yml) | GitHub Actions 回归门禁，说明见 [docs/CI.md](docs/CI.md) |
| [docs/ASSETS.md](docs/ASSETS.md) | 比熊位图素材来源与许可说明 |
| [Vendor/NOTICE.md](Vendor/NOTICE.md) | 第三方许可与归属 |
| [docs/](docs/README.md) | 产品设计、验证摘要、接手说明、CI 说明 |
| [AGENTS.md](AGENTS.md) | 开发协作约定 |
| [CLAUDE.md](CLAUDE.md) · [接手说明](docs/HANDOFF.md) | Claude 协作入口与当前状态 |
| `dist/`、`dist-uitest/` | 可再生成的构建产物，不纳入版本管理 |

## 许可证与归属

MoleMonitor 采用 [GPL-3.0-only](LICENSE)。本仓库不包含 Mole 的代码或二进制，只配合 Mole CLI 使用。SMC 协议和传感器键的实现参考 SMCKit 与 Stats，其 MIT 许可证保存在 `Vendor/`，并随构建产物打包。详见 [Vendor/NOTICE.md](Vendor/NOTICE.md)。
