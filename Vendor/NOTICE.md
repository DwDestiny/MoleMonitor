---
title: "MoleMonitor 上游归属"
type: attribution
last_updated: 2026-10-11
---

# 与 Mole CLI 的关系

MoleMonitor 配合 Mole CLI（https://github.com/tw93/Mole ，许可 GPL-3.0）使用。MoleMonitor 只监测和预警。清理由用户或用户的 agent 调用 Mole CLI 完成。

MoleMonitor 不包含、不下载、不打包 Mole 的任何代码或二进制。MoleMonitor 不调用 Mole CLI。因此本仓库不保存 Mole 的许可证文件。

# 参考的上游项目

补充传感器的协议参考 SMCKit（https://github.com/beltex/SMCKit），CPU 传感器键目录参考 Stats（https://github.com/exelban/stats）。两者的 MIT 许可原文分别保存在 LICENSE-SMCKit 和 LICENSE-Stats，并随 App 资源一起打包。自有实现的具体引用和版权注记见 Sources/Sensors.swift。

# 自有代码

自有代码使用 GPL-3.0-only，许可原文见项目根目录的 LICENSE。构建副本使用本机 ad-hoc 签名。后续分发 App 二进制时，须同时提供同版本的对应源码和明确的取得方式。
