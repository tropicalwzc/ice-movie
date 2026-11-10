# Design

## Context

见 `proposal.md` 的 Why。当前链路的关键约束：

- `AVIOBridge` 固定 4MB 窗口，`SMBFileByteSource` 播放块 1MB + 512MB 环；读调度器单线程，AMSMB2 用一把全局锁串行化请求，实测链路约 3.25MB/s。
- `LibraryView.openPlayback` 在 `preparePlayback` 返回后才创建播放会话，播放页出现时间等于准备时间。
- `SubtitleLoader` 会为内封/外挂字幕各再开一次容器；`MediaReader.open(source:label:)` 未传 `fastProbe`，二次打开还会跑 `avformat_find_stream_info`。
- `PlaybackEngine` 起播要等 3 秒音频 + 2 秒视频；续播是 `play()` 之后才 `seek()`。
- 容器附件在 `avformat_open_input` 阶段被 FFmpeg 读入；≥800MB 的内封字幕路径已经把 `subtitleFonts` 清空，读到的字体实际未被使用。

## Goals / Non-Goals

**Goals:**

- 点击后 200ms 内出现播放页；准备时间不再等于用户等待时间。
- 首次打开只读解封装实际需要的字节；二次打开命中本地容器头缓存。
- 字体附件不进入起播读取路径，同时保留封面图附件。
- 起播水位按链路吞吐自适应，续播在起播前完成定位。
- 报告能区分“代码读取量”和“环境掉速”，避免再把 4~20 秒都归因于解码。

**Non-Goals:**

- 不改 SMB 读流水线、AMSMB2 全局锁或多连接读池。
- 不引入 AVPlayer 双引擎。
- 不做点按预热、下一集预加载。
- 不改缩略图生成与媒体库索引结构。
- 不做服务端/NAS 调优。

## Decisions

### D1. 播放页先出现，引擎后就绪

`openPlayback` 改为两段式：

```
click
  |
  +-> 立即创建 PendingPlayback（entry + 缩略图/封面 + 取消 token）
  |     播放页在 200ms 内 push，展示 poster + 加载态
  |
  +-> preparePlayback(entry, startAt:) 在独立任务里跑
         |
         +-> 成功：绑定 engine/renderer，移除加载态
         +-> 失败：播放页展示错误 + 返回按钮
         +-> 取消：关闭会话，停止后台读取
```

- 占位图直接复用网格单元格已经加载的缩略图缓存；没有缓存时用纯色 + 标题，不触发新的抽帧读取。
- 横屏请求从“准备完成后”提前到“播放页出现时”，把旋转动画和 I/O 重叠。
- `LibraryPlaybackSession` 拆出 `preparing` / `active` / `failed` 三态；只有 `active` 才启动进度、字幕、Now Playing。
- 备选：保持现状只加转圈。被否，因为用户等待的 4 秒里没有任何播放页反馈。

### D2. 字体附件：Swift 侧不读，FFmpeg 侧跳过负载

分两层：

1. **Swift 侧删除读取**
   - `SubtitleLoader.load` 不再调用 `reader.attachments()`，`LoadedSubtitles.fonts` 恒为空。
   - 删除 `containerFonts()`，外挂 ASS 不再为字体开第三次容器。
   - `LibassSubtitleRenderer` 继续先注册 `SubtitleFont.builtinCJK`，再用 `ass_set_fonts(..., "Noto Sans CJK SC", 2, ...)` 走 CoreText 兜底。
2. **FFmpeg 侧跳过字体负载**
   - 给 matroska demuxer 增加 `skip_font_attachments` AVOption（默认 0）。
   - 只在 `fastProbe` 的播放首开设为 1；`DemuxProbe`（缩略图/元数据）保持 0，避免影响封面图提取。
   - 仅对 `font/*`、`application/x-font-*`、`application/vnd.ms-opentype` 等字体 MIME 跳过 `FileData`；`image/*` 仍完整读取，保留封面图附件。
   - 跳过实现：`FileMimeType` 在 `FileData` 之前解析，把 MIME 存到 `MatroskaAttachment`；解析 `FileData` 时若命中字体 MIME，用 `avio_skip` 前进 `length`，把 `bin.size` 置 0，`matroska_parse_attachments` 对空 `bin` 静默跳过。
   - 通过 `Vendor/ffmpeg/patches/` 下的 patch 文件维护，`build.sh` 幂等应用后重新构建 device/simulator 静态库。

