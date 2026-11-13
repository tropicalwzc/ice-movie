# Design

## Context

当前媒体库已经由进行中的 `document-reader` 扩展出 `MediaEntryKind`（目录 / 视频 / Markdown / PDF）与 `LibraryContentSectioning`（网格 + 文档列表）。视频缩略图统一走 `ThumbnailService` → `DemuxProbe` 抽帧；`LibrarySource` 只暴露读取字节源；全屏播放器由 `LibraryView` 根层覆盖层承载。图片目前没有任何条目、缩略图或打开路径。

本设计要在这套结构上增加第二条“静态图片”通道，同时满足：

- 原图与全尺寸解码结果不落盘，设备只做内存边缘缓存；
- 图片与视频共用网格，文档列表保持原有分区；
- LIVP 需要从 ZIP 中取静态图，并能在不生成临时文件的情况下长按播放动态部分；
- `document-reader` 仍在进行中，`startup-latency` 也有文件重叠，设计需要按最终结构合并。

需求见 `specs/image-gallery/spec.md` 与 `specs/media-library/spec.md`，动机见 `proposal.md`。

## Goals / Non-Goals

**Goals:**

- 让 JPG/PNG/HEIC/HEIF/LIVP 进入媒体库、网格、检索与全屏相册。
- 视频与图片混合网格、媒体类型过滤、图片标题与自然排序。
- 网格缩略图、全屏渐进预览、缩放与翻页，且不把原图写入本地。
- LIVP 静态图预览与长按动态播放。
- 与文档分区、视频播放队列、诊断自动播放保持隔离。

**Non-Goals:**

- 不实现照片上传/同步、照片目录标记、删除本地照片（属于后续 `photo-sync`）。
- 不合并同名的 HEIC+MOV 两个条目；只把 `.livp` 文件当作单个 Live Photo。
- 不支持动画 GIF/APNG/WebP、RAW/DNG、图片编辑/分享/保存到照片库。
- 不改变 Markdown/PDF 阅读器行为，不改变视频解码与播放主路径。

## Decisions

### D1. 条目模型：新增 `image`，用 `ImageFormat` 区分普通图片与 LIVP

`MediaEntryKind` 增加 `image`；新增 `ImageFormat`（`jpeg` / `png` / `heic` / `livePhoto`），由 `MediaKind.imageFormat(for:)` 按扩展名识别。`MediaEntry` 增加 `isImage`、`imageFormat`、`isLivePhoto`，`MediaKind.isVisible` 把图片纳入可见条目。

- `.livp` 仍然属于 `image`，不新增 `.livePhoto` kind。过滤、排序、网格、检索都按“图片”处理，只有相册页和封面徽标关心 `isLivePhoto`。
- 新增 `ImageMetadata`：标题为去扩展名的原始文件名，保留大小与修改时间；图片 MUST NOT 调用 `MediaTitleParser`。
- `MediaOrdering` 规则：
  - 目录最前，文档最后（沿用 `document-reader`）。
  - 两个视频之间保持现有季集排序。
  - 两个图片之间按原始文件名自然排序。
  - 图片与视频混排时按展示键自然比较，图片使用原始文件名，视频使用解析后的标题。
- 不采用“图片单独分组”或“图片排在视频之后”，因为用户明确要求混合排列。

### D2. 分区与过滤：网格媒体 = 视频 + 图片，文档列表保持独立

扩展 `LibraryContentSectioning`：

- `gridItems` = 目录 + 视频 + 图片；`hasVideos`、`hasImages`、`hasGridMedia` 分别记录。
- 呈现模式改为 `.mediaGrid`（只有网格媒体）、`.mixed`（网格媒体 + 文档）、`.documentsOnly`（只有目录 + 文档）、`.empty`。
- 为减少与 `document-reader` 的合并冲突，过渡期保留 `videoGridItems` / `.videoGrid` 兼容别名，最终统一到 `gridItems` / `.mediaGrid`；对应测试同步改名。

`LibraryStore` 增加过滤状态：

```
showsVideos: Bool = true
showsImages: Bool = true

mediaFilterIsApplicable = section.hasVideos && section.hasImages
visibleGridItems =
  section.gridItems.filter {
    $0.isDirectory
      || ($0.kind == .video && showsVideos)
      || ($0.kind == .image && showsImages)
  }
```

规则：

