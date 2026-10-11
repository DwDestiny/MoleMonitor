---
title: "MoleMonitor scripts"
type: module
last_updated: 2026-10-11
---

# scripts

本地构建与测试入口。先读 [AGENTS.md](AGENTS.md)。所有脚本从自身位置求得项目根目录，不依赖当前工作目录。

| 脚本 | 平台 | 用途 |
|---|---|---|
| `build.py` | 仅 Mac（arm64，macOS 14+） | 编译 App 与 CLI，组装并签名 `dist/MoleMonitor.app`。加 `--ui-test` 则构建 `dist-uitest/MoleMonitor.app` |
| `ci_acceptance.py` | 仅 arm64 macOS | 回归门禁：对已构建的 App 做签名、自检、真实采样、CLI 读回、预览图和界面回归检查 |
| `test_core.py` | Linux 与 Mac | 编译并运行 `Tests/CoreTests/`，共 353 条断言 |
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

加参数 `--ui-test` 时，脚本用 `-D UITEST` 编译，输出到 `dist-uitest/MoleMonitor.app`，不改动 `dist/`。该变体含界面回归测试代码，不得分发。

## ci_acceptance.py

在 arm64 macOS 上，先运行 `python3 scripts/build.py` 和 `python3 scripts/build.py --ui-test`，再运行 `python3 scripts/ci_acceptance.py`。其他平台上脚本直接退出。环境变量 `MOLEMONITOR_CI_OUT` 指定输出目录，默认是系统临时目录。

脚本按以下顺序检查：

1. 签名、`Info.plist` 版本号、`LSUIElement`、标识符。
2. `--self-test`。
3. 22 秒真实无界面采样，以及实时采样探针（状态卡打开时开启，关闭后停止）。报告含引擎的 `diagnosticSnapshot`（打开、关闭、结束三个时刻）。脚本核对内存压力、热状态、swap、前台 App、覆盖率、芯片、提示词设置、定时器数与进程扫描周期。
4. 数据文件权限（目录 0700，文件 0600）。
5. CLI 读回与只读，CLI 耗时（30 次）。
6. 28 张预览 PNG：7 个场景、浅深两种外观、满数据与空数据。宽 656 像素，高度对应三档（332、560、620 pt），文件两两不同（M1、M3）。
7. 发布二进制不含测试代码。`Panel*.swift` 的每个按钮有标识符和中文标签，且不含 `Timer` 与 `TimelineView`。
8. 运行测试变体的 `--ui-test`，核对项 A 至 L，以及状态卡门禁 M2、M3、M4、M5、M6、M11、M12、M13，以及真实引擎门禁 N1、N2，菜单栏图标 M14，比熊渲染 M19。项的含义见 [CI.md](../docs/CI.md)。

脚本不安装 App，不修改登录项。运行 `--ui-test` 时，状态卡会在屏幕上显示约 30 秒，使用临时数据目录。结果是回归门禁，不是真机验收。

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
