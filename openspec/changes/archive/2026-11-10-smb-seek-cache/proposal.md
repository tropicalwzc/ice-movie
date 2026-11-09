# Proposal

## Why

当前 SMB 播放的缓存语义把「播放头」「解封装读头」「预读最远点」混在 `lastReadEnd` 一个变量里：回退 seek 后锚点不跟着回退，后续每次读取都会判定为再次 seek，导致预读环被反复清空、绿色缓冲区间始终接近 0，并出现反复重新缓冲。对照 mpv 与 ExoPlayer，成熟播放器都从播放头计算可用缓冲、优先复用已缓存区间，并只对未命中的 seek 丢弃前向窗口。

## What Changes

- 新增 SMB 读窗口模型，显式区分 `playhead`（播放位置）、`readHead`（解封装已读位置）、`prefetchHead`（预读最远位置）和 `windowStart`（回看窗口起点）。
- 缓冲区间改为从播放头到预读最远点连续计算，进度条浅绿色区间不再只显示解封装读头之后的一小段。
- seek 先查缓存命中：目标仍在已缓存连续区间内时直接复用，不重置预读环；目标在回看窗口附近时保留重叠段；只有完全未命中才丢弃前向窗口。
- 回看缓存独立限额（默认约 20–30 秒），按离播放头的距离淘汰，而不是按全局最小偏移淘汰。
- seek 后先读取目标位置第一块，再从解封装读头向前预读；旧预读任务用 generation 隔离，不能写回新窗口。
- 增加可观测指标与验收：绿色区间秒数、seek 命中/未命中、seek 后首次出画与缓冲次数、连续反向跳转是否复用缓存。
- 将视频包的封装/入队从播放泵拆到独立有界队列和线程；播放泵只负责读包、音频解码和字幕包处理。seek 时清空视频队列并用 generation 隔离旧包。
- 用实际音频/视频包的字节位置修正播放头估算，避免 VBR 文件绿色区间长期显示 0–1 秒。

## Capabilities

### New Capabilities

- `smb-read-cache`: SMB 播放的读窗口、seek 缓存命中、回看窗口、预读推进和缓冲区间报告。
- `playback-supply`: 视频包处理与音频供给解耦、有界视频队列、seek 清空和供给可观测性。

### Modified Capabilities

无。本次为独立能力，不修改既有主 specs。

## Impact

- **代码**：`IceMovie/Core/SMBSession/SMBFileByteSource.swift`、`SMBChunkRing.swift`、`IceMovie/Core/IceCore/ByteSource.swift`、`IceMovie/Core/DemuxKit/AVIOBridge.swift`、`IceMovie/Core/DemuxKit/MediaReader.swift`、`IceMovie/Core/RenderKit/PlaybackEngine.swift`、`IceMovie/Core/RenderKit/VideoPacketPipeline.swift`、`IceMovie/Feature/Player/PlayerControlsView.swift`。
- **行为**：回退 seek 与邻近 seek 不再清空全部缓存；进度条缓冲区间从播放头计算；seek 后预读从解封装读头继续。
- **测试**：`SMBChunkRingTests`、新增读窗口/seek 命中单元测试；iPad 真机用 4K 长片验证连续反向跳转、绿色区间和缓冲次数。
- **依赖**：不新增第三方依赖；`libsmb2` 仍为单线程读取，预读与播放读继续共用调度器。
- **风险**：视频包独立队列需要处理 AVPacket 所有权、seek 时清空和丢包策略；4K HDR 的显示层解码仍由系统完成，本次只解决播放泵的供给阻塞。