- 过滤条只在 `!isSearching && mediaFilterIsApplicable` 时显示，位置在搜索栏下方、内容区顶部，固定在滚动区域之外。
- 单类型目录 `mediaFilterIsApplicable == false`，忽略过滤状态并隐藏过滤条，避免“进了纯视频目录却什么都没有”。
- 两个都取消时 `visibleGridItems` 只剩子目录；没有子目录且仍有文档时，文档列表继续显示，网格位置显示紧凑的筛选空状态；没有任何内容时才显示整页空状态。
- 过滤状态在当前浏览会话内保持，不写入 `AppStorage`/SwiftData；切换共享时重置为都选中。
- 过滤变化时，若当前滚动锚点仍在 `visibleGridItems` 中则保留，否则回到顶部。

不采用“按目录分别记忆过滤状态”：增加状态维度但没有明确用户收益；单类型目录忽略规则已经避免死角。

### D3. 新增 `ImageKit` 静态框架

职责：

```
ImageKit
  ├─ ImageFormat / ImageMetadata 辅助
  ├─ ImageDecoder            ImageIO 下采样、方向、色彩、PNG alpha
  ├─ LivePhotoPackage        ZIP EOCD / 中央目录 / 条目选择
  ├─ ZipEntryByteSource      stored 条目 -> 底层 ByteSource 范围映射
  ├─ RemoteImageDataProvider CGDataProvider 直接回调 + 同步桥接
  ├─ ImagePreviewLoader      压缩数据读取、解码、内存缓存、取消
  └─ LivePhotoMotionSource   AVAssetResourceLoader 的 range 供给
```

- 只依赖 `IceCore`，不依赖 `MediaLibraryKit`，避免循环依赖。
- `ThumbnailKit` 增加对 `ImageKit` 的依赖；`ThumbnailService` 通过 `ThumbnailContentKind` 选择视频抽帧或图片解码。
- App 与 `IceMovieTests` 显式依赖 `ImageKit`；`project.yml` 新增 target，`xcodegen generate`。
- ZIP deflate 需要 raw inflate：`ImageKit` 链接 `-lz`，App 侧也要显式链接（静态框架不传递链接依赖）。
- 备选：把图片代码塞进 `ThumbnailKit` 或 App target。前者会把 ZIP/AVFoundation 依赖带进缩略图模块，后者难以单测；不采用。

### D4. 缩略图：复用现有缓存与服务，图片走独立生成器

`ThumbnailService` 保留现有 `ThumbnailStore`、in-flight 去重、失败集合与 LRU；新增 `contentKind`：

- `.video` → 现有 `DemuxProbe.thumbnail(source:)`。
- `.image` → `ImageDecoder.thumbnail`。
- `.livePhoto` → `LivePhotoPackage` 取静态图条目 → `ImageDecoder.thumbnail`。

约束：

- 缩略图最大宽度降为 384；输出 PNG；缓存键是 `namespace|path|size|modified`，并把缩略图版本（`thumb384p`）并入命名空间，旧 480px 文件不会再命中；图片与视频共用 **64 MB** 硬上限与 LRU 淘汰策略；`-thumbnailCacheLimitMB` 等启动参数也收敛到该上限以内。
- JPEG 走前缀快速路径：先读前 512KB，自己解析 APP1/EXIF 的 JPEGInterchangeFormat，只解那张**完整的内嵌缩略图**；没有内嵌图才回退整图。不能把部分 JPEG 直接交给 ImageIO——它会返回尺寸正确、但只解码顶部扫描线的图，在瀑布流里表现为只剩一条边。真机日志显示旧路径平均每个封面要读 2.8MB（最大 9.9MB），这是网格滑动的主要瓶颈。
- 网格读取使用 `ThumbnailByteSourceProvider.openThumbnailByteSource` 的 `.thumbnail` 优先级（256 KB × 8 环），不触碰播放的 512 MB 环。
- 图片失败键与视频共用失败集合；同一会话内不重复请求。
- `LibraryStore.thumbnail(for:)` 从只允许 `.video` 扩展为 `.video` 或 `.image`；`cachedThumbnail` 同步。
- 不为图片新建第二套磁盘缓存，避免两个 LRU 争同一目录。

### D5. 远程图片读取：网格尽量按 range 读，相册整图进内存后下采样

分两条路径：

**网格缩略图**

