# MoleMonitor 协作入口

以本仓库为开发真源。先读 [README.md](README.md)。产品范围和设计决定见 [docs/PROJECT.md](docs/PROJECT.md)。验证摘要与待验项见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。Claude 接手见 [CLAUDE.md](CLAUDE.md) 与 [docs/HANDOFF.md](docs/HANDOFF.md)。按任务再读目标目录的 README、AGENTS 和源文件头。代码和公开文档使用可移植路径。

## 范围与模块

- 产品只检测和预警。清理由用户的 agent 调用 Mole CLI。不增加清理、自动删除、sudo、特权 helper、SMC 写入或风扇控制。不提供每应用耗电排行，不以 CPU 使用率估算耗电。
- `Sources/Core/` 只依赖 Foundation，放健康规则、存储和 CLI 报告逻辑。`Sources/App/` 是 Mac 专用的引擎、采样、通知和界面。`Sources/cli/` 是 `molemonitor-cli`，只依赖 Foundation 与 Core。
- `Sources/MoleMonitor.swift` 是入口。`Sources/Sensors.swift` 是只读 SMC，阶段 1 不引用。目录细节见 [Sources/README.md](Sources/README.md)。
- `scripts/` 放构建与测试脚本。路径从脚本所在项目求得，禁止硬编码本机位置，禁止借构建安装应用或修改登录项。构建不下载任何文件。
- `Vendor/` 保存 SMCKit 与 Stats 的许可证和归属。不保存 Mole 的代码或许可证。
- 自有代码使用 GPL-3.0-only。后续二进制分发须提供同版本对应源码和明确指引。
- `docs/VERIFICATION.md` 是公开验证摘要。`docs/verification/` 与 `docs/MIGRATION.md` 可保存本机原件，但被 Git 忽略。新增验证写新条目，不覆盖旧记录。`dist/` 可再生成，不手改二进制。

## 实现约束

- 采样和文件读写在后台队列，界面更新在主线程。只维持一个引擎定时器，不增加高频定时器。
- 缺失、失败、过期与测得的零值必须区分。
- 应用 CPU 的单核满载为 100%，多核可超过 100%。网络只合计物理网卡，不重复计入 VPN。
- 不记录完整进程参数、序列号、凭据或其他无关隐私。公开提交不含本机绝对路径、私有知识库链接、个人运行快照或诊断原件。

## 验证与交付

- 在 Linux 或 Mac 上测试 Core：`python3 scripts/test_core.py`。测试 CLI：`python3 scripts/test_cli.py`。两者需要 `swiftc`，细节见 [scripts/README.md](scripts/README.md)。
- 在 Mac 上构建：`python3 scripts/build.py`。构建后运行 `dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test`。无界面采样：同一可执行文件加 `--diagnose --seconds 22`。静态预览另加 `--preview <绝对路径>`。
- `Sources/App/` 与 `Sources/MoleMonitor.swift` 只能在 Mac 上验证。在 Mac 编译和运行之前，不得把它们写成已验证。Linux 桩类型检查只算静态检查。
- 改 Core 或 CLI 后，必须跑对应测试脚本。改生命周期、通知或界面后，必须在 Mac 上验证对应场景。
- 默认无感执行。不自行启动可见 UI，不安装到 Applications，不设置登录启动。遵守用户当轮授权。静态预览、无界面运行和真实菜单栏交互分开记录。
- 更新实际受影响的文件头、模块说明和项目入口。维护验证文档中的已验、未验及风险。推送前复核暂存文件和隐私排除项。对外推送、发布、公证、部署按具体授权执行。