备选：
- 只删 Swift 侧读取：无法避免 `avformat_open_input` 读字体，收益不完整。
- 跳过全部附件：实现更简单，但会丢 MKV 封面图，违反 spec 的“封面图附件保留”。
- 保留字体但延迟到字幕渲染时再读：需要第二次 open，反而增加起播后的带宽竞争。

### D3. AVIO 窗口自适应 + 精确读

`AVIOBridge`：

- 新增 `minWindowSize = 64KB`、`maxWindowSize = 4MB`、`currentWindowSize`。
- `fastProbe` 从 64KB 起步；连续 4 次顺序填充后翻倍，直到 4MB；发生非连续 seek 时回退到 64KB。
- 单次请求大于当前窗口时，按 `max(request, currentWindow)` 读取，保证 FFmpeg 的大读不被拆碎。
- 记录 `fillCount`、`bytesRead`，供验收报告使用。

`SMBFileByteSource`：

- 新增“精确读”路径：`count < chunkSize` 时按请求区间发起 `pread`，不再对齐到 1MB 整块；结果放入一个有界的小区间缓存（默认 4 × 256KB），避免相邻小读重复走网络。
- `count >= chunkSize` 或预读仍走 1MB 块 + 512MB 环，保持播放吞吐。
- `seekWillChange` 不再淘汰“容器头区间”；头部/尾部区间由 D4 的持久缓存承接，内存环只负责播放窗口。

备选：
- 直接把 `chunkSize` 降到 64KB：会拖慢播放预读，Kodi 的实测也显示块太小会掉吞吐。
- 只改 AVIO 窗口不改 ByteSource：窗口降到 64KB 后仍会按 1MB 取，收益被吃掉。
- 打开阶段用独立 ByteSource：需要重复打开句柄，且无法复用已读区间，复杂度更高。

### D4. 容器头/尾持久缓存

新增 `ContainerHeaderCache`（`PersistenceKit`）：

- Key：`namespace(host|share) + path + size + mtime + 首 64KB 指纹`。指纹避免 mtime 秒级精度导致的误命中。
- 存储：按 64KB 页的稀疏文件 + 每种文件的页位图；页数据直接落盘，元数据（最后访问、页位图、总大小）放一个小索引。
- 写入范围：只在“打开阶段”写入，即从 `MediaReader.open` 开始到 `PlaybackEngine.play()` 之前；播放阶段的媒体数据不落盘。
- 读取：`CachedByteSource` 包在 `SMBFileByteSource` 外层，先查页缓存，未命中再走 SMB；命中页数计入报告。
- 上限：默认 512MB，按文件最近访问 LRU 淘汰；单文件默认最多缓存 64MB。
- 失效：size/mtime/首 64KB 指纹任一变化即失效；缓存目录不可写时静默回退网络读。

```
MediaReader
   |
   v
CachedByteSource ---> ContainerHeaderCache (disk, 64KB pages)
   |
   v
SMBFileByteSource ---> SMBReadScheduler ---> AMSMB2/libsmb2
```

备选：
- 只做内存 pinned header：重启后失效，无法解决“第二次打开仍慢”。
- 整文件缓存：占用太大，和播放窗口重复。
- 依赖系统文件缓存：SMB 客户端缓存不可控，换设备/重启即失效。

### D5. 字幕扫描异步 + 目录列表复用

- `preparePlayback` 返回内封轨 + 一个 `subtitleDiscoveryTask`；播放先用内封轨/默认轨开始。
- `LibraryStore` 在浏览目录时缓存**原始目录项**（过滤前），`discoverExternalSubtitles` 优先复用；只有 `- Sub` 等字幕子目录需要额外列举，且发生在后台。
- 合并规则：内封轨在前、外挂轨在后；按 `(source, language, title)` 去重；若用户已手选轨道，保留选择，不清空当前字幕。
- `SubtitleLoader` 的二次 open 只保留“读取内封字幕文本”这一条路径，并传 `fastProbe: true`。

备选：
- 继续串行 await：中位只省 0.4 秒，但 p90 能省 4.6 秒、最大 15.8 秒；且它发生在起播前，收益被放大。
- 完全去掉外挂字幕：不可接受。