- 首选 `RemoteImageDataProvider`：用 `CGDataProvider` 直接回调把 `ByteSource` 包装成可随机访问的数据源，ImageIO 只取它需要的 range。
- 读取回调维持 256 KB–1 MB 的预读窗口，并复用 `AVIOBridge` 的“异步源 + 同步等待”模式；回调运行在图片解码线程，不占主线程。
- 使用 `kCGImageSourceCreateThumbnailFromImageIfAbsent`、`kCGImageSourceCreateThumbnailWithTransform`、`kCGImageSourceThumbnailMaxPixelSize`。
- 检查返回缩略图宽度；若明显小于目标（例如内嵌缩略图只有 160–320 px），回退到 `kCGImageSourceCreateThumbnailFromImageAlways` 或整文件读取，保证网格清晰度。
- 如果实测 ImageIO 仍然顺序拉完整文件，或 provider 在某些 HEIC 上不稳定，回退到“整文件读取 + 下采样”；读取仍走 `.thumbnail` 优先级并限制并发 2–3。
- **验证结果**：用带 2MB 填充的 JPEG fixture 实测，ImageIO 通过直连 provider 一次请求了整张文件（`requests=1`，读取量等于文件长度），没有字节级 range 收益。因此 v1 的网格缩略图实际走“整张压缩图读取 + 下采样”兜底，`RemoteImageDataProvider` 保留为未来格式/前缀优化的入口，并限制单次读取峰值 8MB。

**相册大图**

- 立即显示网格中已有的缩略图，避免空白等待。
- 当前页读取完整压缩图（普通 iPhone 照片约 2–6 MB）到内存，解码到屏幕尺寸（上限约 2048–2732 px），保留压缩 Data 供放大时重新解码。
- 放大时用同一份压缩 Data 解码到约 2× 屏幕尺寸；不重新读 SMB。翻页后释放上一页的压缩 Data 与解码图。
- 相邻页只预取缩略图，不预取整图；当前页稳定 300 ms 后才考虑预取下一张，快速滑动时取消。
- 压缩图上限 64 MB；超过时使用 lazy provider 或提示过大，禁止全尺寸解码。任何情况下都不把原图或全尺寸解码结果写盘。
- 相册读取走 `LibrarySource.openImageByteSource`，默认复用字幕优先级（用户可见、高于枚举/缩略图），使用 24 MB 级环；不使用 `.playback` 的 512 MB 环。进入相册时停止内联视频，避免读带宽争用。

不采用“所有缩略图都整文件下载”：一张 5 MB、500 张就是 GB 级传输，不符合“本地 CDN”按需读取的目标。也不采用服务端缩略图，共享端没有生成能力。

### D6. LIVP：ZIP 解析 + 静态图按需读取 + 动态 range 供给

`LivePhotoPackage` 解析：

- 读取文件尾部最多 128 KB 定位 EOCD，兼容 ZIP comment；再读中央目录。
- 静态条目优先 `.heic/.heif/.jpg/.jpeg`，多个候选取解压后尺寸最大的；动态条目取 `.mov/.mp4`。
- 支持 stored（method 0）与 deflate（method 8，raw inflate）；不支持 ZIP64、加密和分卷，遇到时返回明确错误。
- 安全上限：条目数、单条解压后大小（如 256 MB）、总解压大小；不写本地文件。

读取策略：

- 静态条目 stored：`ZipEntryByteSource` 把条目内偏移映射到 LIVP 文件的 SMB range，直接喂给 `RemoteImageDataProvider`，ImageIO 只读内部缩略图需要的范围。
- 静态条目 deflate：解压到内存（受上限约束）后用 `Data` 解码。
- 动态条目 stored：`ZipEntryByteSource` 喂给 `AVAssetResourceLoader`，按需读取 `moov` 与样本；deflate 则解压到内存后从 `Data` 供给。
- 缺少静态图：显示占位/错误；不在 v1 做“动态首帧兜底”，避免把 MOV 解码引入封面路径。

### D7. 相册：根层全屏覆盖 + 横向分页 + UIScrollView 缩放

