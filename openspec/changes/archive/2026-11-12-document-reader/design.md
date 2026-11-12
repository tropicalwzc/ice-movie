# Design

## Context

见 `proposal.md` 的 Why。当前实现的关键约束：

- 媒体库的条目模型只有“目录 / 非目录”两态，`MediaKind.isVisible` 只保留 8 种视频扩展名和目录；`LibraryStore.activate` 把所有非目录条目都当作视频处理。
- 目录列举、搜索索引、缩略图、播放队列、诊断自动播放都建立在“非目录 = 视频”的假设上；直接把 Markdown/PDF 放进 `currentEntries` 会污染播放链路。
- 数据源只有 SMB 与本地目录两种，没有外部文件导入或 `open-in` 入口；文档必须通过现有 `LibrarySource` 读取。
- 实际语料：`pythonworkspace/面试知识库` 有 121 个 Markdown（3.9 MB，最大 208 KB，110 个含表格）和 8 个 PDF（5–29 页，最大 3.19 MB，均有文本层）。所有 Markdown 为 UTF-8；PDF 用 PDFKit 读取时 `outlineRoot` 为空，不能依赖书签目录。
- 工程约束：iOS 26、Swift 6 strict concurrency、iPad 优先；项目不使用 SPM，第三方前端资源必须本地打包；`startup-latency` 正在改 `LibraryView` / `LibraryStore`。

## Goals / Non-Goals

**Goals:**

- 让 Markdown 与 PDF 成为媒体库的一等条目，参与目录导航与文件名检索，但不进入播放、缩略图或视频标题解析链路。
- 用一套明确的分区规则同时服务“视频目录”和“纯文档目录”，不牺牲现有视频浏览体验。
- Markdown 阅读器覆盖技术资料的核心排版：GFM 表格、代码块高亮与复制、h1–h3 目录、外链处理、内容安全。
- PDF 阅读器提供连续滚动、页码与页面缩略图导航，适配 5–29 页的技术文档。
- 文档读取与渲染失败时给出可恢复的错误态；文档阅读不持久化位置，也不打断正在播放的视频。

**Non-Goals:**

- 不做阅读位置、书架、分页或阅读进度持久化。
- 不做全文检索、PDF 全文搜索、批注、编辑或导出。
- 不支持 Markdown 图片与相对链接（当前语料为 0），也不支持 `.txt`、`.py` 等其他文本格式。
- 不新增外部文件导入、分享菜单打开或 iCloud 文档入口。

## Decisions

### D1：条目类型用显式 kind，不再用 `isDirectory` 二分

`MediaEntry` 保留 `isDirectory` 兼容现有调用，同时增加计算属性 `kind`：

```
directory | video | markdown | pdf
```

`MediaKind` 增加文档扩展名集合与 `DocumentFormat`（`markdown` / `pdf`）。`MediaKind.isVisible` 改为“目录 || 视频 || 文档”。`LibraryEntryBuilder` 因此会把文档带进 `currentEntries`。

排序仍由 `MediaOrdering` 负责目录优先；视频继续按集号自然排序，文档在同一目录内按文件名自然排序。分区在视图层/Store 层按 kind 过滤，不改变全局排序契约。

**替代方案**：新增独立的 `DocumentEntry` 与第二次目录列举。否决原因是需要重复 SMB 枚举、导航、搜索与缓存状态，且同一目录会出现两套滚动位置。

**必须同步修正的调用点**：

| 位置 | 现有假设 | 修正 |
|---|---|---|
| `PlaybackQueue.next` | 跳过目录后第一个条目就是视频 | 只接受 `kind == .video` |
| `LibraryStore.thumbnail` / `cachedThumbnail` | 非目录就抽帧 | 只对视频抽帧，文档直接返回 nil |
| `displayTitle` / `subtitle` | 非目录就调用 `MediaTitleParser` | 文档使用去扩展名文件名、大小与时间 |
| `RootView` / `LibraryView` 诊断自动播放 | 第一个非目录条目 | 只选择视频 |
| `LibrarySearchResultsView` | 所有命中都用 `LibraryPoster` | 文档命中使用类型行与文档图标 |

