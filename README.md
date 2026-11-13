# IceMovie

iPad 优先的 iOS SMB 视频播放器：直接连接局域网 SMB 共享，用 FFmpeg 解封装、VideoToolbox 硬解、AVAudioEngine 输出音频，支持 MKV/MP4、内封与外挂字幕、内联/全屏、画中画（设置页开关，默认关闭）与续播。点击视频默认直接全屏播放；播放结束后按目录顺序自动播放下一集。同一主机存在多个共享时，可在媒体库左栏直接切换，无需断开重连。

## 环境

- macOS + Xcode 26（部署目标 iOS 26.0）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 本地已放置依赖：
  - `Vendor/AMSMB2`（含 libsmb2 源码）
  - `Vendor/ffmpeg/ffmpeg-src` 与已构建的 `Vendor/ffmpeg/lib/{iphoneos,iphonesimulator}`
  - `Vendor/libass`（实验性，当前未接入构建）

## 生成工程

```bash
xcodegen generate
```

新增 Swift 文件或调整 `project.yml` 后必须重新执行。

## App 图标

图标源文件在 `IceMovie/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`（1024×1024、无 alpha）。
需要重新生成时：

```bash
swift Scripts/make-app-icon.swift IceMovie/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

## FFmpeg

构建脚本：`Vendor/ffmpeg/build.sh`。

- 版本：`Vendor/ffmpeg/ffmpeg-src` 中的源码快照
- 架构：`arm64-apple-ios26.0`（真机）与 `arm64-apple-ios26.0-simulator`（模拟器）
- 关闭编码器、复用器、网络与设备层，只保留播放所需：
  - 解封装：matroska、mov/mp4、avi、mpegts
  - 解码：H.264、HEVC、AAC、Opus、FLAC、AC3/EAC3、DCA、Vorbis，以及 ass/ssa/subrip/webvtt 字幕
- 产物：`Vendor/ffmpeg/lib/iphoneos` 与 `Vendor/ffmpeg/lib/iphonesimulator`

重新构建：

```bash
cd Vendor/ffmpeg && ./build.sh
```

## libass

构建脚本：`Vendor/libass/build.sh`。

- libass 0.17.1 + freetype 2.13.2 + fribidi 1.0.15 + HarfBuzz 6.0.0
- 两套架构：`out/iphoneos` 与 `out/iphonesimulator`
- macOS 需要 `glibtoolize`（Homebrew libtool）；脚本会自动设置 `LIBTOOLIZE`，不需要 meson
- freetype 源码从 GNU Savannah 获取（GitHub Release 不附带源码包）

```bash
cd Vendor/libass && ./build.sh
```

接入方式：`IceMovie/Core/CLibass/module.modulemap` 暴露 `ass.h`；App 侧链接
`libass.a`、`libharfbuzz.a`、`libfreetype.a`、`libfribidi.a`、`libiconv` 与 CoreText。
ASS/SSA 走 libass 位图渲染（保留定位、颜色、描边与 OP 特效），SRT 仍走系统文字；
中文字体优先使用容器附件，其次内置 `Resources/Fonts/NotoSansCJKsc-Regular.otf`，
最后用 CoreText 系统字体兜底。

- 特效脚本超过 4MB 或 5000 事件时自动降级为对白，避免 OP/ED 逐字动画拖垮主线程。
- ≥800MB 的大文件内封文本字幕（ASS/SRT/mov_text）直接复用播放泵读到的字幕包，边播边解析，字幕与音画共用同一读流，不再为字幕二次扫描 SMB；45 秒内没有任何字幕包时才回退到分片加载（4s→16s→60s 递增窗口 + 后台预取）。分片读取使用独立的 `subtitle` 优先级，避免被播放预读拖住；窗口顶到片尾时停止预取，读取失败按 2–8 秒退避。这类文件用系统文字层显示对白。
- SMB 短读不再当作 EOF：每块循环续读直到补满或真正到文件末尾，修复小 MP4 播不出和 4K 视频中途黑屏/截断。
- 旋转、重建视频层或显示层解码恢复时，从当前位置重新解出一段关键帧，而不是把旧帧硬塞进新层；避免新层从非关键帧起解导致的黑屏和恢复刷屏。
- 内封 SRT/mov_text/webvtt 由 FFmpeg 放在 `rect.ass` 里（`ReadOrder,Layer,Style,...,Text`），提取时按字段拆分，界面只显示正文；字幕脚本缓存命中时会重新注册容器字体附件。
- PGS/DVD/DVB 等位图内封字幕暂无文本渲染路径，发现时直接跳过，不参与默认选轨。
- 大文件分片字幕连续失败时会回退到后续字幕候选，并在播放器顶部显示错误提示。
- 音频供给不足时冻结主时钟与音频，缓冲恢复后从同一位置继续，避免声音恢复后落后于画面；音频不足会压过视频领先回压，保证拉流线程继续补音频。

## 媒体库条目

- **目录**：始终显示，排在媒体之前，用于逐级下探。目录内部有视频时，取其中一个视频的中间帧作为封面，并保留文件夹角标；没有视频或抽帧失败时回退通用文件夹图标。
- **视频**：MKV/MP4 等受支持容器，2:3 封面填满单元格；多集剧集目录按识别到的季/集升序排列（集号顺序优先于拍摄时间），单集视频仍按时间倒序；结束后自动连播下一集。
- **图片**：JPG/JPEG、PNG、HEIC/HEIF 与 LIVP，按图片宽高比组成瀑布流，完整显示、不裁切，黑边尽量少；标题使用原始文件名，不解析季集；副标题优先显示文件名末尾 `_yyyyMMddHHmmss` 的拍摄日期，没有时才用文件修改时间。图片按拍摄时间倒序（最新在前），无时间戳的条目排在带时间戳的条目之后。
- **文档**：Markdown 与 PDF，在网格下方以列表呈现，按文件名自然排序。
- **其他文件**：字幕、种子、脚本、隐藏配置等不进入媒体库。

### 混合网格与媒体过滤

- 当前目录同时含视频和图片时，搜索栏下方显示“视频”“图片”两个独立过滤按钮，默认都选中，网格混合排列。
- 取消“视频”只保留图片与子目录；取消“图片”只保留视频与子目录；两个都取消时只显示子目录，没有子目录则显示“当前筛选下没有内容”和“显示全部”。
- 只有一种媒体的目录不显示视频/图片过滤按钮，并忽略之前的过滤状态，避免进入纯视频/纯图片目录后一片空白；纯照片目录仍显示“按拍摄日期”和日历入口。
- 进入搜索时过滤条隐藏，搜索结果不受目录过滤影响。
- 过滤状态在当前浏览会话内保持，切换共享时恢复为全部选中；切换过滤时尽量保留当前滚动位置。

### 照片日历

- 当前目录有带拍摄时间的图片时，过滤条最右侧出现日历按钮；没有时间戳时不会显示空入口。
- 日历按年、月列出月份和照片数量，再按日选择；没有照片的日期不可点。
- 点月份可展开该月日期；月份下方提供“查看整月”，直接跳到该月最新的一张照片。
- 选择某一天/月后，过滤条显示当前日期标签和取消按钮；点标签或日历底部的“显示全部照片”会清除日期并滚回全部照片顶部。
- 选择某一天后，网格滚动到当天最新的一张照片；如果之前关闭了“图片”过滤，会自动恢复图片显示。
- 单类型照片目录只显示“按拍摄日期”和日历按钮，不显示视频过滤按钮。

### 照片同步

- 每个 `host + share` 只保留一个“照片库路径”：在目标目录的「更多」菜单里标记，或长按父级网格中的文件夹标记；换标记会提示替换旧目标。
- 目标目录的过滤条在日历按钮旁显示同步按钮；目录为空、没有照片日历也显示。非目标目录不显示。
- 点同步先做只读扫描，预览“系统相册可访问 / 动态照片 / 视频 / 格式不支持 / 缺少拍摄时间 / 目标已有 / 已匹配 / 待同步”，确认后才上传。
- 上传平铺在目标目录，文件名 `原名_yyyyMMddHHmmss.扩展名`；先写同目录临时文件、校验大小、再 rename，绝不覆盖已有文件，也不删除远端文件。
- 增量判断使用“原文件名 + 拍摄时间”，忽略扩展名、大小写和文件名前缀；本地清单按目标隔离并加速后续扫描，重装后靠远端文件名兜底。
- v1 只同步静态图片 JPG/JPEG/PNG/HEIC/HEIF；Live Photo 只取静态图并记录 `livePhotoStill`；视频、GIF、RAW 跳过并计数；隐藏照片不上传；Live Photo 动态与视频留待后续 change。
- 上传期间顶部固定状态条显示目标、已处理/总数、数量进度条、实际 SMB 上传速度与取消；切换目录仍可见，沉浸式相册/播放时被覆盖。
- 单张失败不中断，状态条显示失败计数；整体中断（断线、目标不可写、权限收回）显示常驻红条；结束汇总成功/失败/跳过、用时和平均速度，可重试失败。失败提示只在应用内，不发系统通知。
- 只在前台同步；锁屏或切后台可能中断，下次从剩余照片继续；已同步照片的后续编辑不重传，手机删除照片也不会删除 SMB 文件。
- 首次同步请求系统相册读取权限；保存到系统相册仍只使用 add-only 权限。

### 全屏相册

- 点击图片进入全屏相册；分页只包含当前目录的图片，按网格顺序跳过视频与文档。
- 支持左右滑、双指缩放、双击缩放与放大后拖动；放大时暂停翻页，换页重置缩放。
- iPhone 与 iPad 都使用全屏覆盖层，iPad 不在右栏内联；iPhone 相册允许横竖屏，关闭后恢复媒体库竖屏。
- 进入相册会停止内联视频；关闭后回到原网格位置。加载先显示网格缩略图，完整图到达后无感替换；快速翻页会取消过期读取。
- 原图、全尺寸解码结果与相册预览不落盘，预览图只占内存。
- 相册提供顺时针 90° 旋转按钮修正拍摄方向；保存菜单常驻，不必先旋转：
  - **保存到系统相册**：未旋转时直接保存原图；旋转后保存完整旋转图。仅添加权限，不修改 SMB 原图。
  - **覆盖原照片**：只在存在未保存旋转时出现，按原图分辨率重新编码并覆盖 SMB 原文件，覆盖前二次确认；失败保留原文件。
- 旋转和覆盖支持 JPG/JPEG、PNG、HEIC/HEIF；LIVP 本期只读，但可以保存其中的静态图到系统相册。

### 收藏夹与删除

- 全屏相册左上角提供删除和收藏按钮；关闭按钮仍在底部。
- 收藏按 `host + share + path` 保存在本机，重启、切换目录后仍保留；全屏页的心形会显示当前收藏状态。
- 媒体库顶部工具栏的心形按钮进入/退出收藏夹；收藏夹跨目录汇总当前共享的所有收藏照片，空状态显示“还没有收藏照片”。
- 删除会先弹一次确认，确认后直接删除 SMB 共享里的原文件；成功后关闭相册并刷新网格、日历与收藏夹，失败时提示并保留文件。

### LIVP 静态与动态

- 支持文件形态的 `.livp`；目录形态仍按普通目录导航。
- 网格与全屏先展示 ZIP 内的静态图；生成静态预览不会读取 MOV 动态条目。
- 相册页长按播放动态、松开回到静态图；翻页、关闭、缩放或内存压力会停止并释放播放资源，不生成任何本地视频文件。
- 没有 MOV 的 LIVP 只保留静态图；ZIP 损坏或缺少静态图时显示占位/错误与重试，不影响其他图片。

### 搜索与播放隔离

- 搜索覆盖视频、图片与文档；图片命中直接打开相册并定位，文档命中直接打开阅读器。
- 视频命中沿用“定位到所在目录”；若该目录的过滤器隐藏了视频，应用会先恢复视频类型再定位。
- 搜索结果不受目录过滤器影响；输入搜索关键字时过滤条隐藏。
- 视频连播、诊断自动播放与缩略图抽帧只选择视频；图片不会进入播放队列、续播、Now Playing、画中画或字幕发现。

## 文档阅读

媒体库除了视频，也会列出 SMB 共享中的 Markdown（`.md` / `.markdown`）与 PDF：

- 目录同时包含视频与文档时，文件夹和视频保持网格，文档在网格下方以列表呈现；没有视频的纯文档目录使用“文件夹行 + 文档行”的统一列表，不再显示海报网格。
- 文档行显示去扩展名标题、`MD`/`PDF` 类型、大小与修改时间；文档不参与视频缩略图抽帧，也不使用季集标题解析。
- Markdown 按 GFM 渲染，支持表格、代码块语法高亮（cpp/swift/objc/bash/python/json/yaml/kotlin/javascript/sql/xml 等）、代码复制与 h1–h3 目录；表格和代码块超出宽度时横向滚动。
- Markdown 以 UTF-8 优先，失败回退 GB18030；单文件上限 5 MB。PDF 单文件上限 30 MB，使用 PDFKit 连续纵向滚动，显示页码并提供页面缩略图导航；现有 PDF 没有可用书签目录，因此不依赖 outline。
- Markdown 内容经 DOMPurify 清洗，脚本、事件属性与危险 scheme 被移除；CSP 只允许本地样式/脚本，远程图片、字体与样式不会发起请求。外链交给系统浏览器，文档内锚点留在阅读器内。
- 不持久化阅读位置：关闭后重新打开 Markdown 从开头开始，PDF 从第 1 页开始。
- 检索会索引文档文件名；文档命中直接打开阅读器，视频命中仍定位到所在目录。文档读取使用 `subtitle` 优先级的 SMB 读取，低于播放预读，打开文档不会暂停或跳转正在播放的视频。
- 阅读器资源在 `IceMovie/Resources/DocumentReader/`（marked、DOMPurify、highlight.js 与本地 CSS），许可信息见同目录 `NOTICE.md`。

真机/模拟器批量验收：

```bash
# 本地目录
... -libraryLocal /path/to/docs -libraryPath "面试知识库" -documentSelfTest

