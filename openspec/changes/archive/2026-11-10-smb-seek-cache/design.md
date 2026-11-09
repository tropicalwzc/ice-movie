# Design

## Context

当前 `SMBFileByteSource` 用单个 `lastReadEnd` 同时承担缓冲区测量锚点、预读续读锚点和 seek 检测锚点，并且用 `max` 只增不减。回退 seek 后锚点仍停在旧的前方位置，后续每次读取都会被判成再次回退，触发 `ring.reset()` 和预读重启；`bufferedAheadBytes` 又从解封装读头往后算，漏掉播放头与读头之间已读、已解码的数据，所以 18GB 4K 上绿色区间长期只有约 1 秒。

对照 mpv 与 ExoPlayer：

- mpv 的 demuxer cache 以 `reader_head`（播放消费点）为基准统计前向缓存，默认前向 150MB、回看 50MB；seek 先查 `demux_cached_range`，命中则直接移动 `reader_head`，未命中才切到新的 cache range。
- ExoPlayer 默认缓冲 50 秒，磁盘缓存按 LRU span 淘汰；seek 只重置 sample queue，不清空缓存。
- 两者都不把「解封装读头」当作播放缓冲的起点。

本次设计只解决读窗口与 seek 缓存语义，不改变解码器架构。

## Goals / Non-Goals

**Goals:**

- 显式区分播放头、解封装读头和预读最远点，消除回退 seek 后反复重置预读。
- 进度条缓冲区间从播放头计算，包含解封装已读但未播放的数据。
- seek 优先复用连续缓存；未命中时只丢弃前向窗口，保留有界回看。
- 预读从解封装读头继续向前，不追已经读过的区间。
- 用验收指标证明 seek 命中、首帧和缓冲次数改善。

**Non-Goals:**

- 不把视频解码从播放泵拆到独立线程；4K HDR 音频饥饿作为单独问题处理。
- 不新增磁盘缓存，不改变约 512MB 的内存预算。
- 不实现跨文件/跨会话缓存，不改变 SMB 连接与调度器架构。
- 不修改字幕加载与渲染路径。

## Decisions

### D1 三个头替代单个 `lastReadEnd`

引入读窗口状态：

```
windowStart     playhead        readHead        prefetchHead
    |               |               |                 |
    v               v               v                 v
----+===============+===============+=================+----> 文件字节
    |<-- 回看窗口 -->|<-- 已读/已解码 -->|<-- 预读环 -->|
```

- `playhead`：当前播放位置对应的估算字节偏移。
- `readHead`：解封装器已经消费到的字节偏移。
- `prefetchHead`：连续预读到达的最远字节偏移。
- `windowStart`：回看窗口起点，由回看预算决定。

`bufferedAheadBytes = prefetchHead - playhead`，仅在 `[playhead, prefetchHead]` 连续时成立；出现缺口时以缺口前的连续段为准。

替代方案是继续修补 `lastReadEnd` 的判断条件，但三个语义耦合在一个变量里，任何 seek 分支都会互相污染，否决。

### D2 缓冲区间从播放头计算

`PlaybackEngine` 已知道播放时间、总时长和文件大小，用 `currentTime / duration * byteLength` 估算播放字节偏移。该估算只用于显示和 seek 命中判断的粗定位，不参与实际读取偏移。

- 正常播放：缓冲秒数 = `(prefetchHead - playheadByte) / 平均码率`，再与已解码音视频队列取较大值，避免低估。
- 播放头进入已解码区间时，以已解码队列的 PTS 领先量为准，防止码率波动导致绿色区间跳动。
- VBR 文件的字节估算有误差，但只影响显示平滑度；真正的 seek 仍由解封装时间戳决定。

### D3 seek 先判命中，再决定窗口操作

`seekWillChange` 不再无条件 reset，按目标位置分三类：

1. **命中连续缓存**：目标落在 `[windowStart, prefetchHead]` 且该区间连续。
   - 只移动 `playhead` 和 `readHead` 到目标。
   - 不清空预读环、不取消预读任务、不重启 generation。
   - 若目标之后仍有连续预读，直接复用。
2. **命中回看窗口但目标之后未缓存**：目标在 `[windowStart, readHead]`，但 `readHead` 之后没有连续预读。
   - 保留目标附近的重叠段，移动播放头。
   - 从 `readHead` 重新向前预读，不从头读目标。
3. **完全未命中**：目标在窗口外。
   - 丢弃前向窗口，保留有界回看段（若目标靠近回看边缘）。
   - 记录新的 `windowStart = target - backBudget`、`playhead = readHead = prefetchHead = target`。
   - 先读取目标位置第一块，再从 `readHead` 向前预读。

`SMBChunkRing` 增加按区间查询与裁剪能力：

- 查询 `[offset, offset + length]` 是否连续。
- 查询目标之后连续缓存的末尾。
- 按 `[keepStart, keepEnd]` 裁剪，而不是只按 `before` 裁剪。
- 容量不足时按「离播放头的距离」淘汰，优先保留回看窗口和最近的前向窗口。

### D4 预读锚点跟随读头

预读任务从 `max(readHead, target)` 开始，而不是从 seek 目标开始。seek 后首次读取负责取目标位置第一块，随后 `schedulePrefetch(after:)` 从本次读末尾向前填。

