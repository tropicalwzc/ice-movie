# Tasks

## 1. 前置与 ImageKit 骨架

- [x] 1.1 确认 `document-reader` 的条目模型与分区结构已落地（`MediaEntryKind` 含文档、`LibraryContentSectioning` 测试通过）；若尚未完成，先合并其 1.x/2.x 产物，不在本 change 重复实现。验证：现有 `MediaKindTests`、`LibraryContentSectioningTests`、`LibraryOrderingTests` 全量通过。
- [x] 1.2 在 `project.yml` 增加 `ImageKit` 静态框架 target（依赖 `IceCore`），并让 `ThumbnailKit`、`IceMovie`、`IceMovieTests` 显式依赖它。验证：`xcodegen generate` 成功，空 target 可构建。
- [x] 1.3 建立 `IceMovie/Core/ImageKit/` 目录与最小公开接口，配置 ImageIO、CoreGraphics、UniformTypeIdentifiers、AVFoundation 与 `-lz` 链接。验证：`xcodebuild ... build` 在模拟器通过，App 能找到 `ImageKit` 模块。
- [x] 1.4 准备测试图片样本：小尺寸 JPEG、PNG（含 alpha）、HEIC/HEIF、stored 与 deflate 两种 LIVP、损坏 ZIP、缺少静态图的 LIVP；必要时增加生成脚本并纳入测试资源。验证：单元测试 target 能读取全部 fixture，`sips`/`file` 确认格式正确。
- [x] 1.5 在 README 增加“图片格式与测试样本”小节，说明支持范围与 fixture 位置。验证：按文档能找到并复现样本；构建产物包含测试资源。

## 2. 条目模型、标题与排序

- [x] 2.1 给 `MediaEntryKind` 增加 `image`，新增 `ImageFormat`（jpeg/png/heic/livePhoto）与 `MediaEntry.imageFormat`、`isImage`、`isLivePhoto`；扩展 `MediaKind.imageFormat`、`imageExtensions`、`isVisible`。验证：`MediaKindTests` 覆盖全部图片扩展名、大写、`.livp` 与不支持格式。
- [x] 2.2 新增 `ImageMetadata`：标题为去扩展名原始文件名，保留大小与修改时间，不调用 `MediaTitleParser`。验证：新增 `ImageMetadataTests`，覆盖 `IMG_1234.HEIC`、中文名、带数字名，断言不产生季集号。
- [x] 2.3 扩展 `MediaOrdering`：目录最前、文档最后；视频之间保持季集排序；带 `_yyyyMMddHHmmss` 的媒体按拍摄时间倒序，无时间戳的排在后面；其余图片按原始文件名自然排序；图片与视频混排按展示键比较。验证：`LibraryOrderingTests` 覆盖图片/视频混排、第 2 张在第 10 张之前、文档仍在媒体之后。
- [x] 2.4 更新 `LibraryEntryBuilder` 与可见性过滤，让图片进入 `entriesByPath`，其他非媒体文件继续隐藏。验证：`LibraryOrderingTests` 断言图片可见、`.torrent/.ass/.txt` 不可见、子目录始终保留。
- [x] 2.5 扩展 `LibraryContentSectioning`：新增 `gridItems`、`hasVideos`、`hasImages`、`hasGridMedia`，呈现模式改为 `.mediaGrid` / `.mixed` / `.documentsOnly` / `.empty`；过渡期保留 `videoGridItems` / `.videoGrid` 兼容别名。验证：`LibraryContentSectioningTests` 增加“只有图片”“图片+文档”“视频+图片+文档”“纯文档不变”四组断言。
- [x] 2.6 更新 `LibraryStore.displayTitle` 与 `subtitle`：图片使用 `ImageMetadata` 标题，副标题显示大小与修改日期；文档与视频保持原行为。验证：单元测试或本地 fixture 断言图片标题不出现“第 N 集”，副标题包含大小与日期。
- [x] 2.7 更新 `LibrarySearchIndex` 的标题来源：图片使用 `ImageMetadata`，文档使用 `DocumentMetadata`，视频使用 `MediaTitleParser`。验证：`LibrarySearchIndexTests` 覆盖 `IMG_1234`、`swift.md`、视频同目录命中与排序。
- [x] 2.8 更新 README 的媒体库条目说明：视频、图片、文档、目录四类条目及标题/排序规则。验证：文档描述与 fixtures 实际行为一致。

