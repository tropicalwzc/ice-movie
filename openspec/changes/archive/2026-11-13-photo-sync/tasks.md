# Tasks

## 1. 目标、权限与写入底座

- [x] 1.1 新增 `PhotoLibraryTarget` SwiftData 模型与 `PhotoLibraryTargetStore`：按 `host + share` 唯一，支持读取、标记、替换、取消与重启恢复。验证：新增 `PhotoLibraryTargetStoreTests`，用内存容器覆盖标记/替换/取消/共享隔离/重启读取。
- [x] 1.2 在 `IceMovieApp` 的 `modelContainer` 注册 `PhotoLibraryTarget`，并把目标状态接入 `LibraryStore`/`LibraryView`（当前目标、`isTarget(path)`、切换共享刷新）。验证：应用启动无 SwiftData 迁移错误；单元测试或 UI 冒烟覆盖标记后切换目录与共享。
- [x] 1.3 在 `Info.plist` 增加 `NSPhotoLibraryUsageDescription`，新增 `PhotoLibraryAuthorization` 包装：区分未决定/拒绝/受限/有限/已授权，首次同步请求 `.readWrite`，拒绝时返回可操作错误。验证：单元测试用假授权状态覆盖全部映射；模拟器首次同步能看到系统权限弹窗。
- [x] 1.4 给 `LibrarySource` 增加 `createFile(path:data:modified:onProgress:)`，默认抛 `unsupportedWrite`；`LocalLibrarySource` 用同目录临时文件 + rename 实现。验证：新增本地集成测试断言写入成功、目标已存在时不覆盖、失败时清理临时文件。
- [x] 1.5 给 `SMBClient` 增加原子 `createFile`：目标不存在检查、临时文件、大小校验、rename、失败清理、可恢复错误重连重试一次；进度回调返回 `false` 时中止。验证：用真实 SMB 测试目录执行创建/读取/已存在不覆盖/取消清理；日志记录临时文件清理。
- [x] 1.6 让 `SMBLibrarySource` 实现 `createFile` 并透传写入进度；保留 `overwriteFile` 供既有图片覆盖使用。验证：本地与 SMB 数据源行为一致；构建通过且无 `LibrarySource` 测试桩编译失败。
- [x] 1.7 更新 `project.yml` 与 `xcodegen generate`，加入新文件、模块与测试依赖；确认 Photos 框架自动链接。验证：`xcodegen generate` 成功，模拟器 build 与 `IceMovieTests` 编译通过。

## 2. PhotoKit 适配与增量纯逻辑

- [x] 2.1 新增同步传输模型：`PhotoAssetDescriptor`（id/创建时间/原文件名/contentKind）、`PhotoExport`（still/motion?）、`UploadFile`、`RemoteFile`、`PhotoContentKind`。验证：单元测试覆盖静态图、Live Photo、未来动态枚举映射；`files`、`remoteFiles` 使用数组而不是单值。
- [x] 2.2 定义 `PhotoLibraryClient` 协议并实现真实 PhotoKit 客户端：只枚举 `mediaType == .image`、排除隐藏、按创建时间倒序；仅为未知资产读取 `PHAssetResource` 元数据；用当前版本导出静态图与 UTI；允许 iCloud 下载；单张超限跳过。验证：假客户端覆盖 fetch/export 失败；模拟器用 `simctl addmedia` 的 JPG/PNG/HEIC 能导出正确 UTI 与文件名。
- [x] 2.3 新增 `PhotoFileName`：`原名_yyyyMMddHHmmss.ext`、时区格式化、UTI 到扩展名映射、非法字符清洗、超长截断、同值时间戳去重、冲突序号插在时间戳前。验证：新增 `PhotoFileNameTests` 覆盖普通、带前缀、中文、长名、同秒冲突、缺失日期。
- [x] 2.4 新增 `RemotePhotoIndex` 与 `PhotoSyncMatcher`：完整名精确匹配、末尾时间戳分桶、同桶 stem 包含原名、忽略大小写/扩展名/前缀、短名只精确匹配、清单所有权、忽略临时文件。验证：新增 `PhotoSyncMatcherTests`，使用 `IMG_9399_20260505222609.jpg` 与 `2025-02-16 210732IMG_1241_20180526143955.livp` 等真实形态。
- [x] 2.5 新增 `PhotoSyncPlanner`：生成可访问/动态/不支持/缺时间/已存在/已匹配/待同步计数，按创建时间倒序排列候选，分配冲突名，Live Photo 只产出静态图。验证：新增 `PhotoSyncPlannerTests` 覆盖静态图、Live Photo、隐藏照片、GIF/RAW、远端缺失、重装无清单。
- [x] 2.6 新增 `PhotoSyncManifest`：按目标哈希的 JSON、版本字段、原子读写、每约 20 张批量保存、损坏回退、目标隔离、`contentKind` 与 `remoteFiles` 记录。验证：新增 `PhotoSyncManifestTests` 覆盖往返、损坏文件、批量保存、不同目标不串记录。
- [x] 2.7 新增 `TransferRateMeter`：用连续时钟记录最近约 3 秒累计字节，计算上传速度；无新样本时归零；UI 更新限频。验证：新增单元测试用可控时钟覆盖稳定速率、停滞归零、阶段切换。

