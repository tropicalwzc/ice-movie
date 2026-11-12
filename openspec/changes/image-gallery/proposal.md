# Proposal

## Why

SMB 共享里已经有 iPhone 照片目录（例如 `tropical-advpc.lan` 的 `Photos`），但媒体库目前只识别视频和文档，JPG/PNG/HEIC/LIVP 在目录列举阶段就被丢弃。用户无法在原地浏览照片，也无法把手机照片与视频放在同一个目录里查看；而 iPhone 本地存储有限，照片应继续留在 SMB、按需读取，不能为预览在本地复制一份原图。

## What Changes

- **图片进入媒体库**：`MediaEntryKind` 增加 `image`，`MediaKind` 识别 `.jpg/.jpeg/.png/.heic/.heif/.livp`；图片与视频、文档一样参与目录列举和检索，其他非媒体文件继续隐藏。
- **混合网格**：视频与图片在同一个 2:3 网格中按自然顺序混排；视频封面填满单元格，图片完整居中显示在深色底色上，不显示明显白色边框；图片不使用发布名/季集解析，占位尺寸稳定，不因解码导致布局跳动。
- **媒体类型过滤**：当前目录同时存在视频和图片时，在搜索栏下方显示“视频/图片”两个独立过滤按钮，默认都选中；只作用于目录网格，进入搜索时隐藏。单类型目录忽略过滤器；两个都取消时只显示子目录。
- **全屏相册**：点击图片进入全屏相册，只翻图片、跳过视频；支持左右滑、双指缩放、双击缩放与拖动。iPhone 与 iPad 都走全屏覆盖层，iPad 不内联；关闭后回到网格原位置。进入相册时停止内联视频播放。
- **旋转与保存**：相册提供顺时针 90° 旋转按钮，修正方向错误的照片；保存入口常驻，未旋转时可直接把原图保存到系统照片库，旋转后可按原图分辨率重新编码并覆盖 SMB 原文件（先确认、临时文件+校验+替换），也可保存旋转后的完整图片到系统照片库（仅添加权限）。LIVP 本期不提供旋转覆盖，但可保存其中的静态图到系统相册。
- **LIVP 静态与动态**：`.livp` 按 ZIP 解包，只读取静态图条目生成封面与大图；长按可播放包内 MOV 动态部分，松开暂停。静态图与动态播放都不在本地保存原文件，ZIP 损坏或缺少静态图时降级为占位或错误态。
- **拍摄时间倒序**：文件名末尾带 `_yyyyMMddHHmmss` 时解析为拍摄时间，最新照片排在最前；无拍摄时间的媒体排在带时间戳的媒体之后，文档仍保持最后。
- **照片日历检索**：过滤条最右侧提供日历入口，按年/月/日列出有照片的日期与数量；选择某一天后滚动到当天最新的一张照片。单类型照片目录也会显示该入口。
- **渐进加载与内存约束**：网格先显示缩略图，点开后立即放大已有缩略图，再按需读取并解码到屏幕尺寸；放大时用内存中的压缩数据重新解码更高分辨率。原图与全尺寸解码结果不落盘，预览图只占内存，图片与视频缩略图共用 64 MB 磁盘硬上限。
- **搜索与播放隔离**：图片进入搜索索引，命中图片可直接打开相册；视频命中保持定位到目录，若该类型被过滤器隐藏则自动启用。视频连播、缩略图抽帧和诊断自动播放只处理视频，图片不得进入播放队列。
- **兼容文档分区**：在 `document-reader` 的“网格 + 文档列表”结构上扩展，网格部分从“视频 + 目录”变为“视频 + 图片 + 目录”，文档列表与纯文档模式保持原有行为。

**BREAKING**（行为契约）：`media-library` 原先规定“非媒体文件默认不出现在网格中”且网格只承载视频与目录；现在图片会进入网格，文档继续以列表形式出现，检索范围也扩大到图片与文档。

## Capabilities

### New Capabilities

- `image-gallery`: 定义图片格式识别、缩略图、混合网格中的图片呈现、全屏相册的滑动/缩放、LIVP 静态图与长按动态播放、渐进加载与无本地落盘约束。

### Modified Capabilities

- `media-library`: 条目识别从“视频 + 文档 + 目录”扩展为“视频 + 图片 + 文档 + 目录”；新增视频/图片过滤条与对应空状态；网格分区、排序、检索命中与视频连播隔离需要覆盖图片。

## Impact

- 条目模型与排序：`IceMovie/Feature/LibraryKit/MediaEntry.swift`、`MediaKind`、`LibraryLoader.swift`、`MediaTitle.swift`、`LibraryContentSectioning.swift`、`LibrarySearchIndex.swift`、`PlaybackQueue.swift`。
- 媒体库界面与状态：`IceMovie/Feature/Library/LibraryStore.swift`、`LibraryGridView.swift`、`LibraryCell.swift`、`LibrarySearchResultsView.swift`、`LibraryView.swift`、`LibrarySidebar.swift`。
- 图片解码与缩略图：`IceMovie/Core/ThumbnailKit/ThumbnailKit.swift`；新增 `IceMovie/Core/ImageKit/`（ImageIO 解码/旋转编码、LIVP ZIP 解析、`ZipEntryByteSource`、图片预览加载器）；`project.yml` 增加对应 target 与测试依赖。
- 写入与系统相册：`SMBClient` 增加临时文件+校验+替换的覆盖写；`LibrarySource` 增加 `overwriteImage`；新增照片库 add-only 保存；`Info.plist` 增加 `NSPhotoLibraryAddUsageDescription`。
- 相册界面：新增 `IceMovie/Feature/Gallery/`（相册模型、分页、缩放、LIVP 动态控制器）。
- 测试：`IceMovieTests` 需补充图片类型、排序、分区、过滤、搜索、LIVP ZIP、缩略图与 `PlaybackQueue` 隔离用例；`IceMovieUITests` 增加混合目录过滤与相册冒烟用例。
- 依赖与并行：本 change 建立在进行中的 `document-reader` 条目/分区结构之上，涉及同一批 `MediaEntry`、`LibraryContentSectioning`、`LibraryGridView`、`LibraryStore` 文件；与 `startup-latency` 也存在 `LibraryView.swift`、`LibraryStore.swift` 重叠，实施时需按最终结构合并。
- 真机验收目标：`tropical-advpc.lan` 的 `Photos` 目录，覆盖 JPG/PNG/HEIC/HEIF/LIVP、混合目录、过滤、iPad 全屏与长按动态。
- **Out of scope**：向 SMB 上传/同步系统照片、照片目录标记、删除本地照片、动画 GIF/APNG/WebP、RAW/DNG、同名 HEIC+MOV 的 Live Photo 配对、目录形态的 `.livp` 包、LIVP 内部的旋转/重写、裁剪/调色等完整图片编辑、批量旋转。
