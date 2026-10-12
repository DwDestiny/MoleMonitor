---
title: "MoleMonitor · 只读菜单栏监控"
type: project
last_updated: 2026-10-12
---

# MoleMonitor

MoleMonitor 是 macOS 菜单栏上的轻量状态监测与预警工具。它只检测和预警，不做清理。清理由用户的 agent 调用 [Mole](https://github.com/tw93/Mole) CLI 完成。

> **注意**：功能代码已经写完。`Sources/Core/` 与 CLI 已在 Linux 上测试。`Sources/App/` 已在 GitHub Actions 的 macOS 虚拟机上通过回归门禁（见 [docs/CI.md](docs/CI.md)），但尚未在用户的 Mac 上人工验收。状态卡与比熊的设计见 [docs/DESIGN.md](docs/DESIGN.md)，产品范围见 [docs/PROJECT.md](docs/PROJECT.md)，验证范围见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。

## 功能

MoleMonitor 是只读的 macOS 14+ 菜单栏健康哨兵。它检查 CPU、内存、温度、磁盘和耗电五个健康项。有问题时，状态卡突出问题名与证据，正常项靠后。

| 位置 | 内容 |
|---|---|
| 菜单栏 | 比熊头像剪影加类别角标。状态变化时播放一次短动画 |
| 状态卡 | 安静模式（没有问题）和问题模式（有问题）。问题卡带 2 小时曲线与已持续时间。占用 App 前 5 名。“复制给 Agent”按钮。尺寸与版面见 [docs/DESIGN.md](docs/DESIGN.md) 第 2 章 |
| 比熊 | AI 生成的位图姿态，姿态切换时 0.22 秒淡入，没有连续动画。素材许可状态见 [docs/ASSETS.md](docs/ASSETS.md) |
| 系统通知 | 磁盘、内存、CPU、温度、耗电的异常，带冷却时间与全局上限 |
| CLI | `molemonitor-cli` 读取状态，输出 JSON 或一行中文。`prompt` 命令输出排查提示词 |

“复制给 Agent”生成不超过 3000 字的提示词。提示词禁止 `mo optimize`、`mo uninstall` 和非 dry-run 清理。

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
dist/MoleMonitor.app/Contents/Helpers/molemonitor-cli prompt --topic cpu
```

| 命令 | 输出 |
|---|---|
| `--status` | 完整状态 JSON |
| `--status --brief` | 一行中文摘要 |
| `--disk-history [--days N]` | 每天一行的磁盘真实已用与增长量。默认 30 天，最大 60 天 |
| `--schema` | 字段说明与口径说明 |
| `prompt [--topic T]` | 排查提示词。T 取 `disk`、`memory`、`cpu`、`thermal`、`power`、`network` |
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
| `trend.json` | 2 小时趋势缓冲，每 5 分钟写一次，重启后恢复 |

工具不联网，不读取进程命令参数，不记录序列号或凭据。完整落盘规则见 [docs/PROJECT.md](docs/PROJECT.md) 的 6.3 节。

## 验证状态

| 范围 | 状态 |
|---|---|
| `Sources/Core/`、CLI | 在 Linux 上通过测试：Core 4171 条断言，CLI 116 项检查 |
| `Sources/App/` | 在 CI 的 macOS 虚拟机上构建并通过回归门禁（最新绿色主分支运行见 [VERIFICATION.md](docs/VERIFICATION.md) 条目 6）。不是真机验收 |
| 动效手感、真机 CPU、观感、真实菜单栏位置、通知授权框、剪贴板、电池行、网卡计数器的特殊场景 | 未验证，需要用户在自己的 Mac 上确认。清单见 [docs/HANDOFF.md](docs/HANDOFF.md) |

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