# SMB（复用设备上已保存的凭据）
... -library -smbHost tropical-advpc.lan -smbShare pythonworkspace \
  -libraryPath "面试知识库" -documentSelfTest
```

验收会递归打开所有文档，检查表格/代码块/高亮/目录、滚动到底部与 PDF 页数，结果写入 App `Documents/DocumentSelfTest-*.json`，并在日志输出 `DOCSELFTEST PASS/FAIL`。当前 `pythonworkspace/面试知识库` 的 118 个可见文档（110 Markdown + 8 PDF）全部通过，累计渲染 603 个表格、498 个代码块、348 个高亮代码块，全部可滚动到底部。

## 构建与签名

模拟器：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovie \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test build \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

必须使用 `CODE_SIGN_IDENTITY='-'`；`CODE_SIGNING_ALLOWED=NO` 会让钥匙串返回 `-34018`。

真机：在 Xcode 中为 `IceMovie` target 选择自己的 Team，或传入 `DEVELOPMENT_TEAM=<TEAM_ID>`。

## 测试

单元测试：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovieTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test test \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

引擎级回归（第 4–7 组，一条命令）：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovieTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test test \
  -only-testing:IceMovieTests/PlaybackRegressionTests \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

UI 测试：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovieUITests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test test \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

### 测试样本

- 本地库通过启动参数注入，不写死主机：`-libraryLocal /private/tmp/animi`
- 回归样本至少需要：
  - `[www.domp4.com]大逃杀.2000.DC.BD1080p.中文字幕.mp4`（H.264 + AC3）
  - `强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv`（HEVC 10-bit + AAC，内封 ASS）
  - `强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - Sub/Kaze ga Tsuyoku Fuiteiru 01.{chs,cht,jpn}.ass`（三语外挂）
  - `re0 s3/… - 01 [IEM 2160p WEB-DL AAC Multi-Subs].mkv`（4K HEVC）
- 缺样本时回归用例会 `XCTSkip` 对应条目。
- 损坏样本：`错误样本/损坏的视频.mp4`（随机字节，用于播放失败提示）。

### 图片样本（image-gallery）

- 支持 `.jpg`、`.jpeg`、`.png`、`.heic`、`.heif`、`.livp`；LIVP 本期只支持文件形态。
- 单元测试 fixture 位于 `IceMovieTests/Fixtures/ImageGallery/`，随 `IceMovieTests` 资源包加载：
  - `sample.jpg`、`sample.heic`、`sample.heif`、`sample-alpha.png`（透明）、`sample-landscape.png`、`sample-portrait.png`、`sample-orientation.jpg`（EXIF Orientation=6）
  - `sample-stored.livp` / `sample-deflated.livp`（静态 HEIC + 0.4 秒 MOV）
  - `sample-no-motion.livp`、`sample-no-still.livp`、`broken.livp`
- 重新生成：`Scripts/make-image-fixtures.sh`。需要 macOS `sips` 与 `zip`；传入 `MOV_SOURCE=<本地影片>` 时用 `avconvert` 生成 `motion.mov`。

## 启动参数（调试/自动化）

- `-libraryLocal <路径>`、`-libraryPath <相对路径>`：本地库
- `-libraryOpenFirst`、`-libraryOpenName <关键字>`：加载目录后自动按产品播放路径打开首个匹配视频
- `-documentSelfTest`、`-documentSelfTestRoot <相对路径>`、`-documentSelfTestLimit <数量>`：递归验收文档，渲染并滚动到底部，结果写入 `Documents/DocumentSelfTest-*.json`
- `-libraryInlinePlayback`：诊断用，首次点视频时不进入全屏，便于验证“播放中打开文档”
- `-librarySeekTo <秒>`：起播 3 秒后执行一次跳转
- `-librarySeekBackTo <秒>`：首次跳转 3 秒后再回跳，用于验收
- `-libraryCloseAfter <秒>`：播放若干秒后关闭，验证续播
- `-libraryRewindAt <秒> -libraryRewindTo <秒>`：每集播到指定秒后自动回退，用于长片压力验收
- `-acceptanceReport`：每集结束/切换时把缓冲、字幕、偏差指标追加到 `Documents/ice-acceptance.json`
- 每条压力 JSON 额外记录 `cpuAvgPercent` / `cpuMaxPercent` / `cpuEndPercent`（单核百分比，100 = 占满一个核心）；`cpuEndPercent ≥ 80` 通常意味着 EOF 后泵线程空转或收尾线程异常，需要复核
- `-resetAcceptanceReport`：启动时清空逐集验收报告
- `-keepControlsVisible`：验收时让控件常显（仅测试）
- `-stressRandom`：随机抽样压力测试开关；配合 `-stressRootPath <相对路径>`（默认共享根）
- `-stressCount <条数>`、`-stressPlaySeconds <秒>`、`-stressSeekAfter <秒>`、`-stressSeekFraction <0–1>`
- `-stressTimeLimit <秒>`：压力测试时间上限（默认 1800）；发现无视频帧、显示层解码恢复、单分钟缓冲 ≥6 次、播放失败或显示层 failed 时自动停止
- `-stressFilter <子串>`：只测路径包含该子串的视频，用于单文件复现
- `-stressHDFirst`：验收时把最大的 4K 排在小 MP4 之后，优先覆盖高码率片
- `-stressTolerateBufferStalls`：把缓冲超标记录为环境异常（`stressBufferException`）并继续，只有无视频帧/解码恢复/播放失败才中断
- `-stressSeekBackSeconds <秒>` / `-stressSeekBackFraction <0–1>`：播放中段再回退指定秒数或比例，用于验证回退命中缓存
- `-stressSeekForwardSeconds <秒>`：播放后段再前进指定秒数，用于验证邻近前跳命中
- `-smbChunkMB <MB>` / `-smbRingMB <MB>`：SMB 播放读块与预读窗口（默认 1MB / 512MB）
- `-smbSeekCache 0`：关闭新的 seek 缓存复用，回退到旧的“seek 清空预读环”行为
- `-playbackRate <倍速>`：加速长片回归（0.5–2.0）
- `-throughputReport <秒>`：播放指定秒数后把吞吐/跳转统计写入 `Documents/ice-throughput.json`
- `-shardedThresholdMB <MB>`：自检时降低分片字幕阈值（默认 800MB）
- `-smbHost <地址> -smbShare <共享> -library`：SMB 库
- `-resetPlaybackProgress`：清空续播记录
- `-resetSubtitlePreferences`：清空字幕偏好
- `-debugLog` / `-logDebug`：打开调试日志并追加写入 `Documents/ice-playback.log`（多窗口只初始化一次，不互相清空）
- `-diagnostics`：直接打开诊断页

## 缓存策略

App 不缓存视频。播放时使用 **512 MB 内存预读环 + 15 秒音视频缓冲**（只占内存、不落盘，关闭播放即释放）；落盘缓存只有四类，合计上限 **144 MB**：

| 缓存 | 上限 | 淘汰 | 说明 |
| --- | --- | --- | --- |
| 图片/视频缩略图 `Caches/Thumbnails` | 64 MB | LRU，按文件修改时间 | 图片与视频封面共用上限；每个封面约几十 KB，命中后刷新访问时间 |
| 目录封面 `Caches/FolderCovers` | 16 MB | LRU，按文件修改时间 | 内部视频中间帧；独立目录，避免被视频预热持续写入的缩略图缓存淘汰 |
| 内封字幕 `Caches/SubtitleScripts` | 16 MB | LRU，按文件修改时间 | 只存降级后的 ASS 文本（通常 60 KB–1 MB），不缓存字体与视频 |
| 容器头 `Caches/ContainerHeaderCache` | 48 MB | LRU，按文件最近访问 | 单文件最多 24 MB，只缓存打开阶段的 64KB 页，不缓存播放媒体数据 |

图片宽高比另存为 `Caches/ThumbnailAspects.json`（通常几十 KB 到几百 KB），用于瀑布流稳定排版。

### 共享侧车缩略图

照片/视频目录会在共享根下维护一个隐藏缓存：

```text
.icemovie/
  version
  index.json          # 路径、宽高、大小、修改时间、缩略图键
  thumbs/ab/<hash>.jpg
