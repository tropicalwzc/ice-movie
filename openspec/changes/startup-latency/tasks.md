# Tasks

## 1. 观测与基线

- [x] 1.1 在 `PreparedPlayback`、`PlaybackEngine.Statistics` 与验收报告写入 `playerPresentedMilliseconds`、`openBytesRead`、`openReadCount`、`avioFillCount`、`attachmentBytes`、`attachmentFontBytes`、`skippedFontCount`、`headerCacheHitBytes`、`headerCacheHitRatio`、`subtitleScanMilliseconds`、`startupPrerollMode`、`startupBufferStalls`；验证：模拟器跑 3 条样本，`docs/acceptance-*.json` 中这些键存在且类型正确
- [x] 1.2 在 `AVIOBridge` 与 `SMBFileByteSource` 增加填充次数、实际读取字节、小读次数计数，并在 `播放准备拆分` 日志中输出；验证：单元测试触发 10 次读后计数为 10，日志包含新增字段
- [x] 1.3 更新 `README.md` 的验收报告字段说明，补齐 1.1 新增字段的含义与单位；验证：文档字段名与 JSON 键逐项一致
- [x] 1.4 用当前 Release 构建跑 20 条代表性样本（1080p MP4、1080p MKV、4K MKV、带字体附件 MKV），保存为 `docs/startup-baseline-2026-11-10.json/md`；验证：基线记录包含点击→首帧、prepare、open、probe、读取字节的中位/p90

## 2. 播放页即时呈现

- [x] 2.1 将 `LibraryPlaybackSession` 拆为 `preparing` / `active` / `failed` 三态，新增 `PendingPlayback`（entry + 占位图 + 取消 token）；点击时立即创建并展示播放页，占位图复用网格缩略图缓存，缺省时用纯色 + 标题；验证：UI 测试断言点击后 200ms 内播放页存在，且未发起新的缩略图抽帧
- [x] 2.2 将横屏请求提前到播放页出现时；`preparePlayback` 完成后只绑定 engine/renderer，不再创建会话；验证：iPad 模拟器点击 4K MKV，播放页先出现、容器就绪后画面接入，方向请求发生在 prepare 完成之前
- [x] 2.3 实现准备期间的取消与失败路径：返回键取消任务并停止后台读取，失败展示错误与返回入口，不残留 `NowPlaying` 或进度定时器；验证：单元测试取消后任务 `isCancelled`、读取计数不再增长；模拟器注入打开失败后播放页显示错误并可返回
- [ ] 2.4 补充 `LibraryView` 的呈现/取消/失败测试；验证：`IceMovieTests` 与 `IceMovieUITests` 新增用例全部通过

## 3. 字幕快速路径

- [x] 3.1 删除 `SubtitleLoader.load` 中的 `reader.attachments()` 与 `containerFonts()`，`LoadedSubtitles.fonts` 恒为空；内封字幕的二次 open 传 `fastProbe: true`；验证：单元测试加载内封/外挂 ASS 时 `fonts.isEmpty`，日志不再出现“容器字体附件”
- [x] 3.2 `preparePlayback` 返回内封轨与 `subtitleDiscoveryTask`，外挂扫描在后台执行；`LibraryStore` 缓存原始目录项供扫描复用；合并时内封在前、外挂在后、按 `(source, language, title)` 去重，并保留用户已选手动轨；验证：单元测试模拟外挂轨延迟 2 秒到达，播放已开始、合并后轨道数增加、手选轨不变
- [x] 3.3 更新字幕子系统的回归测试：内封 ASS、外挂三语 ASS、无字幕、位图字幕忽略、合并时切换轨；验证：新增用例全部通过，原有字幕测试无回归
- [x] 3.4 在 `docs/` 记录“容器字体被忽略”的行为与视觉影响，说明内置 CJK / CoreText 兜底策略；验证：文档与 `subtitle-rendering` delta 的「字体回退」场景逐条对应

## 4. 读取不再放大

- [x] 4.1 `AVIOBridge` 改为自适应窗口：`fastProbe` 从 64KB 起步、连续 4 次顺序填充后翻倍到 4MB，非连续 seek 回退 64KB；单次请求大于窗口时按请求大小读取；验证：单元测试 64KB 请求的网络读取 ≤256KB，连续 20 次顺序读后窗口达到 4MB，seek 后回到 64KB
- [ ] 4.2 `SMBFileByteSource` 增加精确读路径：`count < chunkSize` 时按请求区间取数，不按 1MB 对齐；新增 4 × 256KB 的小区间缓存；播放预读仍走 1MB 块 + 512MB 环；验证：单元测试在偏移 123 请求 64KB 时只发起 64KB `pread`，相邻小读第二次命中小区间缓存
- [x] 4.3 容器头区间不被 `seekWillChange` 淘汰；MP4 `moov` 在尾部时，返回头部读取命中已缓存数据；验证：单元测试模拟 `seek(0) → seek(end) → seek(0)`，第三次读取无网络请求
- [x] 4.4 补充 `AVIOBridge`、`SMBChunkRing`、`SMBFileByteSource` 的读取计数与边界测试（跨块、EOF、短读、seek 回退）；验证：新增用例全部通过，原有 130 个测试无回归