## 3. 过滤条、网格与空状态

- [x] 3.1 在 `LibraryStore` 增加 `showsVideos`、`showsImages`、`mediaFilterIsApplicable`、`visibleGridItems`、`resetMediaFilter()`；单类型目录忽略过滤，切换共享时重置。验证：新增 `LibraryMediaFilterTests` 覆盖默认、取消视频、取消图片、两个都取消、单类型目录忽略、共享切换重置。
- [x] 3.2 新增 `LibraryMediaFilterBar`：两个独立勾选胶囊（视频/图片），带选中态、VoiceOver `isSelected`、动态字体与横竖屏适配；放在 `LibraryContentPage` 搜索栏下方、滚动区域之外，仅 `!isSearching && mediaFilterIsApplicable` 时显示。验证：本地混合 fixture 在 iPhone/iPad 都能看到并切换过滤条。
- [x] 3.3 改造 `LibraryGridView` 使用 `visibleGridItems`，文档列表继续使用未过滤的 `documentItems`；过滤后网格为空但仍有文档/子目录时保留内容，只有完全没有可见内容时才显示筛选空状态与“显示全部”。验证：新增 UI 用例覆盖四种组合。
- [x] 3.4 改造 `LibraryPoster`/`LibraryCell`：图片用 `scaledToFit` + 中性底色留白，视频保持填满；图片使用 `photo.slash` 失败占位；LIVP 预留 `LIVE` 徽标位置；`preparingOverlay` 只对视频生效；无障碍提示区分“打开图片”和“开始播放”。验证：本地 fixture 的横图/竖图不裁切，网格行高不变。
- [x] 3.5 处理过滤切换后的滚动锚点：当前锚点仍在 `visibleGridItems` 时保留，否则回到顶部；过滤条出现/消失不导致内容跳位。验证：在长目录中过滤/恢复，滚动位置符合预期。
- [x] 3.6 更新空状态文案：无内容时说明“没有视频、图片、文档或子目录”；筛选空状态说明当前隐藏了哪些媒体；文档列表存在时不覆盖整页。验证：空目录、纯文档、图片+文档、混合目录四种 fixture 文案正确。
- [x] 3.7 在 README 增加“混合网格与媒体过滤”小节：默认状态、单类型目录、两个都取消、搜索时隐藏、切换共享重置。验证：按文档描述逐项操作，行为一致。

## 4. 图片缩略图与远程读取

- [x] 4.1 在 `ImageKit` 实现 `ImageDecoder`：用 `CGImageSource` 下采样、应用 EXIF 方向、保留色彩空间与 PNG alpha，输出 PNG Data；禁止解码全尺寸原图。验证：`ImageKitTests` 覆盖 JPEG/PNG/HEIC/HEIF、横竖方向、透明 PNG，断言输出尺寸不超过目标。
- [x] 4.2 实现 `RemoteImageDataProvider`：用 `CGDataProvider` 直接回调包装 `ByteSource`，带 256KB–1MB 预读窗口、同步桥接与单次 8MB 峰值限制；用 fake `ByteSource` 记录请求的 offset/length。验证：记录 ImageIO 在 JPEG/HEIC 上的实际读取行为；已确认 ImageIO 会请求整张文件，因此网格缩略图走整文件读取 + 下采样兜底，provider 保留为后续格式级优化入口。
- [x] 4.3 扩展 `ThumbnailService` 支持 `ThumbnailContentKind`（video/image/livePhoto）：视频仍走 `DemuxProbe`，图片走 `ImageDecoder`，LIVP 走静态图提取；复用现有缓存键、in-flight 与失败集合。验证：`ThumbnailCacheTests` 增加图片失败不重试、图片缓存命中、视频路径不变的用例。
- [x] 4.4 更新 `LibraryStore.thumbnail`/`cachedThumbnail` 允许图片；图片封面使用 `.thumbnail` 优先级与低并发。验证：stub `LibrarySource` 断言图片请求不调用视频解封装，滚动 500 张 fixture 时主线程无长阻塞。
- [x] 4.5 增加缩略图回退策略：内嵌缩略图明显小于目标时回退解码主图；lazy provider 在某些 HEIC 上不稳定或仍顺序拉完整文件时，回退整文件读取 + 下采样。验证：用内嵌缩略图偏小的 HEIC 与普通 JPEG 各测一组，网格清晰且读取量有记录。
- [x] 4.6 增加图片缩略图诊断日志：读取字节、解码耗时、缓存命中、来源（内嵌/整图）、失败原因；复用现有 `.thumbnail` 或新增图片类别。验证：滚动 fixture 后日志能区分缓存命中、range 读取与整图回退。
- [x] 4.7 在 README 增加“图片缩略图与不落盘”小节：64 MB 缓存上限、下采样、失败占位、原图不落盘。验证：文档描述与“清空缓存”行为一致。