- 在 `LibraryView` 根 `ZStack` 增加 `ImageGallerySession?` 状态，覆盖整个窗口；不使用 `fullScreenCover`，避免 iPhone 方向控制与系统弹层视图控制器只报竖屏的问题。iPad 同样全屏，不内联。
- 分页集合：当前目录 `currentEntries` 中 `kind == .image` 的条目，按 `MediaOrdering` 顺序；视频与文档不进入。搜索命中图片时，若目录未加载则先加载目录，再以该图片为初始页打开。
- 分页容器：`ScrollView(.horizontal)` + `LazyHStack` + `.scrollTargetBehavior(.paging)` + `.scrollPosition(id:)`。相比 `TabView(.page)`，便于取消、预取和程序化定位。
- 每个页面用 `ZoomableImageView`（`UIViewRepresentable` 包装 `UIScrollView`）实现双指缩放、双击缩放、放大后拖动。缩放手势与分页冲突时，放大状态下关闭外层翻页，只允许平移；切换页面重置缩放。
- 页面 chrome：关闭、页码、标题、LIVP 的 `LIVE` 标识、加载/错误状态；点击画面切换 chrome 显隐。加载超过 300 ms 才显示进度，避免闪烁。
- 方向：iPhone 打开时请求 `.allButUpsideDown`，关闭恢复 `.portrait`；iPad 跟随系统。旋转时保留当前页与缩放状态。
- 打开相册时调用现有 `closePlayback()` 停止内联视频并保存进度；关闭相册恢复网格滚动位置，不重建导航栈。
- 备选：iPad 右栏内联（用户已选全屏）、`TabView(.page)`（控制力弱）、`fullScreenCover`（方向问题）均不采用。

### D8. LIVP 动态：自定义 `AVAssetResourceLoader` + `AVPlayer`，不落临时文件

- 每个当前页创建一个短生命周期 `LivePhotoMotionController`，持有 `AVURLAsset`（自定义 scheme）、`AVPlayerItem`、`AVPlayer` 与 resource loader delegate。
- delegate 处理 `contentInformationRequest`（长度、`UTType.quickTimeMovie`）与 `dataRequest`；从 `ZipEntryByteSource` 或内存 `Data` 按 256 KB 分块 `respond`，检查取消，失败时 `finishLoading(with:)`。
- 页面打开只解析 ZIP 中央目录与静态图，不读取 MOV；长按开始时才读取动态数据、创建 asset 并从 0 播放，松开暂停并回到静态图；播放结束停在末帧或回到静态图，不循环。离开当前页时丢弃缓存的动态数据，避免整段 MOV 长期驻留内存。
- 翻页、关闭、缩放开始、内存警告时停止并释放播放器与请求。
- 音频复用现有播放音频会话；进入相册已停止内联视频，不会与主播放器抢音频。
- 手势用 `UILongPressGestureRecognizer`（约 0.25–0.3 s、允许小幅移动），放大状态下禁用；开始播放时给轻触觉反馈。
- 动态失败只禁用长按并显示非阻塞提示，静态图继续可看；没有 MOV 条目的 `.livp` 不显示 `LIVE` 或长按入口。
- 备选：
  - `PHLivePhotoView`：需要本地文件 URL，为它写临时文件违反“不落盘”，不采用。
  - 现有 `PlaybackEngine`：面向长片，音频/视频预滚与状态较重，且与主播放器隔离成本高；短 Live Photo 用 `AVPlayer` 更合适。
  - 解压 MOV 到临时文件：违反存储约束，不采用。

### D9. 搜索与播放隔离

- `LibrarySearchIndex` 对图片使用 `ImageMetadata`（原始文件名，不解析季集），文档继续用 `DocumentMetadata`，视频继续用 `MediaTitleParser`。
- 搜索结果：
  - 图片命中：直接打开相册并定位；目录未加载时先异步加载，行上显示加载态。
  - 视频命中：保持 `reveal` 定位；若 `mediaFilterIsApplicable` 且视频被过滤，先自动启用 `showsVideos`。
  - 文档命中：保持直接打开阅读器。
- 搜索结果不受目录过滤影响，搜索时过滤条隐藏。
- `PlaybackQueue.next` 已只返回 `.video`；补充测试覆盖“视频 → 图片 → 视频”和“图片作为当前条目”。
- `LibraryStore.activate`：图片走相册回调，文档忽略播放入口，视频走播放；`preparePlayback`/`play` 增加 `.video` 守卫。
- 诊断自动播放、`-libraryOpenFirst`、压力测试选择器只选 `.video`；图片缩略图不调用 `DemuxProbe`。
- 播放进度、Now Playing、画中画逻辑不感知图片。

