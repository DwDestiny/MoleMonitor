---
title: "MoleMonitor · 验证摘要与待验项"
type: verification
last_updated: 2026-10-11
---

# 验证摘要与待验项

本页分三栏记录：已在 Linux 验证、仅静态检查、未验证。新增验证写新条目，不覆盖旧记录。

## 条目 2：阶段 1 重构（2026-10-11，Linux）

### 已在 Linux 验证

| 检查 | 结果 | 覆盖边界 |
|---|---|---|
| Core 测试 `python3 scripts/test_core.py` | 294 条断言通过 | 只覆盖 `Sources/Core/` 的纯逻辑，不含 AppKit |
| CLI 测试 `python3 scripts/test_cli.py` | 79 项检查通过 | 在 Linux 上构建并运行 `molemonitor-cli`，含输出、退出码和只读行为 |
| CLI 耗时 | p50 约 11 ms，p95 约 16 ms | 在 Linux VPS 上测得，不代表 Mac |

### 仅静态检查

| 检查 | 结果 | 覆盖边界 |
|---|---|---|
| `Sources/App/` 的引擎逻辑 | Linux 桩类型检查通过 | 桩类型替代 AppKit 等框架，只证明类型一致，不证明运行行为 |

### 未验证

- 所有 AppKit、SwiftUI、UserNotifications 行为：菜单栏图标、状态卡、弹出与关闭、深浅色。
- `scripts/build.py` 在 Mac 上的构建、签名与 `Info.plist`。
- `--self-test`、`--diagnose`、`--preview` 在 Mac 上的运行。
- `sysctl NET_RT_IFLIST2` 网卡计数器，包括 Thunderbolt 桥接成员 `en1` 至 `en4` 是否被重复计数（验证项 V22）。
- 通知授权流程，包括 ad-hoc 签名下能否弹出授权框（验证项 V19）。
- 菜单栏图标的实际外观，包括红色角标。
- 磁盘读取耗时与"重要用途可用容量"的行为（验证项 V10、V11）。
- Mac 上的 CLI 耗时（验证项 V17，目标 p95 ≤ 20 ms）。
- 睡眠与唤醒后的引擎行为。
- 长时间运行的 CPU、内存和电池影响（目标见 [PROJECT.md](PROJECT.md) 6.3 节）。
- 其他芯片与 macOS 14 的兼容性。
- 公证与分发。

验证项编号与判定标准见 [PROJECT.md](PROJECT.md) 第 11 节。

## 检查方法

在 Linux 或 Mac 上，从项目根目录运行：

```bash
python3 scripts/test_core.py
python3 scripts/test_cli.py
```

在 Mac 上，运行：

```bash
python3 scripts/build.py
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --self-test
codesign --verify --deep --strict dist/MoleMonitor.app
dist/MoleMonitor.app/Contents/MacOS/MoleMonitor --diagnose --seconds 22
```

诊断命令不创建状态栏或可见窗口。需要静态预览时，在参数后加 `--preview <绝对输出路径>`。

新增测试要记录日期、设备与系统、采样时长、退出状态和覆盖范围。对外提交诊断材料前，去除本地路径和应用快照。真实 UI 检查、无界面采样与静态预览分别记录。

## 条目 1：第一版验证记录（2026-10-10，第一版，方案已废弃）

> **注意**：以下记录针对第一版代码，即下载 Mole 状态采集器的方案。该方案已废弃并从代码中删除。这些结果不适用于当前代码。保留它们只为存档。

2026-10-10，在一台 Apple M5/macOS 27 设备上完成以下检查。原始诊断含本地目录与应用快照信息，未随公开源码分发。

| 检查 | 结果 | 覆盖边界 |
|---|---|---|
| 90 秒真实采样 | 取得 44 帧，CPU、内存、网络、电池、传感器和应用数据有值 | 无界面运行，没有创建菜单栏 UI |
| 同次资源采样 | 45 次采样：CPU 均值约 0.49%、峰值 4.9%，峰值 RSS 37.9 MiB。退出后已知关联进程残留为 0 | 不含可见 GUI，不能外推长期耗电 |
| 受控故障恢复 | 坏 JSON 行、分片数据、后端忽略 TERM 并停止输出时，监控能终止后端并恢复采集 | 故障注入不代表真实睡眠与唤醒 |
| 最终构建短诊断 | 22 秒取得 12 帧，退出码 0，stderr 为 0 字节 | 当次短时数据 |
| 静态预览 | 使用当次真实数据生成并检查了静态面板图 | 非 App 窗口截图，不证明菜单点击通过 |
| 构建与协议 | 构建、`--self-test`、本地签名验证及文档检查通过 | 不代替 GUI、兼容性或长期运行验收 |
| 目录整理后复核 | 重新构建、协议检查、签名与 ZIP 校验通过。22 秒取得 12 帧，退出码 0，stderr 为 0 字节 | 迁移复核不扩大功能覆盖 |
| 开源源码构建 | 从无采集器缓存的源码副本下载固定官方资源，核验 SHA-256，构建、协议检查与签名验证通过。无效缓存拒绝检查通过 | 证明旧方案的首次构建路径可用，未创建可见 UI |

第一版的 `--self-test` 覆盖结构化解码、样本时间、缺失与失败占位值、网络聚合和坏 JSON。当前代码的 `--self-test` 已重写，覆盖范围不同。
