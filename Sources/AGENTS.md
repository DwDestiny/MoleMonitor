# Sources 协作约定

继承项目根 [AGENTS.md](../AGENTS.md)，先读本目录 [README.md](README.md)。

## 边界规则

- `Core/` 只依赖 Foundation。不得引入 AppKit、SwiftUI、IOKit 或 UserNotifications。Core 必须能在 Linux 上编译和测试。
- `cli/` 只依赖 Foundation 与 `Core/`。不得引入 AppKit。不得创建线程，不得写文件。
- `App/` 仅限 Mac。需要 AppKit、SwiftUI、UserNotifications 或 Darwin 的代码放这里。把可测试的纯逻辑放进 `Core/`。
- 测试代码只放在 `#if UITEST` 内。`Sources/App/UITestHarness.swift` 整个文件在 `#if UITEST` 内。发布二进制不得含测试代码，`scripts/ci_acceptance.py` 会检查。
- App 与 CLI 共用 `Core/` 的同一份源文件。不得复制逻辑到两处。

## 规则

- 保持后台采样、主线程界面。无界面入口不得创建状态栏或可见窗口。
- 状态卡关闭时，只允许引擎的 5 分钟 tick。实时采样定时器只在状态卡打开期间存在，关闭时取消并清空缓冲。实时点不落盘。
- `Panel.swift` 不创建 `Timer`，不使用 `TimelineView`。
- 未知或失败的值保持可选值，不补成零。
- 传感器只读键。不写 SMC，不提权，不控制风扇。不读取完整进程参数。
- 改 `Core/` 或 `cli/` 后，运行 `python3 scripts/test_core.py` 与 `python3 scripts/test_cli.py`。
- 改 `App/` 后，先过 CI 回归门禁，再请用户在 Mac 上确认。文档可以写“通过回归门禁”，不得写成“真机验收通过”。
- 跨模块变更同步更新对应说明和文件头。原件可新增到 Git 忽略的 `docs/verification/`，不覆盖基线。公开提交只更新脱敏摘要。
