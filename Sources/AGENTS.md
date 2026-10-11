# Sources 协作约定

继承项目根 [AGENTS.md](../AGENTS.md)，先读本目录 [README.md](README.md)。

## 边界规则

- `Core/` 只依赖 Foundation。不得引入 AppKit、SwiftUI、IOKit 或 UserNotifications。Core 必须能在 Linux 上编译和测试。
- `cli/` 只依赖 Foundation 与 `Core/`。不得引入 AppKit。不得创建线程，不得写文件。
- `App/` 仅限 Mac。需要 AppKit、SwiftUI、UserNotifications 或 Darwin 的代码放这里。把可测试的纯逻辑放进 `Core/`。
- App 与 CLI 共用 `Core/` 的同一份源文件。不得复制逻辑到两处。

## 规则

- 保持后台采样、主线程界面。无界面入口不得创建状态栏或可见窗口。
- 未知或失败的值保持可选值，不补成零。
- 传感器只读键。不写 SMC，不提权，不控制风扇。不读取完整进程参数。
- 改 `Core/` 或 `cli/` 后，运行 `python3 scripts/test_core.py` 与 `python3 scripts/test_cli.py`。
- 改 `App/` 后，必须在 Mac 上构建并验证。在此之前，文档不得写成已验证。
- 跨模块变更同步更新对应说明和文件头。原件可新增到 Git 忽略的 `docs/verification/`，不覆盖基线。公开提交只更新脱敏摘要。