- 旧预读任务继续用 generation 隔离；generation 变化后，即使 SMB 读取晚返回也不得写入。
- 预读任务不再因为每次读取都重启；只有窗口重置或预读任务自然结束才启动新任务。
- 保留约 8 个块的余量，避免预读把当前读位置的块挤掉。

### D5 回看窗口与淘汰预算

- 回看窗口默认 20 秒，按平均码率换算字节；上限不超过 64MB，避免高码率 4K 把回看段撑得过大。
- 回看数据只用于播放头之后的邻近 seek，不参与向前预读容量。
- 淘汰顺序：先丢离播放头最远的回看数据，再丢前向窗口中超出容量的远端数据；不按全局最小偏移淘汰。
- 保留现有 512MB 预读环总预算；回看段从前向容量中借用，不额外增加内存。

### D6 seek 验收指标

在现有 `ice-acceptance.json` 中增加或复用：

- `seekCacheHit`：本次 seek 是否命中连续缓存。
- `bufferedAheadSeconds`：从播放头起算的连续可用秒数。
- `lastSeekLatencyMilliseconds`、`firstVideoMilliseconds`、`bufferStalls`。
- `ringResetCount`：本次播放会话中预读环被重置的次数，用于确认连续反向跳转没有反复 reset。

### D7 视频包处理与音频供给解耦

`SampleBufferBuilder` 只把压缩包封装成 `CMSampleBuffer`，不做软件解码；但播放泵在 4K HDR 上仍会把大量时间花在视频包的复制、封装和主线程投递上，音频包被夹在中间，音频队列长期只有 0.6–1.0 秒。解决方式：

- 新增 `VideoPacketPipeline`：独立串行工作线程 + 有界 AVPacket 队列。
- 播放泵遇到视频包时，用 `av_packet_move_ref` 把所有权交给队列，不在泵上创建 sample。
- 工作线程负责 `SampleBufferBuilder.makeSample` 和 `VideoRenderer.enqueue`；音频解码、字幕包处理仍留在播放泵。
- 队列上限按包数和字节数双重限制（默认 64 包 / 64MB）；满时优先丢最老的非关键帧，并计数；只有关键帧时丢最老包并通知显示层等待下一个关键帧。
- seek 时 `flush()` 清空队列、generation 加一；工作线程只处理当前 generation 的包，旧包直接释放，避免 seek 后旧帧串入新画面。
- `enqueueVideo` 的 seek 统计字段用现有 `lock` 保护，音频/字幕路径不变。
- 播放头字节位置改为记录最近音频包的 `pos/pts`，用 `pos + (clock - pts) * 平均码率` 估算；没有音频时用视频包 `pos/pts`。这修正 VBR 文件上绿色区间长期为 0–1 秒的问题。

替代方案是引入 VTDecompressionSession 自建视频解码线程，但 `AVSampleBufferDisplayLayer` 已经异步解码；瓶颈在播放泵的视频包处理，独立队列即可解决，改动更小。

## Risks / Trade-offs

- **字节偏移估算误差**：VBR/多音轨文件用平均码率估算会偏离实际。→ 仅用于显示和粗判命中；实际 seek 和读取仍由解封装时间戳决定，命中判断要求区间连续。
- **回看窗口与预读争内存**：高码率 4K 回看 20 秒可能超过 64MB。→ 回看上限 64MB，超出部分按距离淘汰，优先保证前向预读。
- **单线程 SMB 调度**：预读和播放读仍共用调度器，seek 后首块可能与预读抢队列。→ 首次读取使用播放优先级；预读任务从读头开始，避免重复读。
- **旧预读任务晚返回**：generation 隔离只能防止写回，不能取消已经在 SMB 层的读。→ 接受一次 1MB 读的延迟，后续任务继续。
- **seek 命中判断依赖 ring 连续性**：ring 有缺口时可能误判未命中。→ 以连续段为准，宁可多读一次也不返回错误数据。
- **回退到缓存外仍会重缓冲**：这是物理限制，不承诺零等待；只保证不回退到已缓存区间时也重新读。
- **视频队列丢包**：队列满时丢弃非关键帧会造成花屏或显示层恢复。→ 队列按 64 包 / 64MB 留足余量，丢包计数进入报告；连续丢关键帧时通知渲染层从下一关键帧恢复。
- **视频工作线程与 seek 并发**：旧包可能在 seek 后到达工作线程。→ generation 校验 + `VideoRenderer.reset` 的 `needsKeyframe` 双重保护。
- **AVPacket 所有权**：移动引用后泵不能再 `av_packet_unref`，否则双重释放。→ 队列拥有包并负责释放，泵只对音频/字幕包做 unref。

## Migration Plan

- 无数据迁移；读窗口状态只存在于播放会话内。
- 增加启动参数 `-smbSeekCache 0` 可关闭新逻辑，回退到旧的「seek 清空环」行为，便于真机对比和回滚。
- 先在小 MP4 与 4K 长片上验证绿色区间、连续回退和 seek 首帧，再跑完整随机压力测试。

## Open Questions

- 回看窗口默认 20 秒是否需要按码率自适应（低码率可更长、高码率更短），留待真机数据决定，不阻塞实现。