## 5. 容器头/尾持久缓存

- [x] 5.1 新增 `ContainerHeaderCache`：64KB 页、按 `namespace + path + size + mtime + 首 64KB 指纹` 定位、页位图索引、单文件 64MB / 全局 512MB 上限、LRU 淘汰；验证：单元测试覆盖命中、未命中、指纹变化失效、超限淘汰、损坏索引恢复
- [ ] 5.2 新增 `CachedByteSource` 包在 `SMBFileByteSource` 外层；`MediaReader` 增加打开阶段标记，打开阶段的读写入缓存，`PlaybackEngine.play()` 后停止写入；验证：同一文件二次打开 `headerCacheHitRatio > 0.8`，网络读取字节接近 0；播放阶段不新增缓存页
- [x] 5.3 缓存目录不可写、磁盘满、文件被删除时静默回退网络读，不阻塞播放；验证：单元测试注入不可写目录与写入失败，播放仍成功
- [x] 5.4 在 `README.md` 记录缓存位置、容量、失效规则与清理方式；验证：文档步骤可在模拟器上清空缓存并观察到二次打开重新走网络

## 6. 续播与起播水位

- [x] 6.1 `PlaybackEngine` 新增 `prepareSeek(to:)`：只重置读头、音频裁剪与视频关键帧预滚，不启动主时钟；`preparePlayback(_:startAt:)` 接收续播位置并在返回前完成定位；`LibraryView` 不再在 `play()` 后 seek；验证：单元测试首帧 PTS 落在续播位置附近，`play()` 后无额外 seek 请求
- [ ] 6.2 起播水位改为“1 帧视频 + ≤300ms 音频”，起播后 2 秒提升到 15s/15s；用 `SMBFileByteSource` 的 2.5 秒窗口与打开阶段平均速度估算吞吐，低于码率 1.5 倍时使用保守档（2s/1s）；验证：单元测试 fast/conservative 两档切换，模拟器限速 2MB/s 时进入保守档
- [ ] 6.3 续播定位失败回退到 0 秒并提示，起播后 30 秒缓冲次数纳入报告；验证：单元测试注入 seek 失败，播放从 0 开始且错误可观测
- [x] 6.4 补充 `PlaybackEngine` 的预滚、切换档位、欠载回退测试；验证：新增用例全部通过，原有播放测试无回归

## 7. FFmpeg 字体附件 patch

- [x] 7.1 在 `Vendor/ffmpeg/patches/` 新增 matroska `skip_font_attachments` patch：新增 AVOption、仅对字体 MIME 跳过 `FileData`、空 `bin` 静默跳过；`build.sh` 幂等应用 patch 并重建 device/simulator 静态库；验证：`patch --dry-run` 成功、重复执行不重复打补丁、两种架构构建成功
- [x] 7.2 `MediaReader.open(source:label:fastProbe:)` 在 `fastProbe` 时设置 `skip_font_attachments=1`；`DemuxProbe` 与缩略图路径保持 0；验证：单元测试断言播放首开的 options 含该键、探测路径不含
- [x] 7.3 用同时含字体与封面图的 MKV 验证：字体附件被跳过，`attachments()` 仍返回封面图；验证：样本文件打开后 `attachmentFontBytes = 0`、封面图字节 > 0，媒体库缩略图正常
- [x] 7.4 在 `Vendor/ffmpeg/README.md` 记录 patch 目的、应用方式与升级 FFmpeg 时的冲突处理；验证：按文档从干净源码重新应用并构建成功

## 8. 集成验收

- [ ] 8.1 运行 `IceMovieTests` 全量单元测试与 `IceMovieUITests` 关键用例；验证：全部通过，无新增失败
- [ ] 8.2 模拟器冷/热打开 10 条样本（含 MP4 尾部 moov、4K MKV、带字体附件 MKV）：记录 `playerPresentedMilliseconds`、prepare、open、probe、读取字节与缓存命中；验证：播放页出现 <200ms，热打开 prepare 中位 <1.2s
- [ ] 8.3 iPad 真机跑 20 条代表样本 + 2 小时随机测试：对比基线，确认点击→首帧达标率、prepare 中位/p90、缓存命中率与起播后 30 秒缓冲次数；验证：点击→首帧 1.5s 内比例 >80%，prepare 中位 <1.2s，起播后 30 秒缓冲次数 ≤1
- [x] 8.4 更新 `docs/acceptance-*.md/json` 与验收脚本，按新字段产出报告；验证：报告可由脚本重新生成，字段与 1.1 定义一致

## Workflow follow-up

- 代码审查与 8.3 真机结果确认后，归档本 change。
- 归档后复跑一次 `openspec validate --specs`，确认主 spec 无 delta 头残留。
