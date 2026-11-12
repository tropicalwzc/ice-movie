# Design

## Context

当前媒体库已经支持图片条目、混合网格、媒体过滤、照片日历与全屏相册（见 `image-gallery` change；该 change 已完成但尚未归档）。照片只从 SMB 读取；反方向只有“保存到系统相册”的 add-only 写入。代码中还没有“照片库路径”标记、系统相册读取权限，也没有面向新文件的 SMB 原子创建接口。

本设计建立在这些现有结构上：

- `LibraryStore` 持有当前目录、过滤状态、照片日历与近期路径；`LibraryMediaFilterBar` 是日历入口所在。
- `LibrarySource` 抽象 SMB 与本地目录；`SMBClient` 已有读取、覆盖写与写入探针，但正式接口没有“创建新文件且不覆盖”。
- `PhotoTimestampParser` 已能解析文件名末尾 `_yyyyMMddHHmmss`，照片日历依赖它。
- 真实 `Photos` 共享根约有 3,596 张图片，文件名同时存在 `IMG_9399_20260505222609.jpg` 与 `2025-02-16 210732IMG_1241_20180526143955.livp` 两种形态。
- 应用目前只有 `NSPhotoLibraryAddUsageDescription`，没有读取系统相册的权限声明。

需求见 `specs/photo-sync/spec.md` 与 `specs/media-library/spec.md`，动机见 `proposal.md`。

## Goals / Non-Goals

**Goals:**

- 每个 `host + share` 一个照片库目标；手动触发、先预览、后上传。
- 对现有 3,596 张照片与后续重复同步做确定性去重，首次同步不整批重传。
- 上传原子化：不覆盖、不删除、不留下半截最终文件。
- 前台可见的数量进度条、实际 SMB 上传速度、取消与失败汇总。
- 为 Live Photo 动态 `.livp` 预留数据结构与打包策略口子。

**Non-Goals:**

- 不在 v1 实现 Live Photo 配对视频、`.livp` ZIP 写入、视频同步。
- 不做双向同步、删除远端、覆盖编辑后的照片。
- 不做后台同步、系统通知、跨设备同步标记、递归子目录。
- 不改变现有照片浏览、播放、搜索或保存到系统相册的行为。

## Decisions

### D1. 目标模型：每个 `host + share` 一条 SwiftData 记录

新增独立 `@Model PhotoLibraryTarget`：

```
key        "\(host.lowercased())|\(share.lowercased())"  // 唯一
host       用户连接时填写的地址原文
share      共享名
path       目标目录相对共享根；根目录为空串
createdAt
updatedAt
lastSyncedAt?
```

- 选择独立模型而不是给 `SavedHost` 加字段：`SavedHost.share` 只保存最近一次连接的共享，切换共享会覆盖，无法表达“每个共享一个目标”。
- 选择 SwiftData 而不是 `UserDefaults`：与 `HostRecordStore` 的持久化方式一致，可观察、可测试，后续可扩展同步统计。
- 标记另一个目录 = 更新同一条记录的 `path`，界面先确认“将替换旧目标”；取消标记 = 删除记录。旧目标的本地清单保留在磁盘上，重新标记时可复用。
- 标记只存在本机，不写 SMB。iPhone 与 iPad 各标记一次；同一目标下的重复上传由远端文件名匹配兜底。
- 备选“在 SMB 写一个隐藏 marker 文件”被拒绝：增加远端写入、并发冲突与隐私面，且与“只增照片”原则不符。

### D2. 模块边界与数据流

```
PhotoKit
  └─ PhotoLibraryClient (protocol)
        • authorization / requestAccess
        • fetchImageAssets(knownIDs) -> [PhotoAssetDescriptor]
        • export(assetID) -> PhotoExport { still, motion? }
              │
              ▼
PhotoSyncPlanner (pure)
  ├─ PhotoFileName       命名、扩展名映射、清洗、冲突序号
  ├─ RemotePhotoIndex    远端文件名索引 + 时间戳桶
  ├─ PhotoSyncMatcher    增量匹配 + 清单所有权
  └─ PhotoSyncManifest   每目标本地 JSON
              │
              ▼
PhotoSyncEngine / PhotoSyncModel (@MainActor @Observable)
  ├─ 状态机、进度、失败列表、取消
  └─ PhotoUploader -> LibrarySource.createFile(path:data:modified:onProgress:)
                          └─ SMBClient.createFile（临时文件 + 校验 + rename）
```

