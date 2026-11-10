# Proposal

## Why

2 小时 78 条真机样本显示，点击到首帧的中位数是 4.19 秒、p90 是 27.8 秒，86% 的样本超过 1.5 秒的规格。拆解后 84% 的准备时间花在容器打开与流信息探测上，而播放器界面要等准备全部完成才出现，用户在这几秒里只能看着媒体库网格转圈。

根因不在解码：引擎创建中位 17 毫秒，播放开始后出帧中位 37 毫秒。真正的浪费是读取方式——FFmpeg 只为解析几十 KB 元数据，`AVIOBridge` 也会固定预读 4MB，再被 `SMBFileByteSource` 放大成 4 次串行 1MB 读；实测链路只有约 3.25MB/s，一次窗口填充就是 1.2 秒。字幕扫描、固定 3 秒音频预滚、续播先从头播再 seek，又把本可并行的等待串到了关键路径上。

同时，容器内嵌字体在打开时被完整读入，但 ≥800MB 的内封字幕路径已经把 `subtitleFonts` 清空，实际渲染用的是内置/系统字体。这部分读取是纯浪费，也让起播时间无谓地受字体附件大小影响。

## What Changes

- **播放页即时呈现**：点击后立即进入播放页，用条目缩略图或封面作为占位并显示加载态；容器就绪后再绑定渲染层，不再等 `preparePlayback` 完成才创建播放会话。
- **字体不再进入起播读取路径**：移除 `SubtitleLoader` 对 `attachments()` 和 `containerFonts()` 的二次打开；容器附件字体统一忽略，使用内置中文字体与 CoreText 系统字体兜底；**BREAKING**（视觉行为）：ASS 指定字体不再按原发布渲染。
- **跳过字体附件负载**：给 vendored FFmpeg 的 matroska demuxer 增加 `skip_font_attachments` 选项，只跳过 `font/*` 附件，保留 `image/*` 封面图，避免解析 Tracks 时把数 MB 字体读进内存。
- **读取不再放大**：`AVIOBridge` 从固定 4MB 改为自适应窗口（打开阶段 64–256KB，连续顺序读后增长，最大 4MB）；`SMBFileByteSource` 对小读只取请求区间，不再按 1MB 整块放大；固定保留容器头区间，避免 MP4 `moov` 在尾部时来回 seek 重读。
- **容器头/尾持久缓存**：按路径、大小、修改时间缓存打开阶段实际读过的字节区间，二次打开优先命中本地磁盘，源文件变化后失效。
- **字幕扫描移出关键路径**：内封轨先可用，外挂字幕在后台扫描完成后合并进轨道列表，不阻塞起播，也不清空用户已选轨道。
- **续播先定位再起播**：打开时在返回播放会话前 seek 到续播关键帧，不再先从头播放再跳转。
- **起播水位自适应**：首帧可用即以“1 帧视频 + ≤300ms 音频”起播，再提升到稳态水位；实测吞吐低于码率 1.5 倍时回退到保守水位，避免慢链路开头欠载。
- **起播可观测**：验收报告新增打开阶段实际读取字节、AVIO 填充次数、字体附件字节、容器头缓存命中与各阶段耗时，供后续定位环境掉速与代码成本。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `video-playback`: 修改「首帧呈现」（点击即进入播放页、占位与可取消加载、首帧预算按首次/缓存命中区分）与「续播进度」（起播前定位到续播位置，不得先从头播放再跳转）。
- `subtitle-rendering`: 修改「字体回退」（忽略容器附件字体，统一使用内置/系统字体）与「字幕轨的发现与合并」（外挂字幕异步扫描、后合并，不阻塞起播）。
- `smb-read-cache`: 新增「首开只读所需字节」与「容器头区持久缓存」两项要求。
- `playback-supply`: 新增「起播水位自适应」要求。

## Impact

- 播放与解封装：`IceMovie/Core/DemuxKit/AVIOBridge.swift`、`MediaReader.swift`、`IceMovie/Core/SMBSession/SMBFileByteSource.swift`、`SMBChunkRing.swift`、`IceMovie/Core/RenderKit/PlaybackEngine.swift`。
- 播放页与媒体库：`IceMovie/Feature/Library/LibraryView.swift`、`LibraryStore.swift`、`IceMovie/Feature/Player/PlayerScreen.swift`。
- 字幕：`IceMovie/Feature/Library/SubtitleLoader.swift`、`IceMovie/Core/SubtitleKit/LibassSubtitleRenderer.swift`。
- 持久化：`IceMovie/Core/PersistenceKit/PersistenceKit.swift`（新增容器头缓存索引与淘汰）。
- 依赖与构建：`Vendor/ffmpeg/ffmpeg-src`（matroska demuxer 小 patch）与 `Vendor/ffmpeg/build.sh` 重新构建 device/simulator 静态库。
- 验收：`docs/acceptance-*.md/json` 的报告字段与 `Scripts` 下的验收脚本。
- 测试：`IceMovieTests` 新增窗口自适应、二打开缓存、续播定位、预滚回退的单元测试；真机复测 2 小时随机样本。

**Out of scope**：SMB 读流水线 / AMSMB2 全局锁改造、多连接读池、MP4 走 AVPlayer 双引擎、点按预热与下一集预加载、缩略图生成流程、服务端/NAS 调优。
