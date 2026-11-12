# Proposal

## Why

SMB 共享里除了视频，还有大量技术资料：`pythonworkspace/面试知识库` 中有 121 个 Markdown 文件和 8 个 PDF，Markdown 里包含 110 个含表格的文件和数百个代码块。当前媒体库按扩展名只识别 8 种视频容器，这些文档在目录列举阶段就被丢弃，用户只能切到电脑或其他应用阅读，和正在浏览的媒体库完全割裂。

现在支持的时机已经成熟：文档都很小（Markdown 最大 208 KB，PDF 最大 3.19 MB），现有 SMB 字节源、导航栈和共享切换都可以直接复用；渲染侧不需要新增网络依赖，Markdown 用本地打包的 Web 渲染器、PDF 用系统 PDFKit 即可覆盖。

## What Changes

- **文档进入媒体库**：`MediaEntry` 增加明确的条目类型（目录 / 视频 / Markdown / PDF），目录列举不再只保留视频；其他非文档文件（字幕、种子、脚本、隐藏配置等）仍然不展示。
- **目录自动分区**：有视频的目录保持“文件夹 + 视频”网格，并在网格下方增加文档列表；没有视频、只有文档的目录改为统一列表（文件夹行 + 文档行），不再画 2:3 海报墙。
- **文档列表**：Markdown 与 PDF 混排，按文件名自然排序；每行显示去扩展名标题、`MD`/`PDF` 类型徽标、大小与修改时间；文档不参与缩略图抽帧，也不走视频标题解析。
- **Markdown 阅读器**：使用 WKWebView + 本地打包的 marked、DOMPurify、highlight.js，支持 GFM 表格、代码块语法高亮、代码复制、h1–h3 目录、外链交给系统浏览器；整文件读取上限 5 MB，UTF-8 失败时回退 GB18030。
- **PDF 阅读器**：使用 PDFKit 连续纵向滚动，显示页码，提供页面缩略图导航；整文件读取上限 30 MB；不依赖 PDF 书签目录（现有 PDF 的 `outlineRoot` 为空）。
- **检索覆盖文档**：文件名检索包含 Markdown 与 PDF，命中后直接打开阅读器；视频命中仍保持“定位到所在目录”的现有行为。
- **播放链路隔离**：自动下一集、缩略图生成、诊断自动播放等只选择视频条目，文档不得进入播放队列或被当作视频打开。
- **不持久化阅读位置**：本轮不记录滚动位置、不建书架、不做阅读进度；文档打开失败时提供明确错误与重试。

**BREAKING**（行为契约）：`media-library` 原先规定“非媒体文件默认不出现在网格中”，现在 Markdown 与 PDF 会以文档列表形式出现；其余非文档文件仍保持隐藏。

## Capabilities

### New Capabilities

- `document-reading`: 定义文档从 SMB 读取、解码、渲染与导航的行为，包括 Markdown 的 GFM 渲染/代码高亮/目录/外链处理，以及 PDF 的连续滚动与页面导航、大小限制和错误态。

### Modified Capabilities

- `media-library`: 条目识别从“视频 + 目录”扩展为“视频 + 目录 + 文档”；新增目录分区与纯文档列表；检索结果包含文档并支持直接打开；非文档文件继续保持隐藏。

## Impact

- 媒体库模型与排序：`IceMovie/Feature/LibraryKit/MediaEntry.swift`、`LibraryLoader.swift`、`MediaTitle.swift`、`LibrarySearchIndex.swift`、`PlaybackQueue.swift`。
- 媒体库界面与状态：`IceMovie/Feature/Library/LibraryStore.swift`、`LibraryGridView.swift`、`LibraryCell.swift`、`LibrarySearchResultsView.swift`、`LibraryView.swift`、`LibrarySidebar.swift`。
- 新增文档阅读层：`IceMovie/Feature/Document/`（文档加载、Markdown WebView、PDFKit 阅读器、目录/页面导航）。
- 本地资源与构建：`IceMovie/Resources/DocumentReader/`（marked、DOMPurify、highlight.js、CSS），`project.yml` 需确认 Web 资源进入 Copy Bundle Resources。
- 测试：`IceMovieTests` 需更新“非媒体文件被过滤”的既有断言，并新增文档类型识别、分区规则、读取上限与编码回退、搜索结果打开的测试。
- 性能与并发：文档读取使用低优先级 SMB 读取，避免与播放预读竞争；Markdown 渲染在会话内缓存，PDF 解析放在主线程之外完成后再绑定 PDFView。
- 与进行中的 `startup-latency` 存在文件重叠（`LibraryView.swift`、`LibraryStore.swift`），逻辑不冲突，但合并时需要注意。
- **Out of scope**：阅读位置持久化、书架/分页阅读、PDF 全文搜索与批注、Markdown 图片与相对链接、全文检索、Markdown/PDF 编辑、`.txt` 等其他文本格式、PDF 导出。
