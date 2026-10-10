# MoleMonitor 协作入口

以本仓库为开发真源。先读 [README.md](README.md)；范围和决定见 [docs/PROJECT.md](docs/PROJECT.md)，验证摘要与待验项见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。Claude 接手见 [CLAUDE.md](CLAUDE.md) 与 [docs/HANDOFF.md](docs/HANDOFF.md)。按任务再读目标模块的 README、AGENTS 和源文件头。代码和公开文档使用可移植路径。

## 范围与模块

- 当前产品是只读监控，清理由用户另行调用 Mole CLI。本版不提供每应用耗电排行，不以 CPU 使用率估算耗电。不自行增加清理、自动删除、sudo、特权 helper、SMC 写入或风扇控制。
- `Sources/` 是自有 Swift：`MoleMonitor.swift` 管理界面、协议、排行与子进程生命周期；`Sensors.swift` 只读补充电池、内存压力、温度和风扇。
- `scripts/` 负责固定版本采集器下载、哈希核验和本地构建；路径从脚本所在项目求得，禁止硬编码本机位置或借构建安装应用、修改登录项。
- `Vendor/` 公开许可证和归属。`mole-status` 是下载缓存，须核验固定版本与哈希，不提交到 Git。构建副本的 ad-hoc 签名可以改变副本哈希，下载原件保持不变。
- 自有代码使用 GPL-3.0-only，保留第三方 GPL/MIT 文件与版权。后续二进制分发需提供同版本对应源码和明确指引，不能只上传捆绑 App。
- `docs/VERIFICATION.md` 是公开验证摘要；`docs/verification/`、`docs/MIGRATION.md` 可保存本机原件但被 Git 忽略，不上传系统快照、进程排行图片或迁移信息。新增验证写新文件，不能覆盖原记录。`dist/` 是可再生成的成品，不手改二进制。

## 实现约束

- 采集、进程输出读取和 JSON 解码在后台，界面更新在主线程；只维持一个状态采集子进程，退出、过期重启与唤醒需管理生命周期。
- 缺失、失败、过期、占位零值与测得的零值必须区分。CPU 温度是可读 CPU 传感器均值；应用 CPU 单核满载为 100%，多核可超过 100%；RSS 合计可能重复计入共享页。
- 网络沿用选定路由/隧道的聚合口径，不把 VPN 与物理承载流量重复相加。
- 不记录完整进程参数、序列号、凭据或其他无关隐私。公开提交不含本机绝对路径、私有知识库链接、个人运行快照或诊断原件。

## 验证与交付

- 构建：`python3 scripts/build.py`。协议检查：`dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test`。真实无界面采样：同一可执行文件 `--diagnose --seconds 22`；界面静态预览需额外传 `--preview <绝对路径>`。
- 构建后核验本机签名；改协议/采集要补对应真实采样，改生命周期要验证对应恢复与退出场景。文档或目录变更用文件完整性、链接和相关构建检查，不为简单文档增加行为测试。
- 默认无感执行，不自行启动可见 UI、安装到 Applications 或设置登录启动；遵守用户当轮授权。静态预览、无界面运行和真实菜单栏交互分开记录。
- Linux VPS 仅用于源码、设计与文档工作；Mac 专有框架、传感器和菜单栏构建/运行验收留在 Mac。不得为 VPS 开发擅自更换 Linux 采集器或把静态检查写成 macOS 验收。
- 更新实际受影响的文件头、模块说明和项目入口；维护验收文档中的已验、未验及风险。推送前复核暂存文件和隐私排除项。对外推送、发布、公证、部署按具体授权执行。