- `PhotoLibraryClient` 用协议隔离 PhotoKit，单元测试注入假实现；真实实现只做授权、枚举与导出，不关心命名和去重。
- `PhotoSyncPlanner` 全部是纯逻辑，不依赖 PhotoKit、SwiftUI 或 SMB，便于覆盖前缀、扩展名、冲突、缺失时间等边界。
- `PhotoSyncModel` 持有唯一同步任务；状态条与弹层都观察它，避免两套进度来源。
- `LibrarySource.createFile` 默认抛出“不支持写入”，SMB 与本地源各自实现；测试桩无需改动即可编译。

### D3. 增量身份：原文件名 + 拍摄时间，清单加速

“同一张照片”的规范键：

```
canonical = lower(原文件名去扩展名) + "|" + yyyyMMddHHmmss(创建时间)
```

匹配时忽略扩展名、大小写和文件名前缀，因为现有语料同时存在：

- `IMG_9399_20260505222609.jpg`
- `2025-02-16 210732IMG_1241_20180526143955.livp`

远端索引构建：

```
exactNames: Set<String>                  // 小写完整文件名
byTimestamp: [String: [String]]          // 末尾 14 位时间戳 -> 小写 stem 列表
```

候选判断：

1. 完整文件名（小写）命中 `exactNames` -> 已存在。
2. 同一时间戳桶中存在 stem 等于或包含原文件名（小写）-> 已存在；为避免过短名字误命中，原文件名少于 4 个字符时只做精确匹配。
3. 本地清单记录存在且对应远端文件仍在索引中 -> 已存在。
4. 其余 -> 待同步。

本地清单按目标隔离，记录 `localIdentifier -> { contentKind, remoteFiles: [{ name, role, size }], syncedAt }`。它解决三件事：

- 已同步资产不必每次读取 PhotoKit 资源元数据，后续扫描只处理未知资产。
- 同名同秒冲突时知道某个远端文件属于哪个资产，避免把另一张照片误判为已存在。
- 远端文件被删除时能发现并补传。

重装或清单损坏时没有快速路径，但远端文件名匹配仍能避免整批重复；这是有意的降级。

**不采用内容哈希**：首次要下载 3,596 张远端照片算哈希，时间和流量不可接受。
**不采用严格同名**：会漏掉带前缀或格式转换过的旧文件。
**不采用只按上次同步时间**：会漏掉后来导入的旧照片。

已同步照片在系统相册中被编辑时，清单仍视其为已同步，v1 不覆盖远端；从系统相册删除也不会删除远端。这两点与“只增不删”的备份语义一致。

### D4. PhotoKit：只取静态图，未知资产才读资源元数据

- 授权：首次同步时请求 `.readWrite`，不放在启动阶段；`Info.plist` 增加 `NSPhotoLibraryUsageDescription`。`.limited` 只枚举已授权资产，并在预览中标注。
- 枚举：`PHAsset` 仅取 `mediaType == .image`，按 `creationDate` 倒序，排除 `isHidden`。视频、GIF、RAW 在后续类型判断中跳过。
- 元数据读取：只为“未知且未匹配本地清单”的资产读取 `PHAssetResource`，拿 `originalFilename` 与 UTI；已同步资产直接跳过，避免对大库做全量资源读取。元数据读取可小并发（4 个）以缩短首次扫描。
- 导出：用 `PHImageManager` 的当前版本（`version = .current`、`highQualityFormat`、`isNetworkAccessAllowed = true`），拿到静态图数据与 UTI；UTI 映射为 jpg/jpeg、png、heic/heif。编辑过的照片导出用户当前看到的样子。
- Live Photo：`mediaSubtypes.contains(.photoLive)` 的资产在 v1 只导出静态图，清单记 `contentKind = .livePhotoStill`；不请求 `.pairedVideo`。
- 内存：一次只导出一张；单张超过上限（设计上取 128 MB）跳过并计数，避免大全景/编辑图导致 OOM。v1 不落盘中间文件。
- 备选“用 `PHAssetResourceManager` 取原始资源”会丢失编辑效果，且对 Live Photo 需要额外配对，不采用。