### D10. 格式与解码细节

- JPEG/PNG/HEIC/HEIF 全部走 ImageIO；不使用 FFmpeg 图片解码，也不改 FFmpeg 构建。
- 方向通过 `kCGImageSourceCreateThumbnailWithTransform`；色彩空间保留源 CGImage 的色彩空间，SwiftUI 负责显示。
- PNG 保留 alpha；单元格使用中性底色，避免透明区域变黑。
- `ImageFormat` 先按扩展名识别；解码失败再按损坏/不支持处理。可选读取 magic bytes 做更准确诊断。
- `.livp` 只支持文件形态；目录形态按普通目录导航（用户可进入看到内部 HEIC/MOV）。
- 动画 GIF/APNG/WebP、RAW/DNG 不在本期；即使 ImageIO 能解，也不进入图片条目。

### D11. 失败、取消与诊断

- 图片缩略图失败：写入现有失败集合，单元格显示“无预览”，同一会话不重试。
- 相册页失败：显示错误与重试；翻页仍可继续；SMB 断线后重试重新读取当前图片。
- 所有图片任务绑定页面/单元格生命周期，翻页与关闭时取消；用 generation 防止旧任务回写。
- 日志增加图片相关类别或复用 `.thumbnail`：记录读取字节、解码耗时、缓存命中、内嵌缩略图/整图回退、LIVP 静态/动态、AVPlayer 起播耗时。
- 清空缓存只清缩略图，不产生也不删除原图；预览图只存在内存。

### D12. 网格图片改为瀑布流、按自然比例显示

- 图片单元格高度按缩略图宽高比（宽/高）计算，用多条 `LazyVStack` 按顺序交替分列形成瀑布流；图片 `scaledToFit` 完整显示、不裁切，同时把单元格黑边降到最低。
- 视频与目录保持 2:3 封面；图片缩略图加载后回填比例，并持久化到 `Caches/ThumbnailAspects.json`，下次进入目录不再跳动。
- 宽高比限制在 0.4–2.5，避免超长图造成极端单元格；比例未知时先用 2:3，缩略图到达后更新。
- 停止滚动 350ms 后对当前列的后续条目预取封面，全局最多 12 个预取任务；滑动开始立即取消。预取走与可见单元格相同的下载/后台解码路径，完成后直接进入 NSCache，滚到该条目时无需再等网络。
- 缩略图生成逻辑升级时版本号进入缓存命名空间；当前为 `thumb384p3`。首次启动若版本变化会清空旧缩略图，避免历史半截图继续被命中；宽高比缓存使用 `a3` 命名空间一起失效。
- EXIF 缩略图仍需通过尺寸（宽高均 ≥48）和宽高比（0.2–5）校验；校验失败或没有内嵌缩略图时回退整图解码。
- 单元格请求被取消（滑出屏幕、预取取消）不等于图片损坏：不写永久失败标记，再次可见时重试一次；只有两次都失败才显示“无预览”。
- 备选：`scaledToFill` 裁切（不采用，保留“完整显示照片”的约定）；固定 2:3 居中（黑边过多，用户已明确否掉）。

### D13. 旋转与保存：屏幕预览、原图编码、SMB 覆盖、系统相册

- 相册为 JPG/PNG/HEIC/HEIF 提供顺时针 90° 旋转按钮；屏幕预览只旋转当前解码图，缓存每个角度，切换页面保留未保存角度；LIVP 不提供可用入口。
- 保存时用 `ImageEncoder.rotatedImageData` 重新从**原始压缩数据**按原像素尺寸解码（上限 8192）、旋转、按原格式/质量编码，并尽量保留原元数据、把 EXIF 方向写成 1；绝不拿屏幕尺寸预览覆盖原图。
- SMB 覆盖协议：写唯一临时文件 → 校验大小 → 原文件移到备份 → 临时文件改名到目标 → 删除备份；任一步失败恢复原文件，失败时不删除唯一备份。共享只读或校验失败会显示原因。覆盖与读取一致：瞬时断线等可恢复错误会先重连再重试一次。
- 保存菜单常驻，不要求先旋转：未旋转时“保存到系统相册”直接写原始压缩数据，避免无意义重编码；旋转后才在菜单中出现“覆盖原照片”。
- 系统相册保存使用 PhotoKit `.addOnly` 权限，把当前完整数据作为新资产加入照片库，不修改 SMB 原图；`Info.plist` 增加 `NSPhotoLibraryAddUsageDescription`。
- 保存成功后重新读取该目录，更新网格的大小/修改时间并生成新缓存键；旧缩略图缓存留给 LRU 淘汰。
- 备选：只改 EXIF Orientation、不重编码（质量无损，但 JPEG/HEIC 元数据写回复杂，且部分查看器不认）；`UIImageWriteToSavedPhotosAlbum`（无法控制 UTI/文件名）；直接原地覆盖（失败会留下半截文件）；均不采用。