## 5. 全屏相册

- [x] 5.1 新增 `ImageGallerySession` 与 `ImageGalleryModel`：从当前目录取图片集合、自然排序、初始索引、当前页、加载/错误状态、翻页与关闭；单元测试覆盖空集合、单张、多张、首尾边界。
- [x] 5.2 在 `LibraryView` 根层增加相册全屏覆盖状态；iPhone 与 iPad 都全屏，不内联；打开时停止内联视频并保存进度，关闭后恢复原网格位置与导航状态。验证：iPhone/iPad 本地 fixture 打开/关闭，分栏与单栈都不丢滚动位置。
- [x] 5.3 实现横向分页容器与 `ZoomableImageView`（`UIScrollView` 包装）：左右滑、双指缩放、双击缩放、放大后拖动；放大时禁用外层翻页，切换页面重置缩放。验证：UI 冒烟覆盖滑动、缩放、双击、放大后横拖不翻页。
- [x] 5.4 实现渐进加载：打开先显示网格缩略图，再读取完整压缩图并解码到屏幕尺寸；保留压缩 Data 供放大重解；快速翻页取消旧请求；相邻页只预取缩略图。验证：用限速 SMB/本地 stub 观察缩略图先行、取消生效、放大不重复读取。
- [x] 5.5 增加相册内存管理：压缩数据上限 64 MB、解码图上限按屏幕尺寸、内存警告释放非当前页、关闭相册释放当前页。验证：连续翻 200 张 fixture，内存不随页数线性增长；Instruments/内存日志记录峰值。
- [x] 5.6 实现相册 chrome：关闭、页码、标题、加载超过 300 ms 才显示进度、失败错误与重试；点击画面切换 chrome 显隐。验证：UI 用例覆盖加载态、错误态、重试与关闭。
- [x] 5.7 实现 iPhone 方向控制：打开请求 `.allButUpsideDown`，关闭恢复 `.portrait`；iPad 跟随系统；旋转保持当前页与缩放状态。验证：iPhone 横竖屏各打开/关闭一次，iPad 分屏旋转一次。
- [x] 5.8 在 README 增加“全屏相册”小节：分页范围、缩放、方向、iPad 全屏、关闭恢复位置。验证：按文档逐项操作，行为一致。

## 6. LIVP 静态与动态

- [x] 6.1 实现 `LivePhotoPackage` ZIP 解析：尾部 EOCD、中央目录、local header、静态/动态条目选择；支持 stored 与 deflate（raw inflate），不支持 ZIP64/加密/分卷并返回明确错误；设置条目数与解压大小上限。验证：`ImageKitTests` 覆盖 stored、deflate、损坏 ZIP、缺少静态图、多个候选条目。
- [x] 6.2 实现 `ZipEntryByteSource`：stored 条目把相对偏移映射到底层 `ByteSource`，支持随机读、长度与关闭；deflate 条目走内存解压路径。验证：fake `ByteSource` 断言 offset/length 映射正确，越界与关闭行为符合 `ByteSource` 约定。
- [x] 6.3 接入 LIVP 静态图：缩略图只读静态条目、全屏预览复用同一提取结果；为静态预览不得读取 MOV 条目。验证：带读取计数的 fake 源断言封面/静态预览期间没有访问动态条目 range。
- [x] 6.4 增加 LIVP 的 `LIVE` 徽标与无动态降级：有 MOV 时显示徽标与长按入口；无 MOV 或提取失败时只显示静态图。验证：有/无 MOV 两组 fixture 的网格与相册页表现符合预期。
- [x] 6.5 实现 `AVAssetResourceLoader` 供给与 `LivePhotoMotionController`：自定义 scheme、content length/type、256KB 分块 `respond`、取消与错误；长按开始、松开暂停、结束回到静态图；翻页/关闭/缩放/内存警告停止并释放。验证：用真实 LIVP 的 MOV 播放；运行前后检查 App `tmp`/`Caches` 无新增视频文件。
- [x] 6.6 接入播放音频会话与触觉反馈：动态播放有声音，松开暂停；与内联视频/系统音频中断不冲突。验证：真实设备长按播放/松开，音频正常；用户于 2026-11-12 确认 6.6 通过（有声音可播放）。
- [x] 6.7 动态部分改为按需加载：页面打开只解析 ZIP 目录与静态图，不预取 MOV；长按开始时才读取动态数据并起播，离开页面释放已缓存的动态数据。验证：连续翻 20 个 LIVP 不会下载整段视频；长按可正常播放，日志区分静态/动态耗时。
- [x] 6.8 在 README 增加“LIVP 静态与动态”小节：支持文件形态、静态/动态行为、无本地落盘、目录形态与损坏包的限制。验证：按文档描述逐项操作，行为一致。

