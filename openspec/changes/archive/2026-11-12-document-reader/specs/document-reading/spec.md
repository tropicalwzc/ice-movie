# Spec Delta

## Purpose

定义应用如何从当前数据源读取并在应用内呈现技术文档（Markdown 与 PDF），包括格式识别、大小与编码边界、Markdown 渲染与代码高亮、PDF 页面导航、链接策略和失败处理。

## ADDED Requirements

### Requirement: 文档格式识别

应用 SHALL 依据文件扩展名识别文档：`.md` 与 `.markdown` 为 Markdown，`.pdf` 为 PDF；其他扩展名 MUST NOT 作为文档打开。

#### Scenario: 识别 Markdown

- **WHEN** 用户打开一个 `.md` 或 `.markdown` 文件
- **THEN** 应用 SHALL 以 Markdown 阅读器打开，并渲染其内容

#### Scenario: 识别 PDF

- **WHEN** 用户打开一个 `.pdf` 文件
- **THEN** 应用 SHALL 以 PDF 阅读器打开，并展示第一页

#### Scenario: 其他扩展名

- **WHEN** 目录中出现 `.txt`、`.py`、`.torrent` 等非 Markdown/PDF 文件
- **THEN** 应用 MUST NOT 将其识别为可阅读文档

### Requirement: 文档整文件读取与大小上限

打开文档时，应用 SHALL 在渲染前取得完整文件内容；Markdown 超过 5 MB 或 PDF 超过 30 MB 时 MUST 拒绝打开并展示原因，不得展示截断内容。

#### Scenario: Markdown 在上限内

- **WHEN** Markdown 文件大小不超过 5 MB
- **THEN** 应用 SHALL 读取完整文件并渲染全部内容

#### Scenario: PDF 在上限内

- **WHEN** PDF 文件大小不超过 30 MB
- **THEN** 应用 SHALL 读取完整文件并打开阅读器

#### Scenario: 超过大小上限

- **WHEN** Markdown 超过 5 MB 或 PDF 超过 30 MB
- **THEN** 应用 MUST 拒绝打开，并展示文件过大与对应上限的说明

#### Scenario: 读取失败

- **WHEN** SMB 读取中断、文件被删除或权限不足
- **THEN** 应用 SHALL 展示失败原因与重试入口，不得崩溃或进入空白阅读器

### Requirement: Markdown 编码兼容

Markdown 文件 SHALL 优先按 UTF-8 解码；UTF-8 解码失败时 SHALL 尝试 GB18030；两种编码都失败时 MUST 展示解码错误，不得展示乱码。

#### Scenario: UTF-8 文档

- **WHEN** Markdown 文件使用 UTF-8 编码
- **THEN** 应用 SHALL 正确解码并渲染中文与代码内容

#### Scenario: GB18030 文档

- **WHEN** Markdown 文件不是有效 UTF-8，但可按 GB18030 解码
- **THEN** 应用 SHALL 使用 GB18030 解码并正常渲染

#### Scenario: 无法解码

- **WHEN** Markdown 文件既不能按 UTF-8 也不能按 GB18030 解码
- **THEN** 应用 MUST 展示解码失败提示，而不是乱码文本

### Requirement: Markdown 块级渲染

Markdown 阅读器 SHALL 渲染标题、段落、列表、引用、表格、分隔线与围栏代码块；表格和代码块在超出可用宽度时 SHALL 支持横向滚动，不得挤压或截断内容。

#### Scenario: 表格渲染

- **WHEN** 文档包含 GFM 表格
- **THEN** 应用 SHALL 渲染表头与数据行，并在窄屏上允许表格横向滚动

#### Scenario: 长代码行

- **WHEN** 代码块中的单行宽度超过阅读区域
- **THEN** 代码块 SHALL 保持原始换行与缩进，并提供横向滚动，不得截断代码

#### Scenario: 引用与列表

- **WHEN** 文档包含多级列表或引用块
- **THEN** 应用 SHALL 按层级呈现，并保持可读的缩进与间距

### Requirement: 代码块语法高亮与复制

带语言标记的围栏代码块 SHALL 进行语法高亮，至少覆盖 `cpp`、`swift`、`objc`、`bash`、`python`、`json`、`yaml`、`kotlin`、`javascript`、`sql` 与 `xml`；未标记或不支持的语言 SHALL 以等宽文本呈现；用户 SHALL 能复制代码块内容。

#### Scenario: 高亮常见语言

- **WHEN** 代码块标记为 `cpp`、`swift` 或 `objc`
- **THEN** 应用 SHALL 按对应语言进行语法高亮，并显示语言标识

#### Scenario: 未知语言

- **WHEN** 代码块没有语言标记，或语言不在支持列表内
- **THEN** 应用 SHALL 以等宽、保留缩进的方式呈现，不得错误高亮

#### Scenario: 复制代码

- **WHEN** 用户点击代码块的复制入口
- **THEN** 应用 SHALL 将代码块原始文本复制到系统剪贴板，并给出复制成功反馈

### Requirement: Markdown 目录

Markdown 阅读器 SHALL 从 h1–h3 标题生成目录；点击目录项 SHALL 滚动到对应标题；文档没有 h1–h3 时 MUST 隐藏目录入口。

#### Scenario: 显示目录