### D14. 拍摄时间排序与照片日历

- `PhotoTimestampParser` 只识别扩展名前最后一个下划线后的 14 位 ASCII 数字（`_yyyyMMddHHmmss`），并校验月/日/时分秒范围；扩展名缺失或数字非法时不产生时间戳，不影响条目显示。
- `MediaEntry.captureTimestamp` 在条目创建时解析一次；网格图片副标题优先显示 `captureTimestamp.displayDay`，没有时间戳时才回退到文件修改时间，避免整批同步照片都显示同一天。
- `MediaOrdering` 对视频和图片统一比较拍摄时间，带时间戳的按时间倒序（最新在前），无时间戳的排在带时间戳的后面，目录仍最前、文档仍最后。标题相同时使用每条目独立计算的平局键（季、集、文件名、路径），非视频使用固定哨兵值，避免同标题图片/视频混排出现比较环。
- `PhotoCalendarIndex` 从当前目录图片构建，按 `PhotoDay`（年/月/日）统计数量并记录当天排序最靠前（即最新）的图片；`LibraryStore.photoCalendar` 在目录加载、缓存命中、目录刷新和切换目录时重建。
- 过滤条最右侧显示日历按钮，仅当当前目录存在带时间戳的图片时出现；单类型照片目录只显示“按拍摄日期”说明和日历按钮。日历用 popover 呈现，锚点在按钮下方，避免顶部过滤条把内容挤到屏幕外。
- 选择日期后写入 `pendingScrollTarget`，并自动恢复图片过滤；`LibraryGridView` 消费该目标滚动到对应条目后清除，保证照片可见。月份单元格用于展开该月日期；月份下方另提供“查看整月”按钮，跳到该月最新一天的最新照片，避免只能精确到日。
- 日历日期网格的空白占位与日期按钮使用同一组连续索引 ID，避免 `LazyVGrid` 把相同 `Int` ID 的单元格合并导致月初日期丢失。

### D15. 磁盘缓存总预算

- 真机排查发现容器头缓存曾按 512 MB 上限运行、缩略图 100 MB、字幕 50 MB，叠加日志与系统快照后 App 数据超过 800 MB。
- 新预算：容器头缓存 48 MB（单文件 24 MB）、缩略图 64 MB、内封字幕 16 MB；三类合计 128 MB，加上日志轮转（单文件 4 MB、保留一份轮转）与系统快照，目标控制在 200 MB 以内，硬上限 500 MB。
- 容器头缓存启动时按新预算裁剪并删除索引外的孤儿 `.bin`；稀疏文件的逻辑大小不计入预算，实际占用按已写页统计。
- 日志文件满 4 MB 轮转为 `.1`，启动维护会删除超限的旧调试日志与过期文档自检报告。
- 诊断页新增「缓存占用」，按实际分配块统计各模块；`-cacheReport` 启动参数输出同一份报告，便于真机直接核对。

## Risks / Trade-offs

