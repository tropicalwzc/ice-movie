# Tasks

## 1. 条目模型与目录分区

- [x] 1.1 增加 `MediaEntryKind` 与 `DocumentFormat`，扩展 `MediaKind.documentExtensions`，让 `MediaEntry.kind`、`isDocument`、`isVisible` 识别 `.md`/`.markdown`/`.pdf`；验证：新增 `MediaKindTests`，覆盖 Markdown、PDF、视频、目录、`.txt`、`.py`、`.torrent`、字幕扩展名，测试通过。
- [x] 1.2 抽出 `LibraryContentSectioning` 纯逻辑，输出 `hasVideos`、`videoGridItems`、`documentItems` 与呈现模式（混合 / 纯文档 / 视频网格 / 空）；验证：单元测试覆盖四种组合，断言目录在纯文档模式进入列表、在混合模式留在网格。
- [x] 1.3 更新 `LibraryEntryBuilder` 与 `MediaOrdering`：文档纳入条目，文档按文件名自然排序，视频仍按集号排序；验证：更新 `LibraryOrderingTests`，断言 md/pdf 可见、`.txt`/`.ass`/`.torrent` 不可见，第 2 篇排在第 10 篇之前。
- [x] 1.4 增加文档展示元数据：去扩展名标题、`MD`/`PDF` 类型、大小与修改时间，文档不调用 `MediaTitleParser`；验证：`DocumentMetadataTests` 覆盖中文文件名、同名 md/pdf 与带数字文件名，断言不会解析出集号。

## 2. 播放、缩略图与诊断隔离

- [x] 2.1 修改 `PlaybackQueue.next`，只返回 `kind == .video` 的条目；验证：`PlaybackQueueTests` 覆盖“视频后接 Markdown/PDF”时返回 nil 或下一个视频，绝不返回文档。
- [x] 2.2 在 `LibraryStore.thumbnail` 与 `cachedThumbnail` 中只对视频抽帧，文档直接返回 nil；验证：用 stub `LibrarySource` 断言打开文档列表不触发缩略图 provider。
- [x] 2.3 修正诊断自动播放与 `-libraryOpenFirst` 的“第一个非目录条目”逻辑，只选择视频；验证：抽出可测试的选择函数并覆盖“目录里先出现文档、后出现视频”的顺序，或按启动参数手测日志确认跳过了文档。
- [x] 2.4 更新受影响的既有测试与断言（特别是原“非媒体文件被过滤”的用例）；验证：`xcodebuild ... -scheme IceMovieTests test` 全量通过。

## 3. 媒体库分区与文档列表

- [x] 3.1 改造 `LibraryGridView` 支持混合模式：文件夹与视频保持网格，文档在网格下方用 `LazyVStack` 呈现；验证：本地 fixture 混合目录在模拟器显示两段，视频网格的列数、封面与滚动不受影响。
- [x] 3.2 支持纯文档模式：文件夹行与文档行在同一列表中，文件夹位于文档之前；验证：纯文档 fixture 只显示列表，不出现空网格或“没有视频”的空状态。
- [x] 3.3 新增 `DocumentRow`：文档图标、`MD`/`PDF` 徽标、标题、大小、修改时间、chevron、VoiceOver 标签，`NavigationLink` 指向 `DocumentReaderView` 占位壳（加载态/错误态/返回）；验证：点击行进入占位阅读器并可返回，VoiceOver 能读出标题与类型。
- [x] 3.4 更新空状态、导航标题与工具栏文案：空目录显示“没有可浏览的内容”，纯文档目录显示文档数量或类型摘要；验证：空目录、纯文档目录、混合目录三种 fixture 的界面文案正确。
- [x] 3.5 校验分区布局下的滚动锚点：进入子目录再返回、旋转设备、iPad 分栏/紧凑切换后，网格与文档列表位置保持有效；验证：模拟器逐项手测并记录，必要时为文档列表增加独立的锚点映射。

## 4. Markdown 阅读器

- [x] 4.1 给 `LibrarySource` 增加 `openDocumentByteSource(path:)`（默认转发字幕字节源），实现分块 `readAll`、取消与关闭；验证：用 stub `ByteSource` 测试正常读取、取消与关闭调用。
- [x] 4.2 增加文档大小上限：Markdown 5 MB、PDF 30 MB，超限立即停止读取并返回 `.tooLarge`；验证：`DocumentLoaderTests` 覆盖刚好等于上限、超过 1 字节与读取中途失败。
- [x] 4.3 抽出共享文本解码工具，Markdown 优先 UTF-8、失败回退 GB18030；验证：用 UTF-8 中文、GB18030 中文与随机二进制三组样本测试，最后一组返回 `.decodeFailed`。
- [x] 4.4 加入 `IceMovie/Resources/DocumentReader/` 资源（marked、DOMPurify、highlight.js、CSS、NOTICE）并实现 HTML 模板组装；验证：构建产物中存在全部资源，模板字符串测试能生成包含表格与代码块的 HTML。
- [x] 4.5 实现 `MarkdownReaderView` 的 WKWebView 包装、加载态、错误态与 `WKNavigationDelegate` 外链拦截；验证：模拟器打开含外链的文档，http/https 进入系统浏览器，阅读器不整页跳走。
- [x] 4.6 实现代码块语言标签、语法高亮与复制按钮；未标记或 `text` 代码块按等宽纯文本呈现；验证：用 cpp/swift/objc/text 四组代码块检查高亮差异，点击复制后剪贴板内容与原文一致。
- [x] 4.7 实现 h1–h3 目录：JS 分配标题 id 并通过消息桥回传，Swift 目录 sheet 点击后滚动到标题；无 h1–h3 时隐藏入口；验证：用 `iOS面试-P0P1核心.md` 样本与无标题样本各测一次。
- [x] 4.8 接入 DOMPurify 清洗与 CSP：脚本、事件属性、`javascript:`/`file:` 链接被移除，远程图片/字体/样式不发起请求；验证：用含 `<script>`、`onclick`、远程图片的 fixture 检查 DOM 与网络日志。
- [x] 4.9 增加会话内 HTML 缓存（key 含 namespace/path/size/modified，上限 16 MB）；验证：同一文档第二次打开不产生新的 SMB 读取日志，源文件修改后缓存失效。
- [x] 4.10 在 README 增加 Markdown 阅读器章节：支持范围、5 MB 上限、代码/表格/目录、外链与安全策略、不记录阅读位置；验证：按文档描述逐项操作，行为与文字一致。