## 7. 搜索、播放与抽帧隔离

- [x] 7.1 扩展 `LibrarySearchResultsView`：图片结果使用缩略图、原始标题与“图片”类型标识；点击图片结果先确保目录已加载，再直接打开相册并定位；加载失败给出行级错误。验证：本地混合库搜索 `IMG` 与目录名，图片命中直接进相册。
- [x] 7.2 视频命中保持 `reveal`；若 `mediaFilterIsApplicable` 且视频被过滤，先自动启用 `showsVideos` 再定位。文档命中保持直接打开阅读器。验证：在“只看图片”过滤下搜索并点击视频结果，目录显示视频且定位正确。
- [x] 7.3 搜索结果不受目录过滤影响，搜索时过滤条隐藏；搜索范围说明与索引补全逻辑不变。验证：过滤为只看图片后搜索，结果仍包含视频与文档。
- [x] 7.4 补强播放隔离：`LibraryStore.activate`/`preparePlayback`/`play` 与 `PlaybackQueue` 只处理 `.video`；诊断自动播放、`-libraryOpenFirst` 与压力选择器只选视频；图片点击走相册。验证：`PlaybackQueueTests` 覆盖视频→图片→视频；单元测试图片不会创建播放任务。
- [x] 7.5 确保图片缩略图不调用 `DemuxProbe`，图片不进入播放进度、Now Playing、画中画与字幕发现。验证：stub 源断言图片缩略图无解封装；播放进度记录数不因图片增加。
- [x] 7.6 在 README 增加“搜索与播放隔离”小节：图片命中、视频命中自动启用过滤、文档命中、连播跳过图片。验证：按文档描述操作，行为一致。

## 8. 集成、性能与验收

- [x] 8.1 运行完整单元测试与模拟器构建：`xcodebuild ... -scheme IceMovieTests test` 与 App build 全量通过；新增测试无跳过。
- [x] 8.2 增加 UI 冒烟：本地混合 fixture 的过滤条、图片网格、相册滑动/缩放、LIVP 徽标与长按、空状态；验证：iPhone 与 iPad 模拟器各跑一遍。
- [x] 8.3 做性能验收：500 张图片目录滚动、缩略图读取字节/解码耗时、相册连续翻 200 张的内存峰值、首张打开耗时；把数据记录到 `docs/`。验证：滚动无明显卡顿，内存不随页数线性增长，缩略图不拉全尺寸。
- [x] 8.4 在 `tropical-advpc.lan` 的 `Photos` 目录做真机验收：JPG/PNG/HEIC/HEIF/LIVP、混合目录过滤、iPad 全屏、iPhone 旋转、长按动态、损坏文件、只读/断线恢复；把结果记录到 `docs/`。验证：逐项记录通过/失败与复现步骤，未通过项有明确说明。
- [x] 8.5 检查与 `document-reader`、`startup-latency` 的合并结果：文档分区、图片网格、过滤条、播放准备耗时与起播路径无回退。验证：对比合并前后的播放/启动回归数据，现有文档阅读测试与视频回归全部通过。

## 9. 网格无白边、旋转与保存