- **ImageIO 按需读取行为不确定** → 先做真样本 spike，记录实际读取字节；若 lazy provider 没有收益或不稳定，回退整文件读取 + 低并发，行为规格不变。
- **HEIC 内嵌缩略图可能偏小** → 检查返回尺寸，低于阈值时回退解码主图；代价是更多 CPU/带宽，但保证网格清晰。
- **LIVP ZIP 变体（ZIP64、deflate、异常目录）** → 支持常见的 stored/deflate，其他明确失败；用真实样本与构造 fixture 验证；设置解压上限避免内存爆掉。
- **AVPlayer 自定义 resource loader 可能写缓存或拒绝自定义 scheme** → 验证运行前后容器 `tmp`/`Caches`；若不可控，退回“内存 Data + 自定义 loader”，最后才考虑静态-only 降级。
- **缩放手势与横向分页冲突** → `UIScrollView` 包装 + 放大时关闭翻页；用 UI 冒烟测试覆盖。
- **48MP/大 PNG 内存峰值** → 只解码屏幕尺寸，压缩数据上限 64 MB，放大按 2× 屏幕重解；内存警告释放非当前页。
- **document-reader 合并冲突** → 先落地其条目/分区结构，再按 `gridItems`/`hasGridMedia` 扩展；过渡期保留兼容别名，更新其测试。
- **startup-latency 合并冲突** → 本 change 不改播放准备路径；只增加 `.video` 守卫与相册入口，合并时以播放回归为准。
- **SMB 带宽争用** → 网格缩略图低优先级、并发 2–3；相册整图用字幕级优先级；进入相册停止内联视频；快速翻页取消旧请求。
- **搜索图片直接打开需要异步加载目录** → 行级加载态与失败提示；目录已缓存时立即打开。
- **分离的 HEIC+MOV 不合并** → 用户会看到一张图片和一个视频；本期明确不支持，留给 `photo-sync` 的配对设计。
- **过滤状态跨目录保持** → 单类型目录忽略过滤器、过滤条显示当前状态，降低“内容被隐藏”的困惑。
- **原图分辨率保存的内存峰值** → 保存时才解码原图，限制 8192 像素；常规 12MP 约 50MB、48MP 会触发上限降采样；编码完成立即释放。
- **HEIC/JPEG 重编码质量损失** → 使用 0.95 质量并保留元数据；无法无损写回 EXIF 方向时接受一次重编码，文档说明。
- **SMB 覆盖写不是真正的原子操作** → 临时文件+大小校验+备份+改名；失败恢复备份，绝不删除唯一副本；真实共享用临时探针先验证写权限。
- **照片库权限被拒绝** → 使用 add-only 权限，失败时给出设置提示；不把 SMB 保存和照片库保存捆绑，任一失败不影响另一个文件。
- **LIVP 重写复杂** → 本期旋转/覆盖保存只支持静态图片，LIVP 保持只读；避免破坏 ZIP 内静态图与 MOV 的配对。

## Migration Plan

- 无数据迁移：不新增 SwiftData 模型、不改缓存键、不改视频播放数据。图片只增加条目类型与新模块；`Info.plist` 新增照片库 add-only 权限说明，首次保存到系统相册时由系统弹窗授权。
- 实施顺序：
  1. 等 `document-reader` 的条目模型与分区结构稳定（至少 1.x/2.x 完成），合并其 `MediaEntryKind` / `LibraryContentSectioning` / `GridView` 改动。
  2. 增加 `ImageKit` target 与 `project.yml` 依赖，`xcodegen generate`。
  3. 条目识别、排序、分区、过滤条、图片缩略图。
  4. 全屏相册、分页、缩放、渐进加载。
  5. LIVP 静态解析，再接长按动态。
  6. 搜索、播放隔离、README、全量回归与真机验收。
- 归档顺序：建议 `document-reader` 先归档，再归档 `image-gallery`，避免 `media-library` 的文档分区与 Purpose 被旧文本覆盖；若顺序相反，需要手工合并两份 delta。
- 回滚：撤销本 change 即可，图片重新隐藏，视频/文档/播放路径不受影响；无持久化数据需要清理。
- 真机验收：`tropical-advpc.lan` 的 `Photos` 目录，覆盖 JPG/PNG/HEIC/HEIF/LIVP、混合目录、过滤、iPad 全屏、iPhone 旋转、长按动态与损坏文件。

## Open Questions

- ImageIO 在直接回调 provider 下实际读取多少字节，HEIC 内嵌缩略图是否稳定 ≥384 px？已用 JPEG/HEIC fixture 验证：JPEG 会请求整张文件；HEIC 解码正常。v1 采用整文件读取兜底，range provider 仅作为后续格式级优化入口。
- `AVPlayer` + 自定义 `AVAssetResourceLoader` 播放 ZIP 内 MOV 时是否产生本地临时缓存？需要用真实 LIVP 验证容器 `tmp`/`Caches` 变化；若产生，改为内存 Data 供给。
- 常见 LIVP 的静态图/动态图条目是 stored 还是 deflate？这影响 ZIP 解压路径的性能，但不改变本期“两种都支持、失败可降级”的方案。
