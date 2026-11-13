# Proposal

## Why

媒体库网格中的子目录目前只显示通用文件夹图标，即使目录里全是视频也无法从封面判断内容。当大目录与几个子目录混排时，这种空白尤其明显，用户会误以为封面缩略图没有正常工作。

## What Changes

- **目录视频封面**：网格中的目录条目如果内部存在视频，取其中一个视频的中间帧作为该目录封面，替代通用文件夹图标。
- **候选与降级**：优先使用直接子视频；没有时最多向下扫描两层、有限个子目录。抽帧失败的视频会被跳过并尝试下一个候选；全部失败时回退现有文件夹图标和渐变占位。
- **缓存与失效**：目录封面按“目录路径 + 内部视频路径、大小、修改时间”缓存到独立的 16MB 本地缓存 `Caches/FolderCovers`；候选按路径稳定排序，内部视频变化后自然生成新封面。不写回 SMB 原文件，也不写入共享侧车索引。
- **性能隔离**：目录封面使用独立的单并发队列和短延迟启动，单元格滑出屏幕即取消；保持瀑布流高度稳定，不参与滚动时的布局重算。
- **视觉标识**：使用视频帧铺满目录卡片，并保留一个小文件夹角标，避免与普通视频条目混淆。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `media-library`: 目录条目在网格中的封面呈现从“固定文件夹图标”扩展为“有内部视频时展示视频中间帧，无视频或失败时回退文件夹图标”。

## Impact

- 抽帧：`IceMovie/Core/DemuxKit/DemuxProbe.swift` 增加按视频时长比例定位的参数。
- 缩略图服务：`IceMovie/Core/ThumbnailKit/ThumbnailKit.swift` 透传中间帧位置。
- 媒体库状态：`IceMovie/Feature/Library/LibraryStore.swift` 增加目录候选解析、封面缓存、并发隔离与失效键。
- 网格 UI：`IceMovie/Feature/Library/LibraryCell.swift` 的目录分支加载并展示封面，保留文件夹角标。
- 测试：`IceMovieTests` 增加目录候选选择、中间帧定位与缓存键用例；真机用 `tropical-bigpc.lan` 的 `Videos/Study` 验收。