### D2：目录分区规则与单 ScrollView 布局

Store 暴露三个派生集合：

```
hasVideos       = entries.contains { $0.kind == .video }
videoGridItems  = entries.filter { $0.kind == .directory || $0.kind == .video }
documentItems   = entries.filter { $0.kind.isDocument }
```

呈现规则：

```
有视频 + 有文档  ->  [文件夹 + 视频] 网格
                      [文档] 列表（网格下方）
无视频 + 有文档  ->  [文件夹行 + 文档行] 列表
有视频 + 无文档  ->  现有网格，行为不变
无视频 + 无文档  ->  现有空状态
```

实现上保持一个外层 `ScrollView`：混合目录用 `LazyVGrid` 渲染 `videoGridItems`，再用 `LazyVStack` 渲染文档行；纯文档目录直接用 `LazyVStack` 渲染文件夹行与文档行。避免在 `ScrollView` 内嵌 `List`，否则会出现双层滚动手势和高度不确定。

文档行使用 `NavigationLink` 推入当前 `NavigationStack`：紧凑宽度全屏推入，分栏宽度在右栏推入，左侧目录与正在播放的视频条保持可见。这样不需要新的弹层状态，也天然复用系统返回手势。

**替代方案**：视频/文档分段控件或独立文档页签。否决原因是用户已明确选择“目录内自动分区”，分段会隐藏内容并增加一次切换；把文档直接混进海报网格则会让 121 篇资料变成难以扫读的海报墙。

### D3：Markdown 用 WKWebView + 本地打包前端资源

数据流：

```
SMB ByteSource
  -> 整文件读取（<= 5 MB）
  -> UTF-8，失败回退 GB18030
  -> 组装本地 HTML 模板（marked + DOMPurify + highlight.js + CSS）
  -> WKWebView
  -> 渲染后 JS 后处理：表格包裹、代码语言标签/复制按钮、h1–h3 目录
```

**为什么不用 `AttributedString(markdown:)`**：Foundation 的 Markdown 解析不支持 GFM 表格，而当前语料有 110 个含表格的文件；代码块的横向滚动、语法高亮、复制按钮和目录也都需要额外的原生实现。

**为什么不用 Swift Markdown 库（MarkdownUI / cmark-gfm）**：项目不使用 SPM，vendor 一套 Swift 渲染库的构建与升级成本高于打包三个小型 JS/CSS 资源；WebView 方案把渲染复杂度隔离在模板内，Swift 侧只负责加载与消息桥。

**为什么不用 QuickLook**：Markdown 通常会按纯文本预览，得不到表格、代码高亮与目录。

具体约束：

- **资源**：`marked.min.js`、`purify.min.js`、`highlight.min.js`、`reader.css` 放在 `IceMovie/Resources/DocumentReader/`；`project.yml` 需要显式确认这些文件进入 Copy Bundle Resources。许可证随资源附 NOTICE。
- **HTML 注入**：Markdown 文本以 Base64 或 JSON 字符串注入模板，避免正文中的 `</script>` 破坏模板；JS/CSS 从 Bundle 读取后内联，`loadHTMLString` 不依赖本地文件 URL。
- **安全**：marked 产物先经 DOMPurify 清洗；内容中的 `<script>`、事件属性、`javascript:`/`file:` 链接被移除或阻止；CSP 只允许内联模板样式与脚本，`img-src` 只允许 `data:`，远程图片/字体/样式不会发起请求。
- **排版**：内容最大宽度约 760 pt，正文使用系统字体（含 PingFang SC 回退），代码使用 `ui-monospace`；表格与 `pre` 外层横向滚动；引用、标题、列表使用统一间距；深色模式通过 `prefers-color-scheme` 切换变量。
- **代码块**：`language-*` 映射到 highlight.js；`text`/未知语言不猜测高亮；代码块右上角显示语言标签与复制按钮，复制使用用户手势触发的 `navigator.clipboard`，失败时通过 `WKScriptMessageHandler` 回传提示。
- **目录**：渲染完成后 JS 遍历 `h1,h2,h3`，分配稳定 id，把层级/标题/id 列表通过消息桥交给 Swift；点击目录项调用 `scrollIntoView`。没有 h1–h3 时不显示目录按钮。
- **链接**：`WKNavigationDelegate` 只放行模板首次加载与文档内锚点；`http/https` 交给系统浏览器；其他 scheme 取消。阅读器本身不成为通用浏览器。
- **缓存**：`NSCache<NSString, NSString>` 缓存已生成的 HTML，key 为 `cacheNamespace + path + size + modified`，上限 16 MB；不落盘，源文件变化自然失效。