- [x] 9.1 图片网格改用深色底、完整居中显示，移除浅色内边距与白色留白；视频仍填满。验证：本地 fixture 截图不再出现白边，横图/竖图不裁切。
- [x] 9.2 在 `ImageKit` 实现 `ImageEncoder`：屏幕预览旋转、原图分辨率重解、保持原格式编码，并保留可用元数据、EXIF 方向重置。验证：`ImageEncoderTests` 覆盖 PNG/JPEG 方向/HEIC 与损坏样本，旋转后尺寸正确。
- [x] 9.3 增加 SMB 覆盖写：临时文件、大小校验、原文件备份、改名替换、失败恢复；增加 `LibrarySource.overwriteImage`。验证：本地 fixture 覆盖保存后文件变为 48×96 且哈希变化。
- [x] 9.4 相册增加顺时针旋转按钮；保存菜单常驻，未旋转时可直接保存到系统相册，旋转后额外出现“覆盖原照片”，覆盖前二次确认。验证：UI 测试完成未旋转保存、旋转、菜单、确认、覆盖和关闭。
- [x] 9.5 接入系统照片库 add-only 保存与 `NSPhotoLibraryAddUsageDescription`。验证：模拟器授权后保存出现“已保存到系统相册”，照片库中新增 `IMG_0007.PNG`。
- [x] 9.6 增加非破坏性 SMB 写入探针并复用 iPad 凭据验证真实 `Photos` 共享：68B 创建、256B 覆盖、删除成功。验证：日志 `写入探针成功 ... 已删除`。
- [x] 9.7 更新 README 与 `docs/image-gallery-acceptance.md`：网格无白边、旋转、覆盖保存、系统相册、SMB 写入探针与权限说明。

## 10. 拍摄时间排序、照片日历与缓存上限

- [x] 10.1 实现 `PhotoTimestampParser`：只匹配扩展名前最后一个下划线后的 14 位 `_yyyyMMddHHmmss`，校验日期与时分秒；`MediaEntry.captureTimestamp` 在创建时解析。验证：`PhotoTimestampTests` 覆盖 JPG/LIVP 文件名、非法月日与缺少扩展名。
- [x] 10.2 `MediaOrdering` 对图片与视频统一按拍摄时间倒序，无时间戳条目排在带时间戳条目之后，目录仍最前、文档仍最后。验证：单元测试覆盖最新在前、混合时间戳与无时间戳、视频时间戳、文档仍在最后。
- [x] 10.3 新增 `PhotoCalendarIndex`，按年/月/日统计图片数量并记录当天最新图片；`LibraryStore` 在加载、缓存命中、刷新与切换目录时重建 `photoCalendar`。验证：单元测试覆盖年月日分组、数量与当天首张。
- [x] 10.4 过滤条最右侧增加日历入口（单类型照片目录也显示），日历按年/月/日选择；选择日期后跳转到当天照片，另提供“查看整月”跳到该月最新照片；跳转自动恢复图片过滤并通过 `pendingScrollTarget` 滚动。验证：UI 测试断言最新照片在最前、日历可选 2022-01-01、整月跳转可定位到 2021-12 的照片。
- [x] 10.5 修复日历布局：popover 锚点改为按钮下方，日期网格空白占位与日期按钮使用唯一索引，避免月初日期被 `LazyVGrid` 合并；年份显示不再出现 “2,022” 分组。验证：iPhone 与 iPad UI 测试均可找到并点击月初日期。
- [x] 10.6 缩略图磁盘缓存硬上限改为 64 MB，图片与视频封面共用并按 LRU 淘汰；`LibraryStore` 默认容量跟随该上限，`-thumbnailCacheLimitMB` 启动参数也收敛到上限以内。验证：`ThumbnailCacheTests` 断言默认上限、参数收敛为 64 MB，缓存淘汰用例通过。

## 11. 二轮评审修复

- [x] 11.1 `MediaOrdering` 的同标题平局改为与比较双方类型无关的单一键（季 → 集 → 文件名 → 路径），非视频使用固定哨兵；覆盖同标题视频与图片的 6 种输入顺序。验证：`LibraryOrderingTests` 全部通过。
- [x] 11.2 SMB 覆盖写入接入 `ensureManager`，可恢复错误先重连再重试一次，与读取路径一致；临时文件/备份清理逻辑保持不变。
- [x] 11.3 相册 `activeModel` 改为按当前条目 ID 校验，翻页瞬间旧模型不会驱动旋转/保存，也不再依赖父子 `onChange` 的调用顺序。验证：新增 UI 测试翻页后旋转并进入覆盖菜单。
- [x] 11.4 `ThumbnailStore.init` 在缓存边界再次收敛容量到 64 MB，未来调用方无法绕过上限。验证：`ThumbnailCacheTests` 断言 500 MB 请求被限制为 64 MB。

## 12. 真机磁盘占用收敛（目标 <200MB，硬上限 500MB）

