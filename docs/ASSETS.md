---
title: "MoleMonitor · 图像素材"
type: assets
last_updated: 2026-10-12
---

# 图像素材

本文件记录项目里不是手写代码的图像素材：来源、许可状态和发布前必须确认的事项。当前有两组素材：状态卡比熊的 8 张位图（第 1 节），以及面板 v2 英雄区的比熊动作条带（第 1A 节）。

## 1. 比熊位图（`Resources/DogArt/`）

| 项 | 内容 |
|---|---|
| 文件 | `dog_lie.png`、`dog_stand.png`、`dog_walk.png`、`dog_trot.png`、`dog_sprint.png`、`dog_pant.png`、`dog_alert.png`、`dog_gray.png` |
| 格式 | PNG，透明底，320 × 240 px，每张一只比熊，底边对齐 |
| 用途 | 状态卡的比熊。姿态映射见 [DESIGN.md 4.9](DESIGN.md#49-位图阶段) |
| 打包 | `scripts/build.py` 把 8 个文件复制到 `Contents/Resources/DogArt/`。少于或多于 8 个时，构建报错退出 |
| 体积 | 8 个文件共约 0.37 MB（解码后约 2.4 MB） |

## 1A. 比熊动作条带（`Resources/DogSprites/`）

| 项 | 内容 |
|---|---|
| 文件 | 10 张 PNG 条带：`lie_idle`、`walk`、`trot`、`sprint`、`sniff`、`sit_gray`、`stand_up`、`wag`、`pant_lie`、`notice`，以及 `manifest.json` |
| 格式 | PNG，透明底。每帧 320 × 240 px（@2x），帧横向排列。比熊面朝左，脚底线 y = 230 px |
| 帧数 | 合计 59 帧。`stand_up` 为 6 帧 18 fps，[DESIGN_V2.md 4.3](DESIGN_V2.md#43-动作清单首版) 写 4 帧 12 fps，时长同为 0.33 s。改动原因：4 帧时相邻帧差超过 W11 上限 0.25。其余动作与 4.3 一致。生成的条带 9 张。`sit_gray.png` 由 `dog_gray.png` 镜像得到，不生成 |
| 清单 | `manifest.json` 记录每个动作的帧数、帧率、播放方式、静止帧、代表帧、着地帧、站立帧和面部区域 |
| 用途 | 面板 v2 英雄区的序列帧动画，见 [DESIGN_V2.md 第 11 章](DESIGN_V2.md#11-动画引擎性能预算与降级) |
| 打包 | `scripts/build.py` 复制 `Resources/DogArt/`。如果 `Resources/DogSprites/` 存在，则也复制到 `Contents/Resources/DogSprites` |
| 道具 | `bed_some.png`、`bed_full.png`：磁盘黄与磁盘红时舞台左下的狗窝（蓝灰色软垫狗窝，前沿有缺口，里面放带封箱胶带的纸箱），每张 192 × 112 px（96 × 56 pt），底线 y = 108 px |
| 体积 | 12 张 PNG（10 张条带与 2 个道具）共 2,488,417 字节（约 2.49 MB，2.37 MiB，无损 PNG，不量化）。上限 4 MB（11.3）。全部 59 帧解码后约 18 MB，所以引擎只缓存当前动作与预取动作 |
| 门禁 | `python3 scripts/check_sprites.py`（W11）。需要 Pillow 与 numpy。加 `--sheet-dir 目录` 输出白底、深色底、彩色底的联系表，供人工盲测 |

生成方式、提示词、调用次数与后处理步骤见 [Resources/DogArt/PROVENANCE.md](../Resources/DogArt/PROVENANCE.md) 的“Action strips for panel v2”一节。

## 2. 来源

| 项 | 内容 |
|---|---|
| 生成方式 | AI 图像生成。不是手绘 |
| 模型 | `gpt-image-2.5`，经 OpenAI 兼容中转站调用 |
| 日期 | 2026-10-12 |
| 提示词与处理步骤 | 见 [Resources/DogArt/PROVENANCE.md](../Resources/DogArt/PROVENANCE.md) |
| 后处理 | 脚本清理透明度，统一缩放，底边对齐。`dog_gray.png` 由 `dog_stand.png` 去色得到 |
| 动作条带 | 同一模型，同一中转站，2026-10-12。以 `dog_stand.png` 为参考图（`stand_up` 另加 `lie_idle` 的一帧作第二张参考图），每个动作一次 `edit` 调用出一行条带，共 23 次调用。后处理：透明度下限 80、上限 200，镜像为面朝左，按眼鼻三角形大小统一比例，脚底线对齐，水平配准。不重画、不混合、不调色 |

本项目的构建不调用任何模型，也不下载任何文件。素材已经生成，作为文件提交在仓库里。

## 3. 许可状态

> **警告**：不要把这 8 张图和 `Resources/DogSprites/` 的条带写成 GPL-3.0-only 素材。不要写成项目作者的原创手绘作品。原因：这些图像由 AI 生成，版权归属在法律上不确定。

1. 本项目的自有代码使用 GPL-3.0-only。这个许可不适用于 `Resources/DogArt/` 与 `Resources/DogSprites/` 里的图像。`scripts/check_sprites.py` 是自有代码，适用 GPL-3.0-only。
2. 图像的版权归属不确定。不同司法辖区对 AI 生成图像是否有版权，以及版权属于谁，有不同的规则。
3. 图像的使用条款取决于模型服务商的条款，以及中转站的条款。项目没有取得这些条款的书面副本。
4. 项目没有给这些图像指定任何许可。需要用户确认后，才能写入许可声明。
5. 矢量比熊（`DogShapes.swift`、`DogArt.swift`、`DogRig.swift`）是手写代码和路径，属于自有代码，适用 GPL-3.0-only。

## 4. 发布前需要用户确认的事项

下表的每一项必须由用户决定。工程师和 agent 不替用户做这些决定。每一项同时适用于 8 张位图和 `Resources/DogSprites/` 的条带。

| 编号 | 事项 | 选项 |
|---|---|---|
| A1 | 是否在公开发布的二进制和仓库里包含这 8 张 AI 图像 | 包含，或者换成手绘图，或者只发布矢量比熊 |
| A2 | 图像使用什么许可声明 | 不声明，或者声明为“版权状态不确定”，或者另选许可 |
| A3 | 是否核对模型服务商与中转站的使用条款 | 核对并存档，或者放弃使用这组图像 |
| A4 | 二进制分发时，如何在应用的“关于”或源码归属文档里标注图像来源 | 写入 `Source-Attribution.md`，或者另写文件 |
| A5 | 是否保留矢量比熊作为回退 | 当前保留。位图文件缺失时，状态卡自动显示矢量比熊 |

## 5. 更换素材

1. 在 `Resources/DogArt/` 放入同名的 8 个 PNG，尺寸 320 × 240 px，透明底。
2. 更新 `PROVENANCE.md`：来源、日期、提示词或工具。
3. 运行 CI。门禁 BC 检查文件数与尺寸。门禁 BD 检查 7 个姿态在 72 × 54 pt 下两两不同。门禁 BE 检查非背景像素占比。
4. 在 Mac 上看浅色与深色下的外观。

更换动作条带：

1. 在 `Resources/DogSprites/` 放入同名条带，每帧 320 × 240 px，透明底，面朝左。
2. 更新 `manifest.json` 与 `PROVENANCE.md`。
3. 运行 `python3 scripts/check_sprites.py --sheet-dir <临时目录>`。如果有一项 FAIL，则重新生成该动作。不得放宽阈值。
4. 把联系表交给人工盲测，确认是同一只狗。

> **注意**：`.github/workflows/build-mac.yml` 的路径过滤含 `Resources/**`。只改 PNG 的提交也会触发 CI。
