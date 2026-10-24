# scripts 协作约定

继承项目根 [AGENTS.md](../AGENTS.md)，先读本目录 [README.md](README.md)。

- 项目根目录使用 `Path(__file__).resolve().parent.parent`。不依赖固定工作目录或本机路径。
- 构建不下载任何文件，不访问网络。不得重新加入采集器下载。
- 构建只写本项目的 `dist/`。不删除源文件，不安装 App，不设置登录项，不执行清理。
- 版本号只从 `Sources/Core/AppInfo.swift` 读取。不在脚本里写第二份版本号。
- 缺少 `Sources/cli/main.swift` 时，`build.py` 必须失败。不得静默跳过 CLI。
- 保留 SMCKit 与 Stats 的许可证和归属文件。签名只针对打包副本。
- `test_core.py` 与 `test_cli.py` 必须能在 Linux 上运行。它们只用 Foundation 源码。不得让它们依赖 AppKit。
- 改 `build.py` 后，必须在 Mac 或 CI 上实际构建，核验 App 与 CLI 的签名，并运行 `--self-test`。在 macOS 构建之前，`build.py` 只算未验证。
- `--ui-test` 只写 `dist-uitest/`，不改动 `dist/`。`dist-uitest/` 不得分发。
- `ci_acceptance.py` 不安装 App，不修改登录项，不联网。它只在 arm64 macOS 上运行。
- 改 `ci_acceptance.py` 后，运行 `--self-test` 并在 CI 上跑显式 `--ci-headless`。两项具名实体容量范围诊断单列，缺失、类型错误、越界或 API 状态失败仍阻断 CI；默认完整流程和 `--headless-only` 仍严格执行原阈值。默认完整 GUI 路径保留；不在 CI 运行，不以缺少图形会话为由计作通过。不得为了通过而放宽阈值。放宽时必须在 [docs/CI.md](../docs/CI.md) 写明原因。
- `.github/workflows/build-mac.yml` 的成本约束：不得加 `schedule`，不得加多系统或多版本矩阵，保持单作业，保持现有 `timeout-minutes: 30`，保持路径过滤和并发取消。改动前先读 [docs/CI.md](../docs/CI.md)。
- 改测试脚本后，运行该脚本并确认全部通过。