### D4：PDF 用 PDFKit 连续阅读，页面缩略图代替书签目录

- `PDFView` 通过 `UIViewRepresentable` 嵌入；`displayMode = .singlePageContinuous`、`displayDirection = .vertical`、`autoScales = true`、`pageShadowsEnabled = true`，页面宽度适配可用宽度。
- 读取仍走 `ByteSource` 整文件（<= 30 MB）；Data 在后台读取，`PDFDocument(data:)` 通过一个 `@unchecked Sendable` 的不可变包装交给主线程绑定，避免在 Swift 6 下跨 actor 传递非 Sendable 类型。
- 页码通过 `PDFViewPageChanged` 通知更新，覆盖在阅读器底部或导航栏副标题。
- 页面导航用缩略图 sheet：`PDFPage.thumbnail(of:for:)` 按需生成，`LazyVGrid` 展示，点击 `go(to:)`。现有 PDF 的 `outlineRoot` 为空，所以不把书签目录作为主路径；未来若 PDF 自带 outline，可作为额外入口。
- PDF 页面保持白底，阅读器背景跟随系统深浅色；不做反色，避免代码截图/语法颜色失真。
- PDF 全文搜索、批注、文本重排不在本轮范围。

### D5：文档读取走低优先级 SMB，错误分类明确

- `LibrarySource` 增加 `openDocumentByteSource(path:)`，默认转发到 `openSubtitleByteSource`；SMB 实现使用 `.subtitle` 优先级（低于 `.playback`，高于 `.enumeration`/`.thumbnail`），保证播放预读优先。
- 读取以 1 MB 分块，边读边累计；超过 Markdown 5 MB / PDF 30 MB 立即停止并返回 `.tooLarge`，不保留半截内容。
- 读取任务支持取消：关闭阅读器或返回时取消 Task 并 `close()` 字节源。
- Markdown 解码复用现有字幕解码逻辑（UTF-8 -> GB18030），提取为共享的文本解码工具，避免两份实现。
- 错误枚举覆盖：`tooLarge(format, limit)`、`readFailed`、`decodeFailed`、`renderFailed`、`invalidPDF`、`cancelled`；每种都有中文可读文案与重试入口。
- 日志记录格式、字节数、读取耗时、渲染耗时；便于后续定位“文档打开慢”是 SMB 还是渲染。

### D6：检索与导航的文档分支

- 文档进入 `currentEntries` 后会被 `LibrarySearchIndex` 自动索引（索引只读元数据，不读文件内容）。
- `displayTitle` 对文档返回去扩展名的文件名；`subtitle` 返回“`MD`/`PDF` · 大小 · 修改时间”。文档不调用 `MediaTitleParser`，避免把 `P01` 之类误解析成集号。
- 搜索结果仍是一个列表：视频命中保留 `reveal` 行为；文档命中直接推入阅读器，并在行内显示类型徽标与相对路径。
- 阅读器是 `NavigationStack` 的普通目的地，不新增全局弹层；目录切换时 `LibraryContentPage` 的 `.id(store.currentPath)` 会重置栈，阅读器自然关闭。

### D7：构建、资源与测试