扩展口：

```
PhotoAssetDescriptor { id, creationDate, originalFilename, contentKind }
PhotoExport          { still: PhotoResource, motion: PhotoResource? }
PhotoTransfer        { assetID, contentKind, files: [UploadFile] }
SyncManifestRecord   { assetID, contentKind, remoteFiles: [RemoteFile] }
```

未来只需让导出填充 `motion`、增加 `LivePhotoPackaging`（输出 `.livp` 或 HEIC+MOV），同步引擎、清单与上传器不用重写。

### D5. 命名、扩展名与冲突

- 目标目录内平铺，不建年/月子目录；照片日历按当前目录索引，平铺才能让目标目录的日历覆盖全部照片。
- 文件名：`base_yyyyMMddHHmmss.ext`。
  - `base` 取 `originalFilename` 去扩展名；若 base 已以同值 `_yyyyMMddHHmmss` 结尾，则不重复追加。
  - 时间戳使用 `creationDate`，按当前时区格式化；没有 `creationDate` 时退 `modificationDate`，两者都没有则跳过并计数。
  - 扩展名按导出 UTI 映射：`public.jpeg -> jpg`、`public.png -> png`、`public.heic -> heic`、`public.heif -> heif`。
- 清洗：去掉 `/`、NUL 与控制字符，压缩连续空白；base 过长时截断到约 160 字符，保留时间戳与扩展名。
- 冲突：若目标名已被**其他资产**占用（由清单所有权判断），在时间戳前加 `_2`、`_3`；冲突候选按 `localIdentifier` 排序，保证多次扫描分配稳定。若目标名存在但不属于任何本地资产，视为旧语料已存在，跳过。
- 上传成功后把远端修改时间设为拍摄时间；设置失败只记日志，不使上传失败。
- 备选“按年/月分目录”会破坏当前目录日历与现有平铺语料，不采用；备选“UUID 文件名”不可读且日历解析失效，不采用。

### D6. SMB 原子创建与进度回调

`SMBClient` 新增 `createFile(path:data:modified:onProgress:)`：

```
1. ensureManager
2. 目标不存在（attributesOfItem 抛错视为不存在）
3. 写同目录临时文件 path.icemovie-tmp-<uuid>
4. 校验远端大小 == data.count
5. 再次确认目标仍不存在
6. moveItem 临时文件 -> 最终文件
7. setAttributes 修改时间为拍摄时间
8. 任一步失败：removeItem 临时文件，抛错
9. 可恢复错误：重连后重试一次；若重试时发现最终文件已存在且大小一致，视为成功
```

- 进度：AMSMB2 的 `write(data:toPath:progress:)` 每约 1 MiB 回调已写字节；把回调透传给 `PhotoSyncModel`，用于网速与协作取消。回调返回 `false` 会中止写入，`createFile` 负责清理临时文件。
- `LibrarySource` 增加 `createFile`（默认抛 `unsupportedWrite`）；`SMBLibrarySource` 走上述接口，`LocalLibrarySource` 用临时文件 + rename 实现，供模拟器端到端测试。
- 不复用 `overwriteFile`：它要求原文件存在，并会先备份/替换，不能安全用于创建新文件。
- 不直接写最终文件：中断会留下半截文件，后续可能被误判为已存在；临时文件方案保证最终文件要么完整、要么不存在。
- 临时文件后缀 `.icemovie-tmp-` 不进入媒体库索引；同步开始构建远端索引时忽略它。崩溃遗留的临时文件不可见，后续可加清理任务，v1 不做远端删除。
- 串行上传，一次一张：SMB 会话同时服务缩略图与播放读取，串行能控制内存和错误语义；播放中同步可能降低吞吐，但不阻塞播放。

