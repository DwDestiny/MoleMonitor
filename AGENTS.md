# MoleMonitor 协作入口

以本仓库为开发真源。先读 [README.md](README.md)。产品范围和设计决定见 [docs/PROJECT.md](docs/PROJECT.md)。验证摘要与待验项见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。Claude 接手见 [CLAUDE.md](CLAUDE.md) 与 [docs/HANDOFF.md](docs/HANDOFF.md)。按任务再读目标目录的 README、AGENTS 和源文件头。代码和公开文档使用可移植路径。

## 范围与模块

- 产品只检测和预警。清理由用户的 agent 调用 Mole CLI。不增加清理、自动删除、sudo、特权 helper、SMC 写入或风扇控制。不提供每应用耗电排行，不以 CPU 使用率估算耗电。
- `Sources/Core/` 只依赖 Foundation，放健康规则、存储、实时曲线数据和 CLI 报告逻辑。`Sources/App/` 是 Mac 专用的引擎、采样、通知和界面。测试代码只放在 `#if UITEST` 内。`Sources/cli/` 是 `molemonitor-cli`，只依赖 Foundation 与 Core。
- `Sources/MoleMonitor.swift` 是入口。`Sources/Sensors.swift` 是只读 SMC，阶段 1 不引用。目录细节见 [Sources/README.md](Sources/README.md)。
- `scripts/` 放构建与测试脚本。路径从脚本所在项目求得，禁止硬编码本机位置，禁止借构建安装应用或修改登录项。构建不下载任何文件。
- `Vendor/` 保存 SMCKit 与 Stats 的许可证和归属。不保存 Mole 的代码或许可证。
- 自有代码使用 GPL-3.0-only。后续二进制分发须提供同版本对应源码和明确指引。
- `docs/VERIFICATION.md` 是公开验证摘要。`docs/verification/` 与 `docs/MIGRATION.md` 可保存本机原件，但被 Git 忽略。新增验证写新条目，不覆盖旧记录。`dist/` 可再生成，不手改二进制。

## 实现约束

- 采样和文件读写在后台队列，界面更新在主线程。状态卡关闭时，只维持引擎的 5 分钟 tick，没有高频定时器。状态卡打开期间，允许一个 2 秒实时采样定时器，关闭即取消并清空缓冲。实时点不落盘。
- 缺失、失败、过期与测得的零值必须区分。
- 应用 CPU 的单核满载为 100%，多核可超过 100%。网络只合计物理网卡，不重复计入 VPN。
- 不记录完整进程参数、序列号、凭据或其他无关隐私。公开提交不含本机绝对路径、私有知识库链接、个人运行快照或诊断原件。

## 验证与交付

- 在 Linux 或 Mac 上测试 Core：`python3 scripts/test_core.py`。测试 CLI：`python3 scripts/test_cli.py`。两者需要 `swiftc`，细节见 [scripts/README.md](scripts/README.md)。
- 在 Mac 上构建：`python3 scripts/build.py`。构建后运行 `dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test`。无界面采样：同一可执行文件加 `--diagnose --seconds 22`。静态预览另加 `--preview <绝对路径>`。
- Mac 专用行为（`Sources/App/`、`Sources/MoleMonitor.swift`）的第一道验证走 CI 回归门禁（`.github/workflows/build-mac.yml`，说明见 [docs/CI.md](docs/CI.md)）。CI 结果不得写成真机验收。真机帧率、观感、菜单栏位置和通知授权框仍须用户在 Mac 上确认。Linux 桩类型检查只算静态检查。
- 改 Core 或 CLI 后，必须跑对应测试脚本。改生命周期、通知或界面后，必须过 CI 回归门禁，再请用户在 Mac 上确认对应场景。
- 不得给 `build-mac.yml` 加 `schedule`，不得加多系统矩阵，保持单作业与超时。仓库改为私有前，先复核计费，见 [docs/CI.md](docs/CI.md)。
- 默认无感执行。不自行启动可见 UI，不安装到 Applications，不设置登录启动。遵守用户当轮授权。静态预览、无界面运行和真实菜单栏交互分开记录。
- 更新实际受影响的文件头、模块说明和项目入口。维护验证文档中的已验、未验及风险。推送前复核暂存文件和隐私排除项。对外推送、发布、公证、部署按具体授权执行。
