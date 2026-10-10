# scripts 协作约定

继承项目根 [AGENTS.md](../AGENTS.md)，先读本目录 [README.md](README.md)。

- 构建根目录使用 `Path(__file__).resolve().parent.parent`，不依赖固定工作目录或旧 Documents 路径。
- 构建生成文件限于本项目 `dist/`；下载缓存限于 `Vendor/mole-status` 及该目录的临时下载文件。不删除源文件、改上游字节、安装应用、设置登录项或执行清理。
- 下载使用固定官方 release URL，已有缓存与新下载都校验固定 SHA-256，验证成功后才使用；失败退出，不回退到未验证文件或另一版本。采集器缓存不提交到 Git。
- 保留 Mole、SMCKit、Stats 的许可证和归属文件；签名只针对打包副本。
- 构建脚本变更后实际构建，核验 App 与嵌入采集器签名，并跑 `--self-test`。说明最低系统、CPU 架构和工具链要求。
