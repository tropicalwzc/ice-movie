# Proposal

## Why

媒体库目前已经能浏览 SMB 上的照片，但只能从 SMB 读取；用户无法把 iPhone 系统相册里的新照片备份到已经整理好的 SMB 照片目录。实际 `Photos` 共享已有约 3,596 张图片，靠手动导出或复制既费时又容易重复，需要一个在媒体库内手动触发、自动识别增量、只增不删的同步入口。

## What Changes

- **照片库路径标记**：每个 `host + share` 维护唯一目标目录；当前目录「更多」菜单和文件夹长按都可标记/取消；标记目录在父级网格显示 `photo.stack` 徽标，副标题显示“照片库路径”。
- **同步入口**：目标目录的媒体过滤条在日历按钮旁增加同步按钮；目标为空、没有照片日历时也显示。
- **增量识别**：读取系统相册静态图片（JPG/PNG/HEIC/HEIF），按“原文件名 + 拍摄时间”与远端文件名匹配，扩展名和前缀不参与；本地清单按 `localIdentifier` 加速，并在远端文件缺失时补传。
- **首次预览**：点同步后先扫描，展示系统相册可访问数、动态照片数、格式不支持数、目标已有/已匹配数、待同步数；确认后才开始上传。
- **上传与命名**：平铺到目标目录，文件名 `原名_yyyyMMddHHmmss.ext`；SMB 写入使用临时文件 + 大小校验 + rename，绝不覆盖已有文件，也不删除远端文件。
- **状态条与失败提示**：上传期间在导航/搜索栏下方固定显示数量进度条、实际 SMB 上传速度和取消按钮；单张失败继续并计数，整体中断显示常驻错误状态；结束时汇总成功/失败/跳过，可重试失败。失败提示只做应用内，不发系统通知。
- **Live Photo 扩展口**：v1 遇到 Live Photo 只上传静态图，清单记录 `livePhotoStill`；数据结构预留 `contentKind`、`[UploadFile]`、`[RemoteFile]` 与 `PhotoPackagingPolicy`，后续可加 `.livp` 动态同步而不重写同步引擎。
- **权限**：新增系统相册读取权限；保留现有 add-only 保存权限。

**BREAKING**：无。本 change 只新增同步能力，不改变现有播放、图片浏览或保存到系统相册的行为。

## Capabilities

### New Capabilities

- `photo-sync`: 照片库路径标记、系统相册读取与授权、增量匹配、同步预览、原子上传、状态条与网速、失败汇总与重试、Live Photo 静态图及未来动态扩展口。

### Modified Capabilities

- `media-library`: 目标目录条目增加“照片库路径”徽标/副标题；目标目录的过滤条增加同步入口（空目录也显示）；同步完成后目标目录与照片日历可刷新。

## Impact

- 媒体库 UI：`IceMovie/Feature/Library/LibraryMediaFilterBar.swift`、`LibraryView.swift`、`LibraryCell.swift`、`LibraryStore.swift`。
- 新增照片同步模块：`IceMovie/Feature/LibraryKit/` 下的纯逻辑（目标、命名、匹配、计划、清单）与 `IceMovie/Feature/PhotoSync/`（PhotoKit 适配、同步模型、状态条/预览/进度/汇总视图）。
- 数据与持久化：SwiftData 新增 `PhotoLibraryTarget` 模型（每 `host + share` 一条）；本地 JSON 清单按目标隔离；不向 SMB 写清单。
- SMB 写入：`IceMovie/Core/SMBSession/SMBClient.swift` 增加原子 `createFile`（临时文件、大小校验、rename、失败清理、可恢复错误重试一次）；`LibrarySource` / `LocalLibrarySource` / `SMBLibrarySource` 增加创建文件与进度回调。
- 权限与工程：`IceMovie/Resources/Info.plist` 增加 `NSPhotoLibraryUsageDescription`；`IceMovie/App/IceMovieApp.swift` 注册新 SwiftData 模型；`project.yml` 增加新文件/模块并重新生成工程。
- 测试与验收：新增命名/匹配/计划/清单/目标存储单元测试，本地数据源 + 假 PhotoKit 的端到端同步测试，UI 冒烟；真实 SMB 先验证写入探针，再对 `Photos` 共享做只读预览和 2-3 张照片的小批量上传，确认第二次同步无重复。
- 归档顺序：`image-gallery` 已完成但尚未归档；应先归档 `image-gallery` 再归档本 change，或手工合并两份 `media-library` delta，避免图片条目/过滤条要求冲突。
- **Out of scope**：Live Photo 动态 `.livp`、视频同步、GIF/APNG/WebP/RAW/DNG 转换、删除或覆盖远端文件、后台同步、系统通知、跨设备同步标记、递归子目录、编辑后照片重传。
