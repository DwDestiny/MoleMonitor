# Claude 协作入口

先读 [AGENTS.md](AGENTS.md)，遵循其中的产品范围、实现约束和验证边界。项目概览见 [README.md](README.md)，本次接手背景、可用命令和下一步见 [docs/HANDOFF.md](docs/HANDOFF.md)。按任务再读目标模块的 README 和 AGENTS；不要把整套项目规则复制到另一份文档。

这是 Apple Silicon / macOS 14+ 的只读菜单栏项目。Linux VPS 用于阅读、设计和修改源码，不能完成 AppKit、IOKit、AppleSMC 或菜单栏的运行验收；构建和真实设备检查在 Mac 上完成。不为适配 VPS 擅自更换为 Linux 采集器或改变产品平台。

本次只完成项目文件交接，没有启动 Claude 会话，也没有开启持续双向同步。具体机器路径与同步收据保存在被 Git 忽略的 `local-notes/`（若存在）；公开文档保持可移植。
