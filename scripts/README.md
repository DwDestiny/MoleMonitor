---
title: "MoleMonitor scripts"
type: module
last_updated: 2026-10-24
---

# scripts

本地构建与测试入口。先读 [AGENTS.md](AGENTS.md)。所有脚本从自身位置求得项目根目录，不依赖当前工作目录。

| 脚本 | 平台 | 用途 |
|---|---|---|
| `build.py` | 仅 Mac（arm64，macOS 14+） | 编译 App 与 CLI，组装并签名 `dist/MoleMonitor.app`。加 `--ui-test` 则构建 `dist-uitest/MoleMonitor.app` |
| `ci_acceptance.py` | 仅 arm64 macOS | CI 显式 `--ci-headless`：签名、自检、真实采样、CLI 读回、离屏静态预览和审计；默认完整 GUI 自动化入口历史保留 |
| `test_core.py` | Linux 与 Mac | 编译并运行 `Tests/CoreTests/`，共 5074 条断言 |
| `test_cli.py` | Linux 与 Mac | 编译 `molemonitor-cli`，运行 124 项检查 |

## build.py

在项目根目录运行 `python3 scripts/build.py`。脚本不下载文件，不需要网络。如果运行平台不是 macOS，脚本报错退出。

脚本按以下顺序工作：

1. 从 `Sources/Core/AppInfo.swift` 读取版本号。
2. 用 `swiftc` 编译 `Sources/Core/`、`Sources/App/`、`Sources/MoleMonitor.swift` 和 `Sources/Sensors.swift`，得到 `Contents/MacOS/MoleMonitor`。
3. 用 `swiftc` 编译 `Sources/Core/` 和 `Sources/cli/main.swift`，得到 `Contents/Helpers/molemonitor-cli`。
4. 复制 `LICENSE`、`Vendor/LICENSE-SMCKit`、`Vendor/LICENSE-Stats` 和 `Vendor/NOTICE.md` 到 `Contents/Resources/`。
5. 不复制位图或序列帧资源（`Resources/` 已随比熊删除，U10）。
6. 写入 `Info.plist`。
7. 先对 CLI，再对整个 App 做 ad-hoc 签名。

脚本只删除并重建本项目的 `dist/MoleMonitor.app`。脚本不安装 App，不修改登录项。

加参数 `--ui-test` 时，脚本用 `-D UITEST` 编译，输出到 `dist-uitest/MoleMonitor.app`，不改动 `dist/`。该变体含界面回归测试代码，不得分发。

## ci_acceptance.py

CI 在 arm64 macOS 上构建普通 App 后运行 `python3 scripts/ci_acceptance.py --ci-headless`。该模式不要求 `dist-uitest/`，不启动窗口、状态栏交互、合成事件或屏幕捕获。它保留原有签名、包信息、自检、22 秒真实引擎采样、数据权限、CLI 读回/只读/耗时、28 张离屏静态预览、源码审计、Core 日志门禁和发布二进制无测试代码检查。实体容量范围诊断只单列 `disk used is between 0 and total` 与 `disk available_important is plausible`：照常使用原表达式和阈值，记录每项 PASS/FAIL，失败通过日志 warning、GitHub summary 与报告暴露，不计为软件门禁通过。其余检查仍阻断 CI；容量数据缺失、非整数、负数、越界或 API 状态失败也阻断 CI。

`MOLEMONITOR_CI_OUT` 指定临时输出根目录，默认是系统临时目录；`MOLEMONITOR_CORE_LOG` 指向 `test_core.py` 的日志，W13、W20、W21 仍须读取有效结果。`molemonitor-ci/acceptance-report.json` 在 CI 模式记录 `scope=ci-headless`、`gate.status` 与 `capacity_diagnostics`。只有实体容量诊断失败时，软件门禁可为 `gate.status=pass`，但顶层 `status=diagnostic_failure`，失败项仍列在 `failures` 中；其他失败返回非零。UI 与实机验收记录 `not_run`，不计入通过数。无界面 CI 通过不等于图形或实机验收通过。对应版本的图形和交互由 computer use 在本机 Mac 实测。

`--headless-only` 保留严格无界面验收：实体容量诊断失败仍返回非零。

不带参数的默认入口仍执行原有完整检查，含 UI 变体正控和完整 `--ui-test` 门禁，所有阈值保持原样。这个历史入口需要事先运行 `build.py --ui-test`，仅保留供研究和追溯，不再作为 CI 或本轮本机执行的强制关卡。

`python3 scripts/ci_acceptance.py --self-test` 可在任何系统验证登记表、源码审计、显式 scope 和发布二进制审计的正反控制；不启动 App。所有模式均不安装 App、不改登录项、不联网。

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
