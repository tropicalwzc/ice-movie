# Proposal

## Why

多集剧集文件夹里，文件名如果带 `_yyyyMMddHHmmss` 拍摄时间，当前排序会优先按时间倒序，导致第 10 集排在第 1 集前面，播放顺序和浏览顺序都被打乱。剧集文件夹应该从第 1 集顺序排到最后一集。

## What Changes

- **多集目录识别**：同一目录中至少两集视频共享同一解析标题且都有集号时，判定为多集剧集目录。
- **按集数升序**：多集目录中的视频按“标题 → 季 → 集”升序排列，集号顺序覆盖拍摄时间；第 2 集排在第 10 集之前。
- **非剧集内容回退**：单集视频、无法解析集号的视频与图片继续按拍摄时间倒序；文档仍排在最后。
- **严格弱序**：多集视频整体成块排在非剧集媒体之前，避免逐对忽略时间造成排序环。
- **播放顺序同步**：目录列表顺序同时用于播放队列，剧集从第 1 集开始连播。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `media-library`: 多集剧集目录的排序规则从“拍摄时间优先”明确为“季/集升序优先”，其余媒体保持原有时间排序。

## Impact

- 排序逻辑：`IceMovie/Feature/LibraryKit/MediaTitle.swift` 的 `MediaOrdering`，新增多集检测与剧集优先比较器。
- 目录构建：`IceMovie/Feature/LibraryKit/LibraryLoader.swift` 继续统一走 `MediaOrdering.sorted`，无需改调用方。
- 测试：`IceMovieTests/LibraryOrderingTests.swift` 增加带拍摄时间的多集排序、单集/照片回退、多部剧集分组与严格弱序用例。
- 真机验收：`tropical-bigpc.lan` / `sensei` 下多集番剧目录，确认从第 1 集顺序排列。