- [x] 12.1 容器头缓存默认上限从 512 MB / 单文件 64 MB 降为 48 MB / 24 MB；初始化时按新预算裁剪，并删除索引外的孤儿页文件。验证：`ContainerHeaderCacheTests` 覆盖重开裁剪与孤儿清理。
- [x] 12.2 缩略图上限降为 64 MB，字幕脚本上限降为 16 MB，并在启动时按新上限修剪；三类缓存合计 128 MB。
- [x] 12.3 播放日志按 4 MB 轮转并保留一份 `.1`；启动维护删除超限的 `ice-playback.log`、`ice-smb.log`、`ice-stress.log` 等旧调试文件，文档自检报告只保留最近 3 份。
- [x] 12.4 增加 `CacheUsageReport`：按实际分配块统计容器头、缩略图、日志、系统快照、字幕等模块占比；诊断页「更多 > 缓存占用」可查看，`-cacheReport` 输出到 stderr。
- [x] 12.5 真机验证升级后首次启动即回收旧缓存，App 数据降到 200 MB 以内。

## 13. 瀑布流与拍摄日期

- [x] 13.1 图片网格改为按自然宽高比的瀑布流：多条 `LazyVStack` 交替分列，图片完整显示、不裁切，显著减少固定 2:3 单元格的黑边；视频与目录仍保持 2:3。
- [x] 13.2 缩略图加载后回填宽高比并持久化到 `Caches/ThumbnailAspects.json`，限制 0.4–2.5；清空缓存时一并删除。验证：横图与竖图单元格高度明显不同。
- [x] 13.3 网格图片副标题优先显示文件名中的拍摄日期，无时间戳时才用修改时间。验证：UI 测试断言 `2022年3月10日` 出现在图片下方，而不是同批同步日期。

## 14. 瀑布流滚动性能

- [x] 14.1 缩略图最大宽度从 480 降到 384，并把 `thumb384p` 并入缓存命名空间，旧尺寸文件不再命中；缩略图 PNG 解码移到后台执行。
- [x] 14.2 JPEG 增加前缀快速路径：先读前 384KB，EXIF 内嵌预览图达到 192px 就直接使用，避免为网格封面下载 3–10MB 整图；过小的预览图仍回退完整解码。
- [x] 14.3 单元格滑出屏幕时取消对应的缩略图生成任务；快速滑动期间暂缓瀑布流改高度，停止后再应用宽高比，避免边滑边重排。
- [x] 14.4 真机日志验证：旧路径 87 个封面读取约 239.6MB（平均 2.8MB、最大 9.9MB）；新路径 53 个 JPEG 封面改走 384KB 前缀，只有超大 PNG/无内嵌预览的图片才整图读取。
- [x] 14.5 空闲预取：停止滚动 350ms 后对当前瀑布流列向前预取最多 12 张；全局最多同时保留 12 个预取任务，滑动开始立即取消；预取复用同一套后台下载/解码，完成后写入内存缓存。验证：单元测试预取后 `cachedThumbnail` 直接命中，且只打开一次缩略图源。
- [x] 14.6 修复半截图/边缘图：不再把部分 JPEG 交给 ImageIO（会返回尺寸正确、只解码顶部扫描线的图）。改为解析 APP1/EXIF 的 JPEGInterchangeFormat，只解完整内嵌缩略图；没有内嵌图就回退整图。缩略图版本升到 `thumb384p3`，首次启动清空旧缩略图；宽高比缓存升到 `a3`。单元格请求取消后不记为永久失败，会重试一次。验证：真机 IMG_9415 旧图只剩顶部一条，新图完整；缓存从 68MB 清到 12.9MB。

## Workflow follow-up

- 实现与验收完成后，按项目评审要求归档本 change。
- 归档前更新 `openspec/specs/media-library/spec.md` 的 Purpose，使其覆盖视频、图片与文档，而不是只描述视频。
- 建议先归档 `document-reader` 再归档 `image-gallery`；若顺序相反，手工合并两份 `media-library` delta，确保文档分区与图片网格规则都保留。
- 后续 `photo-sync` 另开 change，实现照片目录标记、系统照片上传与去重；不要在本 change 中提前实现。
- 真实照片覆盖保存建议在一张可恢复的照片上验收；本次已验证本地 fixture 覆盖、模拟器系统相册保存，以及真实 SMB 共享的临时文件写入/覆盖/删除探针。