## 5. PDF 阅读器

- [x] 5.1 实现 PDF 加载：整文件读取、30 MB 上限、`PDFDocument(data:)` 的 Sendable 包装与错误分类（`.invalidPDF`/`.readFailed`）；验证：用 29 页样本、损坏 PDF、超过上限的构造数据测试，分别得到成功、`.invalidPDF`、`.tooLarge`。
- [x] 5.2 实现 `PDFReaderView`：`PDFView` 连续纵向滚动、页面宽度适配、页码/总页数指示；验证：打开 20 页样本显示第 1 页，滚动到中间页码更新。
- [x] 5.3 实现页面缩略图 sheet：按需生成缩略图，点击跳转到对应页并关闭 sheet；验证：从 20 页样本选择第 10 页后视图定位正确。
- [x] 5.4 增加 PDF 失败态、重试与退出清理；验证：损坏 PDF 显示错误与重试，关闭阅读器后 `PDFDocument`/`PDFView` 不继续持有大对象（用内存日志或 Instruments 检查）。
- [x] 5.5 在 README 增加 PDF 阅读器章节：30 MB 上限、连续滚动、页码与缩略图、不依赖书签目录、不做全文搜索；验证：按文档描述逐项操作，行为与文字一致。

## 6. 搜索、导航与并发

- [x] 6.1 确认 `LibrarySearchIndex` 自动索引文档元数据，搜索 `swift` 同时命中 `swift.md`、`swift.pdf` 与视频；验证：模拟器本地库搜索并断言结果包含三种类型。
- [x] 6.2 更新 `LibrarySearchResultsView`：文档结果显示类型徽标与相对路径，点击直接打开阅读器；视频结果保持 `reveal` 定位；验证：分别点击文档与视频命中，行为符合 spec。
- [x] 6.3 校验阅读器导航：紧凑宽度全屏推入，分栏宽度在右栏推入，左侧目录与正在播放的视频条保持可见；验证：iPhone 与 iPad 分栏各走一遍进入/返回。
- [x] 6.4 校验播放中打开文档：视频内联播放时打开 Markdown 与 PDF，视频不暂停、不跳转、字幕选择不变；验证：记录打开前后的播放进度与日志中的 SMB 读取优先级。
- [x] 6.5 校验不持久化阅读位置：Markdown 滚到中部、PDF 翻到第 10 页后关闭，再次打开均回到开头/第 1 页；验证：模拟器连续操作两次并记录。
- [x] 6.6 在 README 增加检索、导航与并发说明；验证：按文档描述操作搜索结果、分栏阅读与播放中打开文档，行为一致。

## 7. 构建、回归与真机验收

- [x] 7.1 更新 `project.yml`，确保 `IceMovie/Resources/DocumentReader/` 进入 Copy Bundle Resources，并附第三方许可证 NOTICE；验证：`xcodegen generate` 成功，构建后的 `.app` 中存在 JS/CSS/NOTICE。
- [x] 7.2 运行完整单元测试与模拟器构建；验证：`IceMovieTests` 全量通过，`xcodebuild ... build` 无错误。
- [x] 7.3 增加文档阅读 UI 冒烟测试：文档行进入阅读器、返回、目录/页面按钮可见；验证：`IceMovieUITests` 中新增用例通过。
- [x] 7.4 在真实 SMB 共享 `pythonworkspace/面试知识库` 上验收：121 个 Markdown 抽样、8 个 PDF、混合与纯文档目录、208 KB 长文、29 页 PDF、深色模式、表格/代码横向滚动、外链、失败重试、播放中打开文档；验证：逐项记录结果到 `docs/` 下的验收记录，未通过项有明确说明。
- [x] 7.5 检查与 `startup-latency` 的合并结果：媒体库分区、文档阅读不改变播放准备耗时与起播路径；验证：对比合并前后的启动/播放回归数据，确认无回退。

## Workflow follow-up

- 完成实现与验收后，按项目评审要求归档 `document-reader` change。
- 归档前确认 `media-library` 主 spec 的 Purpose 与新增文档行为一致，必要时另行更新 Purpose。