- **WHEN** 文档包含一个或多个 h1–h3 标题
- **THEN** 阅读器 SHALL 提供目录入口，并按标题层级展示条目

#### Scenario: 跳转到标题

- **WHEN** 用户点击目录中的某个标题
- **THEN** 阅读器 SHALL 滚动到该标题位置，并保持当前文档内容不变

#### Scenario: 没有标题

- **WHEN** 文档不含 h1–h3 标题
- **THEN** 阅读器 MUST 隐藏目录入口，不展示空目录

### Requirement: Markdown 链接处理

文档中的 `http` 与 `https` 链接 SHALL 交给系统浏览器打开；同一文档内的锚点链接 SHALL 在阅读器内滚动到对应位置；其他 scheme MUST NOT 被执行。

#### Scenario: 外部链接

- **WHEN** 用户点击 `http` 或 `https` 链接
- **THEN** 应用 SHALL 使用系统浏览器打开该链接，阅读器保持原文档

#### Scenario: 文档内锚点

- **WHEN** 用户点击指向本文档标题的锚点链接
- **THEN** 应用 SHALL 在阅读器内滚动到对应标题，不离开当前文档

#### Scenario: 危险 scheme

- **WHEN** 文档包含 `javascript:`、`file:` 或其他非 http/https/锚点链接
- **THEN** 应用 MUST NOT 执行或导航到该链接

### Requirement: Markdown 内容安全

渲染 Markdown 时，应用 SHALL 移除脚本、事件处理属性与危险 HTML；阅读器 MUST NOT 执行文档内脚本，也 MUST NOT 自动加载远程图片、字体或样式资源。

#### Scenario: 脚本与事件属性被移除

- **WHEN** Markdown 中嵌入 `<script>` 或 `onclick` 等事件属性
- **THEN** 渲染结果 SHALL 不包含可执行脚本或事件处理属性

#### Scenario: 远程图片不加载

- **WHEN** Markdown 引用远程图片 URL
- **THEN** 阅读器 MUST NOT 发起该图片请求，不得向外部地址泄露阅读行为

#### Scenario: 远程样式与字体不加载

- **WHEN** Markdown 引用远程 CSS 或字体资源
- **THEN** 阅读器 MUST NOT 加载这些资源，只使用本地内置样式与系统字体

### Requirement: PDF 连续阅读与页面导航

PDF 阅读器 SHALL 以连续纵向滚动呈现，页面宽度适配可用宽度；SHALL 显示当前页码与总页数；SHALL 提供页面缩略图导航，点击缩略图跳转到对应页。

#### Scenario: 打开 PDF

- **WHEN** 用户打开一个 20 页的 PDF
- **THEN** 阅读器 SHALL 展示第一页，并显示当前页码与总页数

#### Scenario: 滚动更新页码

- **WHEN** 用户在 PDF 中连续滚动到另一页
- **THEN** 页码指示 SHALL 更新为当前可见页

#### Scenario: 缩略图跳转

- **WHEN** 用户从页面缩略图中选择第 10 页
- **THEN** 阅读器 SHALL 跳转到第 10 页并关闭缩略图选择界面

#### Scenario: PDF 无法解析

- **WHEN** PDF 文件损坏或 PDFKit 无法建立文档
- **THEN** 应用 SHALL 展示打开失败原因与重试入口

### Requirement: 文档加载与失败处理

读取或渲染文档期间，应用 SHALL 展示加载态；失败时 SHALL 展示失败原因、重试入口与返回入口；重试 SHALL 重新读取并渲染完整文档。

#### Scenario: 加载中

- **WHEN** 文档正在从 SMB 读取或正在渲染
- **THEN** 应用 SHALL 展示明确的加载状态，不得先显示空白页面

#### Scenario: 渲染失败

- **WHEN** Markdown 渲染或 PDF 解析失败
- **THEN** 应用 SHALL 展示失败原因，并保留返回文档列表的入口

#### Scenario: 重试成功

- **WHEN** 用户在失败态点击重试且文件已恢复可读
- **THEN** 应用 SHALL 重新读取并渲染完整文档

### Requirement: 阅读位置不持久化

应用 MUST NOT 持久化文档阅读位置；关闭并重新打开同一文档时 SHALL 从文档开头展示。

#### Scenario: 重新打开 Markdown

- **WHEN** 用户阅读到 Markdown 文档中部后关闭，再次打开同一文档
- **THEN** 阅读器 SHALL 从文档开头展示

#### Scenario: 重新打开 PDF

- **WHEN** 用户阅读到 PDF 第 10 页后关闭，再次打开同一 PDF
- **THEN** 阅读器 SHALL 从第 1 页开始展示

### Requirement: 文档阅读不中断播放

当视频正在内联播放时打开文档，应用 SHALL 保持视频的播放、暂停、进度与字幕选择不变；读取文档不得导致播放卡顿、暂停或跳转。

#### Scenario: 播放中打开文档

- **WHEN** 视频正在内联播放，用户点击同一目录中的文档
- **THEN** 阅读器 SHALL 打开，视频 SHALL 继续播放，播放进度与字幕选择保持不变

#### Scenario: 关闭文档后继续播放

- **WHEN** 用户关闭文档阅读器返回目录
- **THEN** 视频 SHALL 仍处于打开文档前的播放状态与进度
