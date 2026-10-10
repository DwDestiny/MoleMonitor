---
title: "MoleMonitor scripts"
type: module
last_updated: 2026-10-10
---

# scripts

本地构建入口。先读 [AGENTS.md](AGENTS.md)。`fetch_status.py` 从官方固定 release 下载采集器至 Git 忽略的 `Vendor/mole-status`，校验 SHA-256；已有缓存同样检查。`build.py` 调用下载检查，从自身位置找到项目根，编译 `Sources/`、复制采集器与许可证、生成 App 并做本机 ad-hoc 签名；不安装应用或修改登录项。

从根目录执行 `python3 scripts/build.py`；依赖 arm64 macOS、Python 3 与可用 Swift 工具链。首次需要访问 GitHub，后续使用通过哈希核验的缓存。也可单独执行 `python3 scripts/fetch_status.py`。无界面诊断在生成的 App 可执行文件中，入口和验证方法见 [VERIFICATION.md](../docs/VERIFICATION.md)。诊断不启动状态栏和窗口，不输出进程命令行、网络地址或电池序列号。

打包当前构建：`ditto -c -k --keepParent dist/MoleMonitor.app dist/MoleMonitor-0.1.0-arm64.zip`；随后用 `unzip -t` 校验归档。

上述是本机开发打包命令。仓库首版仅发布源码；对外分发捆绑 Mole 的二进制前，应提供同版本对应源码及明确取得方式，不能直接将此 ZIP 当作完成发行准备。
