---
title: "MoleMonitor · 图像素材"
type: assets
last_updated: 2026-10-18
---

# 图像素材

v3 起，项目没有 AI 生成的图像素材。仓库没有 `Resources/` 目录，构建不复制任何位图。

| 项 | 现状 |
|---|---|
| 面板 | 没有位图。标题块、问题行、曲线和爪印章都是代码绘制 |
| 菜单栏图标 | 比熊侧视剪影，用 `Path` 矢量绘制，见 `Sources/App/MenuRunnerShapes.swift` |
| 应用图标 | 本文件不记录。如果以后添加应用图标，先在这里登记来源与许可 |
| 许可 | 全部自有代码适用 GPL-3.0-only。第三方归属见 [Vendor/NOTICE.md](../Vendor/NOTICE.md) |

## 历史

v2 曾使用 AI 生成的比熊图像：8 张位图和 10 个动作的序列帧条带。这些图像的版权归属在法律上不确定。2026-10-18，用户决定删除比熊（原话 U10，见 [DESIGN_V3.md](DESIGN_V3.md) 4.1）。图像、`scripts/check_sprites.py` 和相关门禁都已删除，许可风险随之消失。原文件在 git 历史里。

## 以后添加素材

1. 先在本文件登记：文件名、来源、日期、许可。
2. 如果素材由 AI 生成，先让用户确认版权与服务条款，再提交。
3. 在 [Vendor/NOTICE.md](../Vendor/NOTICE.md) 或本文件写明归属。

> **注意**：`.github/workflows/build-mac.yml` 的 CI 门禁检查包内没有 `DogArt` 与 `DogSprites`，源码树没有 `Resources/`。添加素材前先改这条门禁，见 [CI.md](CI.md)。
