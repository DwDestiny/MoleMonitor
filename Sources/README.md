---
title: "MoleMonitor Sources"
type: module
last_updated: 2026-10-10
---

# Sources

只读指标与原生菜单栏界面。先读 [AGENTS.md](AGENTS.md)；架构、口径和决定见 [PROJECT.md](../docs/PROJECT.md)。

| 文件 | 责任 |
|---|---|
| `MoleMonitor.swift` | 状态子进程、NDJSON 适配、应用归并、菜单栏/展开面板和无界面诊断 |
| `Sensors.swift` | 电池、内存压力、SMC 温度与风扇只读采样 |

系统采集和解码在后台，界面在主线程；失败不能当作零值。不得增加清理、sudo、写 SMC 或自动触发删除的能力。上游采集器由构建脚本下载到 `Vendor/` 并核验；公开验证摘要位于 `docs/VERIFICATION.md`，本机诊断原件不提交。