## 3. 同步引擎与状态机

- [x] 3.1 实现 `PhotoSyncEngine` 扫描与预览：授权、加载清单、读取目标目录、构建远端索引、调用 planner、返回预览计数；确认前不写任何文件。验证：集成测试用假 `PhotoLibraryClient` + `LocalLibrarySource` 断言预览后磁盘无新增文件。
- [x] 3.2 实现上传循环：逐张导出、`createFile`、成功后写清单、失败分类；单张失败继续，成功后修改时间设为拍摄时间。验证：集成测试覆盖成功、单张失败继续、清单只记录成功项。
- [x] 3.3 实现取消与连续失败中止：取消标志在进度回调中检查，尽量中止当前写入并清理临时文件；连续 3 次 SMB 写入失败、不可写、登录失效、权限收回时停止。验证：集成测试断言取消后无半截最终文件、已上传文件保留、再次同步只处理剩余照片。
- [x] 3.4 实现 `PhotoSyncModel` 状态机与对外状态：`idle/scanning/review/uploading/summary/upToDate/interrupted`，发布 processed/total、bytesPerSecond、当前文件名、失败列表、目标与平均速度。验证：单元测试覆盖状态迁移、失败计数、重试失败、取消后的 summary。
- [x] 3.5 接入前台约束：同步期间 `isIdleTimerDisabled = true`，完成/取消/中断恢复；监听 `scenePhase`，切后台不承诺完成，回前台显示中断；不申请后台任务。验证：模拟器切后台/回前台，状态条显示中断且已上传文件保留。
- [x] 3.6 实现同步后刷新：完成/取消/中断后使目标目录缓存失效，当前在目标目录时刷新网格、照片日历与检索索引。验证：`LibraryStore` 单元测试断言缓存被移除并重新列举；UI 测试断言新照片无需重进目录即可出现。
- [x] 3.7 接入诊断日志：记录扫描计数、预览、开始/完成/取消/中断、失败原因、平均速度；不记录照片内容，成功逐张不刷屏。验证：真实/本地同步后日志包含关键节点，失败日志含文件名与原因。

## 4. 媒体库 UI 与状态条

