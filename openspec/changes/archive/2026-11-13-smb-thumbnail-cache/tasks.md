# Tasks

## 1. 共享侧车缓存模型

- [x] 1.1 在 `ThumbnailKit` 定义 `ThumbnailSidecarProviding`、`SharedThumbnailIndex`、缓存键与 SHA256 分片路径；验证单元测试覆盖键变化、索引编解码与两位分片。
- [x] 1.2 实现 `SharedThumbnailCache` actor：延迟加载索引、侧车命中读取、生成后写入索引、每 20 张或 5 秒批量 flush、写入失败标记只读；验证 fake provider 单测覆盖命中、miss、批量 flush 与降级。

## 2. SMB 与本地侧车实现

- [x] 2.1 扩展 `SMBClient`：公开创建目录、文件存在判断、读取小文件、原子写文件与删除；验证 68B/256B 共享往返测试与现有 SMB 回归。
- [x] 2.2 实现 `SMBThumbnailSidecar`：`.icemovie/version`、`index.json`、分片缩略图读写与 `.icemovie` 创建；`LibrarySource` 暴露可选 sidecar，本地源提供同构实现供模拟器测试。
- [x] 2.3 侧车读写单测：使用临时目录 provider 验证首次写入、再次读取、源文件大小/时间变化失效、索引损坏回退。

## 3. ThumbnailService 接入

- [x] 3.1 `ThumbnailService` 在本地缓存 miss 后先查侧车；侧车命中时返回数据且不打开原图字节源；验证单测断言原图 provider 打开次数为 0。
- [x] 3.2 缩略图生成成功后异步写回侧车与索引，记录宽高；写入失败不影响当前显示；验证单测与只读 provider 降级。
- [x] 3.3 侧车缩略图损坏时删除并回退原图生成；验证损坏 JPEG 单测。

## 4. 全量预热与增量

- [x] 4.1 实现 `ThumbnailPrewarmController`：进入目录自动开始、单并发、可见项优先、暂停/继续/取消、进度与断点跳过；验证 controller 单测覆盖跳过已有、暂停、恢复。
- [x] 4.2 接入 `LibraryStore` 与 `LibraryGridView`：目录加载后自动启动，滚动时暂停，顶部显示进度条与暂停/继续按钮；验证 UI 测试能看到进度并在完成后消失。
- [x] 4.3 增量预热：目录刷新时对比索引与实际条目，新增/变化入队，删除条目清理索引与缩略图；验证 fake provider 单测。
- [x] 4.4 完成/暂停/退出时 flush 索引；充电空闲时通过 `BGProcessingTask` 继续当前目录预热；验证任务注册与恢复路径。

## 5. 集成、验收与文档

- [x] 5.1 更新 README 缓存策略与验收文档：侧车目录、预热、增量、只读降级、磁盘占用。
- [x] 5.2 真机 iPad SMB 验收：首轮预热进度、侧车文件数量与大小、二次打开首屏、增量新增照片；记录数据。首轮缺失从 3,892 降到 0，侧车命中 5–45KB，最终提示无缺失封面。
- [x] 5.3 运行完整单元测试、iPhone/iPad `ImageGalleryUITests` 与真实 SMB 验收，确认无回归。

## 6. 滚动帧率与渲染收尾

- [x] 6.1 移除 `.scrollPosition(id:)` 持续跟踪，改用 `ScrollViewReader` + 非 Observable 可见锚点；恢复位置只在进入目录/跳转时执行。
- [x] 6.2 移除每个 cell `onAppear` 都重排预热队列的 O(n) 操作；滚动期间预热只暂停，不参与布局。
- [x] 6.3 增加 `-fpsMonitor` + `CADisplayLink` 滚动帧率诊断；60Hz iPad 10 次滑动验收线 ≥50fps。
- [x] 6.4 修复 10-bit/广色域 HEIC 编码失败：PNG/JPEG 失败时归一化为 8-bit sRGB 后重试；6 张老 HEIC 全部生成，预热缺失归零。
- [x] 6.5 真机复测：优化前 33.2–45.0fps，优化后 10 次滑动 **54.5–57.2fps**、单次掉帧约 7–14 帧。
- [x] 6.6 消除滑动时黑边闪现：进入目录先用侧车索引合并 3,891 条宽高比；单元格首次加载先回填比例再显示图片；已有比例时滚动中才延迟改高度。验证：真机日志 `侧车宽高比合并 数量=3891`，滚动帧率维持 57fps。

## Workflow follow-up

- 实现与验收完成后，按项目评审要求归档本 change。
- 归档后检查 `openspec/specs/thumbnail-cache/spec.md` 的 Purpose 与 `media-library` 的缩略图要求已合并。
