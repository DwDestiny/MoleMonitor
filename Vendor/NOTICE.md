---
title: "MoleMonitor 上游归属"
type: attribution
last_updated: 2026-10-10
---

# Mole 状态采集器

构建脚本下载 https://github.com/tw93/Mole/releases/tag/V1.59.1 发布的原始 status-darwin-arm64，校验 GitHub release asset SHA-256：04c412f3dec65781b9e69e8a20bcdaa2d217f27cf0eda52843aea910ade39ef6。官方资源 URL 为 https://github.com/tw93/Mole/releases/download/V1.59.1/status-darwin-arm64，源码标签为 https://github.com/tw93/Mole/tree/V1.59.1 。来源 tw93/Mole，许可 GPL-3.0，完整许可见 LICENSE-Mole。

公开仓库只保存归属和许可，不分发采集器二进制。`mole-status` 是 Git 忽略的本机下载缓存，不修改上游，不包含清理模块。App 构建副本会作本机 ad-hoc 签名，所以副本哈希会变化，下载缓存保持原始字节。首版仅发布源码，未提供对外二进制发行/公证流程；后续分发捆绑 App 时须提供同版本对应源码及明确下载指引。

补充传感器的协议参考 SMCKit（https://github.com/beltex/SMCKit），CPU 传感器键目录参考 Stats（https://github.com/exelban/stats）。两者 MIT 许可原文分别保留于 LICENSE-SMCKit、LICENSE-Stats，并随 App 资源打包。自有实现的具体引用及版权注记见 Sources/Sensors.swift。