### D7. 同步状态机与界面

```
idle
  │ tap sync
  ▼
scanning ──无增量──> upToDate
  │ 有增量
  ▼
review ──取消──> idle
  │ 开始
  ▼
uploading ──完成──> summary
  │ 取消/中断
  ▼
summary
```

- `PhotoSyncModel` 是 `@MainActor @Observable`，持有任务、阶段、`processed/total`、`bytesPerSecond`、失败列表、目标与清单。状态条和进度弹层读同一份状态。
- 状态条放在 `LibraryContentPage` 的 `VStack` 顶部、媒体过滤条上方，固定在滚动区域之外；导航/搜索栏仍由系统承载。切换目录时 `LibraryContentPage` 不重建，因此状态条继续可见。
- 数量进度条以“已处理/待同步总数”为准；失败也推进进度，汇总单独显示成功/失败。
- 网速：`TransferRateMeter` 用 `ContinuousClock` 记录最近 3 秒的累计写入字节，计算滑动窗口速率；UI 以约 2 Hz 更新，显示 `↑ 18.4 MB/s`。读取照片/iCloud 下载阶段显示“正在读取照片…”，不上报旧速度；停滞超过 3 秒归零。
- 预览弹层：扫描完成后展示可访问、动态照片、不支持格式、缺少时间、目标已有/已匹配、待同步等计数；点“开始同步”后关闭弹层，状态条接管，用户可以继续浏览。
- 进度/汇总弹层：点状态条打开；展示当前文件、成功/失败/跳过、用时、平均速度与失败原因；提供“重试失败”。
- 失败：单张失败继续，状态条显示红色失败计数；整体中断（SMB 断线、目标不存在、不可写、权限收回）停止并常驻红条；预检失败用带“去设置/重新标记/取消”的提示。
- 取消：协作式。状态条与弹层都有取消入口；取消标志在 SMB 进度回调中检查，尽量中止当前写入并清理临时文件；已上传文件保留，汇总显示剩余数量。
- 前台：同步期间置 `isIdleTimerDisabled = true`，完成/取消/中断后恢复；不申请后台任务，不承诺后台完成。切后台导致的中断在回到前台后显示“已中断”，下次同步继续。
- 沉浸式相册/全屏播放覆盖状态条；退出后若仍在同步或存在失败，状态条重新出现。
- 刷新：完成/取消/中断后让目标目录缓存失效；若当前在目标目录，调用 `loadCurrent(force:)` 或 `reloadDirectoryIfNeeded`，重建照片日历并更新检索索引。

备选“进度只放在模态弹层”会让用户无法边浏览边看进度，不采用；备选“系统通知”在纯前台同步下没有可靠触发时机，不采用。

### D8. 本地清单与恢复

- 每个目标一个 JSON，路径 `Application Support/PhotoSync/manifest-<sha256(host|share)>.json`；带 `version`、`target`、`assets`。按目标哈希隔离，避免路径字符问题。
- 清单只在成功上传后记录；失败或取消的当前文件不记录。每成功约 20 张批量原子写一次，并在完成/取消时强制写；崩溃最多丢一小批记录，下次靠远端文件名补齐，不会重复上传。
- 清单损坏或版本不兼容：记日志、丢弃并从远端文件名重建；不阻塞同步。
- 不把清单写到 SMB：避免额外远端写入、并发冲突与跨设备权限问题；跨设备重复由文件名匹配兜底。
- 备选 SwiftData 逐条记录：每次同步可能新增数千条，逐条保存和迁移成本更高；JSON 快照更适合这种“整表加载、批量写”的索引。

### D9. 权限、隐私与数据边界

- 新增 `NSPhotoLibraryUsageDescription`；仅在首次同步时请求 `.readWrite`，启动时不做权限提示。
- 隐藏照片不枚举、不上传；有限授权只处理用户选中的照片，并在预览中明确说明。
- 不上传照片到任何第三方服务；只写用户标记的 SMB 目标。
- 日志只记录数量、目标路径、失败原因与耗时，不记录照片内容；文件名按现有 `Log.shortPath` 规则处理。
- 标记与清单只在本机；不向 SMB 写除照片以外的文件（v1）。