- [x] 4.1 在当前目录「更多」菜单与文件夹长按菜单加入“设为照片库路径/取消照片库标记”；同一 `host + share` 已有目标时先确认替换。验证：UI 测试覆盖标记、取消、替换确认与取消确认。
- [x] 4.2 在父级网格显示照片库徽标，目标目录副标题显示“照片库路径”；未标记目录保持“文件夹”。验证：UI 测试/快照断言徽标与副标题；普通目录不受影响。
- [x] 4.3 在 `LibraryMediaFilterBar` 日历按钮旁增加同步按钮：仅当前目录是目标时显示，空目录/无照片日历也显示；状态覆盖空闲、扫描、上传、失败。验证：UI 测试覆盖有照片目标、空目标、非目标、切换共享。
- [x] 4.4 实现顶部同步状态条：固定在导航/搜索栏下方、过滤条上方；显示目标名、已处理/总数、数量进度条、上传速度、取消；切换目录仍显示；全屏相册/播放器覆盖后退出重新出现。验证：UI 测试断言状态条出现/隐藏/切换目录保持；视觉检查 iPhone 与 iPad。
- [x] 4.5 实现扫描/预览弹层：扫描中状态、预览计数、开始/取消、已是最新、预检错误（权限/目标不存在/不可写）。验证：UI 测试断言确认前目标目录无新增文件；无待同步显示已是最新。
- [x] 4.6 实现进度/汇总弹层：当前文件、成功/失败/跳过、用时、平均速度、失败原因列表、重试失败、取消。验证：UI 测试注入失败后断言失败列表与重试入口；全部成功时不显示失败区。
- [x] 4.7 实现失败提示：单张失败在状态条显示红色计数并继续；整体中断显示常驻红条与“重试/详情”；权限错误提供“去设置”，目标错误提供“重新标记/取消”。验证：UI 测试覆盖单张失败、整体中断、权限拒绝、目标不可写。
- [x] 4.8 补充无障碍与布局：状态条/进度条/取消/同步按钮的 label、value、identifier；动态字体、iPhone 两行布局、iPad 单行布局不截断。验证：VoiceOver 能读出“同步到 Photos，3/1260，18.4 MB/s”；iPhone/iPad 横竖屏视觉检查。

## 5. 集成、验收与文档

- [x] 5.1 本地端到端测试：`LocalLibrarySource` + 假 `PhotoLibraryClient` 完成首次同步、第二次无重复、带前缀/扩展名不同的旧文件匹配、取消后继续、单张失败继续。验证：新增 XCTest 全绿，临时目录的文件名、大小与清单一致。
- [x] 5.2 模拟器 UI 冒烟：用 `simctl addmedia` 注入 JPG/PNG/HEIC，授予照片权限，标记本地目标目录，走同步按钮→预览→开始→状态条→汇总→网格刷新。验证：XCUITest 通过，目标目录出现带时间戳的文件，照片日历出现对应日期。
- [x] 5.3 真实 SMB 小批量验收：对测试目录执行写入探针；标记目标，只上传 2-3 张照片，检查大小/修改时间/文件名；再次同步确认无重复；确认没有覆盖既有文件、没有遗留临时文件。验证：iPad/iPhone 真机日志与 SMB 目录 listing。
- [x] 5.4 真实 `Photos` 共享只读预览：连接 `tropical-advpc.lan` 的 `Photos` 共享，标记根目录后只扫描并查看预览计数，不开始上传；核对“目标已有/已匹配/待同步”数量是否符合 3,596 张语料的预期，异常时先取消，不放量上传。验证：预览计数与日志；必要时截图。
- [x] 5.5 性能与内存检查：大库首次扫描耗时、100 张批量上传、取消响应时间、状态条网速与实际耗时对比、内存峰值。验证：Instruments/`XCTMemoryMetric` 或日志记录；单张超限能被跳过且不崩溃。
- [x] 5.6 更新 README 与 `docs/photo-sync-acceptance.md`：说明标记、同步、权限、命名/去重、状态条/网速、失败重试、只增不删、Live Photo 仅静态图与未来动态口子。验证：按文档步骤可复现本地/模拟器流程，文档与实现一致。
- [ ] 5.7 归档前检查：`openspec validate photo-sync --strict` 通过；确认 `image-gallery` 已归档或两份 `media-library` delta 已手工合并；媒体库主 spec 的 Purpose 覆盖视频、图片与文档。验证：`openspec validate` 与 `openspec show media-library --type spec`。

## Workflow follow-up

- 按项目评审要求归档本 change；建议先归档 `image-gallery` 再归档 `photo-sync`。
- 归档后确认 `openspec/specs/photo-sync/spec.md` 与 `openspec/specs/media-library/spec.md` 合并结果无重复/冲突。
- Live Photo 动态补全与 `.livp` 打包另开 change；复用本 change 的 `contentKind`、`[UploadFile]`、`[RemoteFile]` 与 `PhotoPackagingPolicy` 口子。