### D6. 续播先定位再起播

- `preparePlayback(_ entry, startAt: Double?)`：打开 reader 后、返回前调用 `engine.prepareSeek(to:)`，完成 demuxer seek + 音频裁剪 + 视频关键帧预滚。
- `PlaybackEngine` 新增 `prepareSeek(to:)`：只重置读头和预滚，不启动时钟；`play()` 直接从此位置启动。
- `LibraryView` 把 `resume` 传入 prepare；`play()` 之后不再调用 `seek(to: resume)`。
- seek 失败时记录日志并回退到 0，界面提示“续播定位失败，已从头播放”。

备选：
- 保持 play 后 seek：会先读 0 秒附近数据再丢弃，慢链路上浪费 1~3 秒。

### D7. 起播水位自适应

`PlaybackEngine` 水位分两档：

| 阶段 | 音频 | 视频 | 触发 |
|---|---|---|---|
| 起播 | ≤300ms | 1 帧 | 首帧解码完成 |
| 稳态 | 15s | 15s | 起播后 2s |

- 吞吐估计：`SMBFileByteSource` 的 2.5 秒窗口 + 打开阶段平均读取速度；与 `byteLength/duration` 估算的码率比较。
- `throughput < 1.5 × bitrate` 时使用保守档（音频 2s、视频 1s），并允许显示缓冲状态。
- 起播后 2 秒切到稳态档；若期间出现欠载，回退保守档 5 秒再尝试提升。
- 备选：固定 3s/2s。被否，慢链路上 4K 内容光垫预滚就要 2~5 秒。

### D8. 可观测字段

`PreparedPlayback` / 验收报告新增：

- `playerPresentedMilliseconds`：点击到播放页出现。
- `openBytesRead`、`openReadCount`、`avioFillCount`。
- `attachmentBytes`、`attachmentFontBytes`、`skippedFontCount`。
- `headerCacheHitBytes`、`headerCacheHitRatio`。
- `subtitleScanMilliseconds`（起播后）。
- `startupPrerollMode`（fast / conservative）、`startupBufferStalls`（起播后 30 秒）。

这些字段只用于诊断，不改变用户界面。

## Risks / Trade-offs

- **小窗口增加往返次数** → 连续读时翻倍增长；窗口上限 4MB；慢链路用保守预滚兜底。
- **精确读打散预读环** → 小读不进 1MB 环，单独小区间缓存；播放预读保持 1MB 块。
- **字体替换导致 ASS 排版偏移** → 产品已接受；保留内置 CJK + CoreText；报告记录忽略的字体数量，便于回滚。
- **FFmpeg patch 维护成本** → patch 文件 + `build.sh` 幂等应用；新增 matroska 附件回归样本（含字体 + 封面图）。
- **缓存误命中旧文件** → size + mtime + 首 64KB 指纹三重校验；失效时删除该文件的页。
- **缓存占满磁盘** → 512MB 上限 + LRU + 单文件 64MB 上限；缓存不可写时静默回退。
- **播放页先出现但打开失败** → 明确错误态 + 返回；不残留后台读取任务。
- **续播先 seek 失败** → 回退 0 秒并提示；不阻塞播放。
- **起播水位过低导致开头欠载** → 吞吐门限 + 保守档 + 起播后 30 秒缓冲次数验收（≤1 次）。

## Migration Plan

1. 先落 D8 观测字段和 D1/D5/D6（不改读取层），用 20 条样本确认感知与串行收益。
2. 再落 D3/D4（读取层），用 A/B 开关 `-startupFastPath 0/1`、`-containerHeaderCache 0/1` 对比读取字节与 prepare 时间。
3. 最后落 D2 的 FFmpeg patch 与 D7 的自适应预滚，跑完整 78 条随机样本 + 2 小时长跑。
4. 回滚：关闭上述启动参数即可回到旧行为；容器头缓存目录可整体删除；FFmpeg patch 回滚后重新构建静态库。

## Open Questions

- 容器头缓存的单文件上限（默认 64MB）和全局上限（默认 512MB）是否需要按设备存储调整，留到 P2 实测后定。
- 是否保留 `-useContainerFonts 1` 作为调试开关，留到实现时决定；不影响 spec 与任务拆分。
