# scripts 协作约定

继承项目根 [AGENTS.md](../AGENTS.md)，先读本目录 [README.md](README.md)。

- 项目根目录使用 `Path(__file__).resolve().parent.parent`。不依赖固定工作目录或本机路径。
- 构建不下载任何文件，不访问网络。不得重新加入采集器下载。
- 构建只写本项目的 `dist/`。不删除源文件，不安装 App，不设置登录项，不执行清理。
- 版本号只从 `Sources/Core/AppInfo.swift` 读取。不在脚本里写第二份版本号。
- 缺少 `Sources/cli/main.swift` 时，`build.py` 必须失败。不得静默跳过 CLI。
- 保留 SMCKit 与 Stats 的许可证和归属文件。签名只针对打包副本。
- `test_core.py` 与 `test_cli.py` 必须能在 Linux 上运行。它们只用 Foundation 源码。不得让它们依赖 AppKit。
- 改 `build.py` 后，必须在 Mac 上实际构建，核验 App 与 CLI 的签名，并运行 `--self-test`。在 Mac 构建之前，`build.py` 只算未验证。
- 改测试脚本后，运行该脚本并确认全部通过。
