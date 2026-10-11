---
title: "MoleMonitor scripts"
type: module
last_updated: 2026-10-11
---

# scripts

本地构建与测试入口。先读 [AGENTS.md](AGENTS.md)。所有脚本从自身位置求得项目根目录，不依赖当前工作目录。

| 脚本 | 平台 | 用途 |
|---|---|---|
| `build.py` | 仅 Mac（arm64，macOS 14+） | 编译 App 与 CLI，组装并签名 `dist/MoleMonitor.app` |
| `test_core.py` | Linux 与 Mac | 编译并运行 `Tests/CoreTests/`，共 294 条断言 |
| `test_cli.py` | Linux 与 Mac | 编译 `molemonitor-cli`，运行 79 项检查 |

## build.py

在项目根目录运行 `python3 scripts/build.py`。脚本不下载文件，不需要网络。如果运行平台不是 macOS，脚本报错退出。

脚本按以下顺序工作：

1. 从 `Sources/Core/AppInfo.swift` 读取版本号。
2. 用 `swiftc` 编译 `Sources/Core/`、`Sources/App/`、`Sources/MoleMonitor.swift` 和 `Sources/Sensors.swift`，得到 `Contents/MacOS/MoleMonitor`。
3. 用 `swiftc` 编译 `Sources/Core/` 和 `Sources/cli/main.swift`，得到 `Contents/Helpers/molemonitor-cli`。
4. 复制 `LICENSE`、`Vendor/LICENSE-SMCKit`、`Vendor/LICENSE-Stats` 和 `Vendor/NOTICE.md` 到 `Contents/Resources/`。
5. 写入 `Info.plist`。
6. 先对 CLI，再对整个 App 做 ad-hoc 签名。

脚本只删除并重建本项目的 `dist/MoleMonitor.app`。脚本不安装 App，不修改登录项。

## 测试脚本

编译器查找顺序：环境变量 `SWIFTC`，然后 `~/.local/bin/swiftc-local`，然后 `PATH` 中的 `swiftc`。两个测试脚本都在临时目录里编译，不写入项目。测试失败时退出码不为 0。

```bash
python3 scripts/test_core.py
python3 scripts/test_cli.py
```

`test_cli.py` 还检查 CLI 的只读行为和耗时。Linux 上测得的耗时不代表 Mac。

## 打包

打包当前构建：`ditto -c -k --keepParent dist/MoleMonitor.app dist/MoleMonitor-0.2.0-arm64.zip`。然后用 `unzip -t` 校验归档。文件名中的版本号必须与 `Sources/Core/AppInfo.swift` 一致。这是本机开发打包命令。对外分发 App 二进制前，须提供同版本对应源码和明确指引。

验证方法见 [VERIFICATION.md](../docs/VERIFICATION.md)。