```

- 读取顺序：内存 → 本地 64MB 缓存 → 共享侧车 → 原图。侧车命中时不再读原图。
- 进入目录自动全量预热：可见项优先、单并发、滚动时让路、可暂停/继续/取消；顶部显示进度。
- 新照片/变化照片增量补；删除文件的索引与孤儿缩略图会清理。
- 侧车缩略图为 384px JPEG，单张约 10–50KB；3,596 张照片约 100–200MB，不占本地设备空间。
- 共享只读或写入失败时自动回退本地缓存 + 原图，不影响浏览。
- 充电空闲时通过 `BGProcessingTask` 继续当前目录预热；首轮通常约 10–25 分钟，之后进入增量模式。
- 滚动不再持续跟踪 `scrollPosition`，改用 `ScrollViewReader` + 轻量可见锚点；60Hz iPad 实测 10 次滑动 54.5–57.2fps。可用 `-fpsMonitor` 启动参数输出实时帧率。
- 进入目录时从共享索引预填宽高比，单元格首次加载先确定比例再显示图片，避免滑动时先闪一帧 2:3 黑边再跳成真实比例。
- 目录封面走独立的单并发队列，取内部视频的中间帧；优先直接子视频，没有时最多向下扫描两层、4 个子目录。封面写入独立的 16MB 本地缓存，不写共享侧车；候选缓存 30 秒，内部视频变化后按新的大小/修改时间重新生成。
- 上次选中的内部视频会持久化 24 小时；再次启动命中封面时直接读本地缓存，不再枚举 SMB 目录，也不会重新抽帧。只有封面被淘汰或选择过期后才重新解析候选。

加上日志轮转和系统快照，App 数据目标控制在 **200 MB 以内**，硬上限 **500 MB**；启动时会自动修剪升级前遗留的超大缓存。iPad 实测从约 800 MB 降到 **64–67 MB**（容器头缓存重建后播放一个视频约 3 MB，后续最多再增长 48 MB）。

- 内存中的封面另有 64 MB `NSCache`，退出即释放。
- 图片缩略图与视频共用 `Caches/Thumbnails` 的 **64 MB** 硬上限：网格按 384px 下采样，生成失败显示“无预览”且同一会话不重试；JPEG 先读 512KB 前缀，解析 EXIF 后只解码完整的内嵌缩略图，避免为封面下载整张 3–10MB 原图；没有内嵌图才整图解码。缩略图解码在后台完成，滑出屏幕的生成任务会取消，快速滑动时暂缓瀑布流改高度；停止滚动后会预取后续最多 12 张封面并提前解码，滑动开始则立即取消。缩略图生成逻辑升级时会清空旧版本缓存，避免历史半截图继续被使用。实测 ImageIO 通过直连数据源会请求整张压缩图，因此网格封面按可见条目读取整图（受低并发与缓存约束），不做全尺寸解码；LIVP 只读取静态图条目，不碰 MOV。原图、全尺寸解码结果与相册预览都不落盘，相册图只在内存中保留当前页。
- 播放预读：SMB 播放块默认 1 MB、内存环约 512 MB（512 块，可用 `-smbChunkMB` / `-smbRingMB` 调整）；音频/视频各补到 15 秒，起播快速档只需 1 帧视频 + ≤300ms 音频，慢链路自动回退到 2s/1s。局域网带宽足够时提前读、提前解码，网络抖动不再立刻触发“缓冲中”；该缓冲只占内存，不写硬盘。
- 预读是持续的后台任务：环形窗口填满后不会停死，播放消耗后从新的读位置继续补下一段。
- 视频包封装/投递在独立有界队列和线程完成，播放泵只做读包与音频/字幕处理；音频低于 1 秒时暂停后台预读，把 SMB 带宽让给播放读，避免高码率 4K 反复缓冲。
- 关闭视频或切换文件时会立即取消旧文件的预读任务并递增 generation，旧任务最多完成手头一个 1MB 读就退出，不会在后台继续下载抢下一部的带宽。
- 视频队列默认上限 96 包 / 96MB，满时优先丢最老非关键帧；seek 时清空队列并用 generation 隔离旧包。
- seek 先查连续缓存：回退或邻近跳转命中时不重置预读环、不重新下载；未命中时只丢弃前向窗口，先读目标位置第一块，再从解封装读头向前预读。
- 读窗口显式区分播放头、解封装读头和预读最远点：缓冲区间从播放头算到预读最远点，包含已解封装但尚未播放的数据；进度条不会只显示读头之后的一小段。
- 回看窗口默认约 20 秒、最多 64 MB，其余内存留给未来窗口；淘汰先丢回看窗口外的远端块，再丢前向窗口外和窗口内离播放头最远的数据。
- 播放器 HUD：iPad 右上角在控件可见时显示实时下载速度和电量；返回/关闭按钮与状态栏随控件一起淡入淡出；标题在 iPad 允许两行。进度条用浅绿色显示当前播放点到预读窗口末端的已缓冲区间。
- 缩略图与字幕脚本的缓存键都带数据源命名空间（SMB 为主机 + 共享，本地源为根目录绝对路径），切换共享或根目录不会串用。
- 字幕脚本缓存键还带格式版本；解析或降级逻辑升级后，旧缓存会自动失效。
- 最坏会先写入一个新文件再触发淘汰，瞬时可能略微超过上限，但下一次读取前就会回到预算内。
- 媒体库「更多 > 清空缓存」可立即删除缩略图、目录封面、字幕脚本与容器头缓存。
- 诊断页「更多 > 缓存占用」会按实际分配块显示各模块占比；`-cacheReport` 启动参数可把同一份报告输出到 stderr。

## 真机实测（iPad Air 11 英寸 M2，iOS 27.0.1，SMB `192.168.5.2` / `TROPICAL-ADVPC.local`）

通过 `-libraryOpenFirst -throughputReport <秒>` 让真机按产品路径播放并写回
`Documents/ice-throughput.json`，用 `devicectl device copy from` 取回：

| 样本 | 编码 | 平均码率 | 实测读取 | 时长 | 欠载 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 强风吹拂 01（1080p） | HEVC + AAC | 2.00 Mbps | 0.21 MB/s | 60s | 0 | 无失败 |
| Re:Zero 01（2160p） | HEVC + AAC | 3.12 Mbps | 0.91 MB/s | 60s | 0 | 无失败 |

4K 样本跳转到 300 秒：首包 311ms、预滚 40 帧、落点偏差 0.38s、无欠载。

### 长跑验收（iPad 模拟器，冷启动）

清空 `Thumbnails` 与 `SubtitleScripts` 后，用四月第 4、5 集（1.13GB / 1.44GB，内封 ASS 分片）走完整流程：

1. 第 4 集从 0 秒完整播放 1372.2 秒：0 欠载，最大音频偏差 0.032s、显示偏差 0.002s，625 条分片字幕；播完自动进入第 5 集。
2. 第 5 集播放到 13:07 自动关闭并保存续播位置 787.4s；重开后从 787.4s 续播。
3. 回退到 600s（10:00）：seek 出画 19ms，字幕窗口 590–660s 约 0.1 秒就绪。
4. 从 600s 继续播到 1372.1s：0 欠载，最大音频偏差 0.03s、显示偏差 0.001s，累计 341 条字幕；播完自动进入第 6 集。

内存预读环 512 MB：按 3.12 Mbps 可缓存约 23 分钟内容，按 Solo Leveling 的
5.8 Mbps 约 12 分钟，按高码率 4K（80 Mbps）约 51 秒；起播快速档只需 1 帧视频 + ≤300ms 音频，慢链路自动回退到 2s/1s，
播放中音视频各补到 15 秒。该缓冲只占内存，不写入硬盘缓存。

### iPhone 横屏播放（iPhone 16 真机验证）

- 媒体库固定竖屏；点击视频进入全屏时自动切到横屏，即使系统开启“竖排方向锁定”。
- 全屏播放器在紧凑布局改用根视图覆盖层（不再使用 `fullScreenCover`），避免系统弹层的视图控制器只支持竖屏导致 `requestGeometryUpdate` 失败，也避免键盘退场动画期间覆盖层被丢弃。
- 播放 350MB H.264 MP4：横屏画面、进度条、±90 秒与字幕按钮正常；画中画改由「更多 > 设置」开关控制（默认关闭）。退出播放回到竖屏媒体库。
- 搜索定位后再点视频（键盘仍在退场）也能正常进入播放器，`testOpenFromSearchPresentsPlayer` 覆盖该路径。

### 随机起播 / 中间跳转压力验收

使用 `-stressRandom -stressRootPath "" -stressCount 16 -stressPlaySeconds 60 -stressSeekAfter 4 -stressSeekFraction 0.5 -stressTimeLimit 1800`：

- 不递归扫共享：样本来自 SwiftData 播放历史 + 当前目录 + 根目录里关键词命中的已知目录（Solo / American / 无职 / K-ON!）和名字带 2160p/4K/UHD/HDR 的电影目录，目录列举总预算 20 秒。
- 过滤小于 100MB 的广告占位文件与花絮；每个目录最多取 3 条，保证多样性。
- 第一条优先小 MP4（<1.5GB）让画面尽快出现，随后保证 1080p MKV、至少 3 条 4K MKV、超过 5GB 的长片都有覆盖。
- 每条起播 4 秒后跳到 50%，播放约 1 分钟。
- 逐条写 `Documents/ice-acceptance.json`：首帧耗时、视频入队/恢复次数、显示层状态、视频队列深度/丢包、缓冲次数/分钟、累计缓冲、seek 时延/偏差、`seekCacheHit`、`seekCacheHits`/`seekCacheMisses`、`ringResetCount`、字幕条数与错误。
- 无视频帧、显示层解码恢复、播放失败或显示层 failed 会自动停止；单分钟缓冲 ≥6 次默认也停止，加 `-stressTolerateBufferStalls` 时改为记录 `stressBufferException` 并继续，适合区分代码问题与服务器/过热掉速。最多 30 分钟。
- 总结条目包含 `stressCompleted`、`stressSeriousFound`、`stressBufferExceptions`、`stressStopReason`。

### 起播延迟诊断字段

验收报告的每条播放记录额外包含以下字段，用于区分“代码读取量”和“环境掉速”：

| 字段 | 单位 | 含义 |
|---|---|---|
| `playerPresentedMilliseconds` | ms | 点击到播放页出现的时间；占位图与加载态在此刻已可见 |
| `openBytesRead` | byte | 打开容器阶段实际从字节源读到的字节数 |
| `openReadCount` | 次 | 打开阶段字节源发起的读取次数 |
| `avioFillCount` | 次 | `AVIOBridge` 预读窗口填充次数 |
| `attachmentBytes` | byte | 容器附件总字节数（不含已跳过的字体） |
| `attachmentFontBytes` | byte | 容器附件中字体字节数 |
| `skippedFontCount` | 个 | FFmpeg 跳过的字体附件数量 |
| `headerCacheHitBytes` | byte | 容器头缓存命中的字节数 |
| `headerCacheHitRatio` | 0–1 | 打开阶段读取中缓存命中的比例 |
| `subtitleScanMilliseconds` | ms | 起播后外挂字幕扫描耗时 |
| `startupPrerollMode` | `fast` / `conservative` | 起播预滚档位 |
| `startupBufferStalls` | 次 | 起播后 30 秒内的缓冲次数 |
| `lastSeekTimebaseOffset` | s | seek 完成时的显示层时间基偏差；窗口内 tick 采样不会覆盖它 |
| `maxSeekTimebaseOffset` | s | seek 后 2 秒内该偏差的最大值；>1s 表示画面可能停住或快速追赶 |
| `seekTimebaseJumpCount` | 次 | 时间基偏差超过 1 秒的次数；每次 seek 最多计 1 次 |

### 容器头缓存

- 位置：App 沙盒 `Library/Caches/ContainerHeaderCache/`，`index.json` 记录页位图，`data/` 存 64KB 页。
- 写入范围：只在“打开容器”阶段写入；`PlaybackEngine.play()` 之后停止写入，播放媒体数据不落盘。
- 容量：全局 48MB、单文件 24MB，按文件最近访问 LRU 淘汰；源文件大小/修改时间/首 64KB 指纹任一变化即失效。启动时会收敛到新预算并清理索引外的孤儿页文件。
- 清理：媒体库「更多 > 清空缓存」会同时删除缩略图、目录封面、字幕脚本与容器头缓存；也可以删除上述目录。
- 验证二次打开：先播一次，再播同一文件，报告中的 `headerCacheHitRatio` 应明显上升、`openBytesRead` 应明显下降。

## 真机人工验证清单

以下项目无法靠模拟器闭环，必须在 iPad（主要场景）与 iPhone 上人工确认：

1. 首次访问局域网时出现系统授权框；拒绝后给出可恢复提示（1.3）
2. 分别用 IP（如 `192.168.5.2`）与 `.local` 名称连接同一主机
3. 锁屏后音频继续，锁屏/控制中心显示标题、进度，播放/暂停/±90 秒可用（8.2）
4. 「更多 > 设置」中画中画开关默认关闭；开启后离开 App 自动进入画中画，窗口内容正常、可暂停与关闭（模拟器窗口内容可能黑屏）
5. 1080p 与 4K 样本的实际可持续码率、预读窗口是否足够（8.5）
6. 解封装失败、编码不支持、主机不可达三种提示互不相同且都能返回媒体库（8.3）
7. iPad 分栏浏览、内联播放、全屏互转、外接键盘、分栏与滑动覆盖切换（8.7）
8. 六条验收标准在 iPhone 与 11 英寸 iPad Air 上逐条记录（8.6/8.7）
9. 纯文档目录只显示“文件夹 + 文档”列表；混合目录显示视频网格 + 文档列表；文档行带 `MD`/`PDF` 徽标
10. Markdown 中的表格、代码块、高亮、复制、h1–h3 目录与外部链接按预期工作；关闭后重新打开从开头开始
11. PDF 连续滚动、页码、页面缩略图跳转与损坏 PDF 的重试提示正常；文件名检索可直接打开文档

## 已知限制

- 模拟器画中画窗口内容可能黑屏，但音频与播放进度继续；以真机为准。
- 损坏文件在个别 demuxer 上探测较慢；已修正 FFmpeg 自定义 IO 的 EOF 与失败清理，并保证播放准备不阻塞媒体库。
- libass 的复杂特效（模糊、逐字动画等）仍受字体与脚本支持范围限制；常规对白、定位 OP、颜色与描边已保真。
- ≥800MB 的内封字幕按播放位置分片读取并使用系统文字层，以保证秒开；OP/ED 逐字特效会降级为对白。