### D10. 测试与验收

- 单元测试：`PhotoFileName`（时间戳、扩展名、清洗、冲突）、`PhotoSyncMatcher`（精确/前缀/扩展名/时间戳/清单所有权）、`PhotoSyncPlanner`（静态/Live Photo/不支持/隐藏/缺时间/远端缺失）、`PhotoSyncManifest`（往返、损坏、目标隔离）、`PhotoLibraryTargetStore`（唯一目标、替换、取消、共享隔离）。
- 集成测试：`LocalLibrarySource` + 假 `PhotoLibraryClient` 跑完整扫描→预览→上传→再次同步；验证原子性、取消、失败继续、刷新。
- UI 测试：用模拟器照片库或假客户端标记本地目录、打开预览、开始同步、状态条出现、完成后网格出现新照片；验证失败状态条。
- 真机验收：先用写入探针确认目标可写，再对 `Photos` 共享做**只读预览**核对匹配数；确认后只上传 2-3 张小批量照片，第二次同步确认无重复；最后再考虑全量。
- 归档顺序：先归档 `image-gallery`，再归档 `photo-sync`；否则两份 `media-library` delta 需要手工合并图片条目/过滤条要求。

## Risks / Trade-offs

- **旧语料命名不统一，首次同步可能重复上传** → 宽松文件名匹配 + 预览计数 + 不自动开传；先做只读预览核对，再小批量验收。
- **时区差异导致拍摄时间戳与旧文件不一致** → 首次预览会暴露异常高的待同步数；先取消并调整匹配规则，不加自动兜底以免误跳过。
- **大库首次扫描慢** → 已同步资产走清单快速跳过；未知资产才读资源元数据；小并发 + 可取消 + 扫描阶段文案。
- **首次同步数据量大、耗时长** → 预览确认、取消入口、保持屏幕常亮、明确“前台运行”；不承诺后台完成。
- **iCloud 照片下载慢或失败** → 允许网络访问；单张失败继续；汇总可重试。
- **SMB 写入与播放/缩略图争用** → 串行上传、手动触发；播放中同步可能变慢，但不阻塞播放。
- **超大编辑图导致内存峰值** → 单张大小上限，超限跳过并计数；v1 不支持视频/动态包。
- **崩溃遗留临时文件** → 后缀不出现在媒体库；同会话失败会清理；后续可加启动清理。
- **宽松匹配误判（同名同秒不同照片）** → 原文件名过短时只做精确匹配；清单所有权处理冲突；预览与汇总可发现异常。
- **清单损坏或重装** → 丢弃后靠远端文件名重建；最坏情况只重复少量命名不一致的照片。
- **SwiftData 新模型迁移** → 新增独立模型，不改现有模型；失败时回退到本地 JSON 目标存储的备选方案在实现阶段评估。
- **未来 Live Photo 补全与已上传静态图并存** → 清单记录 `livePhotoStill` 与 `remoteFiles`，后续 change 决定保留还是替换静态图；不影响 v1。

## Migration Plan

- SwiftData：在 `modelContainer` 注册 `PhotoLibraryTarget`；新表由 SwiftData 自动创建，不改 `SavedHost` 与 `PlaybackProgressRecord`。
- 权限：新增 `NSPhotoLibraryUsageDescription`；已有 add-only 文案保留。首次同步才请求，不影响启动。
- 工程：新增文件后执行 `xcodegen generate`；`Photos` 由系统框架自动链接，无需手工加依赖。
- 回滚：移除同步入口与目标记录即可；已上传照片保留在 SMB，由用户自行处理；本地清单可删除，不影响媒体库读取。
- 归档：按 D10 的顺序先归档 `image-gallery`。

## Open Questions

- Live Photo 动态补全时，已上传的静态图是保留、替换还是生成 `.livp` 后清理？留到后续 change；v1 只记录 `livePhotoStill`，不影响当前行为。