- `project.yml` 增加/确认 `IceMovie/Resources/DocumentReader` 的资源构建阶段；XcodeGen 重新生成工程后检查 `.app` 内确实包含 JS/CSS。
- 单元测试重点：`MediaKind` 文档识别、`LibraryEntryBuilder` 可见性、分区集合、文档标题/副标题、`PlaybackQueue` 只选视频、读取上限与编码回退（用 stub `LibrarySource` / `ByteSource`）。
- WebView 的 JS 清洗与链接策略无法用 XCTest 完整覆盖，至少做一次模板级快照/字符串断言，并在模拟器做人工验收。
- 真机验收：iPad 分栏与 iPhone 紧凑、纯文档目录、混合目录、208 KB Markdown、29 页 PDF、深色模式、表格/代码横向滚动、外链、播放中打开文档、读取失败重试。

## Risks / Trade-offs

- **WKWebView 内存与进程开销**：同时只保留一个阅读器 WebView；退出即销毁；缓存只存 HTML 字符串，不缓存 WebView。文档打开不应与 4K 播放长时间并存时失控，需在真机观察内存。
- **大文档高亮延迟**：highlight.js 对数百个代码块可能增加首屏时间。先在首屏 HTML 渲染后异步高亮，必要时用 `IntersectionObserver` 只高亮可见代码块；以 208 KB 的最大文档为基准测量。
- **PDFKit 解析卡顿**：Data 读取在后台，`PDFDocument` 创建用不可变包装后回主线程；文件最大 3.19 MB，若真机仍出现明显卡顿，再改为后台创建 + 主线程只绑定视图。
- **SMB 读取与播放竞争**：文档读取使用 `.subtitle` 优先级和 1 MB 分块；播放中打开文档必须验证视频不卡顿、不跳转。若竞争明显，降级到 `.enumeration` 并为文档单独限速。
- **XcodeGen 资源遗漏**：`.js`/`.css` 可能不被自动识别为资源。通过显式 `buildPhase: resources` 或 `resources` 配置修正，并在构建产物中检查。
- **清洗规则误伤合法 HTML**：语料中有少量 `<br>`、`<details>`、`<summary>`。DOMPurify 允许这些安全标签，同时移除脚本与事件属性；用实际文档做回归。
- **滚动锚点与分区布局**：混合目录同时有网格和文档列表，`scrollPosition(id:)` 的锚点可能跨两个布局。需要把文档 id 也纳入锚点恢复测试，必要时为文档列表单独建立布局容器。
- **规范与测试漂移**：现有 `LibraryOrderingTests.testNonMediaItemsAreFilteredButDirectoriesRemain` 明确断言 md 被过滤，必须更新；`media-library` 的“非媒体条目处理”契约也随 delta 改变，避免代码与主 spec 不一致。
- **与 `startup-latency` 的文件重叠**：两者都改 `LibraryView` / `LibraryStore`。先完成或冻结 `startup-latency` 的播放准备路径，再叠加文档分支，减少合并冲突与回归面。

## Migration Plan

无数据迁移，也没有需要清理的持久化状态。

1. 先落模型与可见性：`MediaEntry.kind`、`MediaKind` 文档扩展名、`LibraryEntryBuilder`、排序/分区派生集合，并更新受影响的视频假设与单元测试。
2. 再落文档列表 UI：混合/纯文档两种布局、文档行、空状态、搜索命中分支。
3. 接 Markdown 阅读器：加载/解码、HTML 模板与本地资源、WebView 包装、目录/链接/复制、错误态。
4. 接 PDF 阅读器：Data 读取、PDFDocument 绑定、页码与缩略图。
5. 最后做并发与真机验收：播放中打开文档、208 KB Markdown、29 页 PDF、失败重试、深色模式、iPad/iPhone 布局。

回滚策略：停止把 Markdown/PDF 纳入 `MediaKind.isVisible` 即可让功能整体不可见；视频网格、播放、缩略图与搜索的视频行为不受影响，无持久化数据需要回滚。
