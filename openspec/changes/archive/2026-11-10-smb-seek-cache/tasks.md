# Tasks

## 1. 预读环的区间能力

- [x] 1.1 为 `SMBChunkRing` 增加连续区间查询：给定偏移和长度，返回是否连续命中以及连续末尾；用单元测试覆盖跨块、缺口、EOF 短块
- [x] 1.2 为 `SMBChunkRing` 增加按区间裁剪 `trim(keepFrom:keepTo:)`，保留回看段与前向段；用单元测试验证区间外数据被删除、区间内数据保留
- [x] 1.3 将容量淘汰改为按离播放头的距离排序，先丢最远回看、再丢最远前向；用单元测试构造回看/前向混合场景验证保留顺序

## 2. 读窗口与 seek 分类

- [x] 2.1 在 `SMBFileByteSource` 引入 `playhead`、`readHead`、`prefetchHead`、`windowStart`，替换 `lastReadEnd` 的三种职责；用现有播放路径验证顺序读取行为不变
- [x] 2.2 实现 `seekWillChange` 三分类：连续缓存命中、回看窗口命中、完全未命中；单元测试或可注入的假句柄覆盖三类分支
- [x] 2.3 命中连续缓存时只移动播放头/读头，不清空预读环、不取消预读任务；验证 seek 后 `ringResetCount` 不增加
- [x] 2.4 完全未命中时丢弃前向窗口、保留有界回看、先读目标位置第一块；验证下一次读取命中该块且随后预读从读头向前推进
- [x] 2.5 预读起点改为 `max(readHead, target)`，旧任务用 generation 隔离；验证旧任务晚返回不会写入新窗口

## 3. 播放引擎与进度条

- [x] 3.1 在 `PlaybackEngine` 用播放时间、总时长和文件大小估算播放字节偏移，并提供从播放头起算的连续缓冲秒数；单元测试覆盖正常播放、seek 后、接近结尾
- [x] 3.2 `bufferedAheadBytes` 改为从播放头到 `prefetchHead` 计算，缺口时截断到缺口前；验证进度条浅绿色区间在 seek 后不清零
- [x] 3.3 回看窗口预算默认 20 秒、上限 64MB，按平均码率换算并接入 `setRetainBackBytes`；验证高码率长片不会超预算
- [x] 3.4 在验收报告增加 `seekCacheHit`、`bufferedAheadSeconds`、`ringResetCount`；用一次命中 seek 和一次未命中 seek 验证字段变化

## 4. 开关与诊断

- [x] 4.1 增加 `-smbSeekCache 0` 回退开关，关闭时保持旧的 seek 清空环行为；验证两种模式都能起播
- [x] 4.2 在 `ice-smb.log` 记录 seek 分类、命中区间、预读起点和 reset 原因；验证一次回退 seek 日志中只出现一次必要的窗口操作

## 6. 视频包供给解耦

- [x] 6.1 新增 `VideoPacketPipeline`：独立串行工作线程、有界 AVPacket 队列、`av_packet_move_ref` 所有权转移、flush/stop；验证队列释放不泄漏
- [x] 6.2 播放泵把视频包移交给队列，音频解码和字幕处理仍留在泵上；验证音频包处理不再被视频包封装阻塞
- [x] 6.3 seek 时 flush 视频队列并递增 generation，工作线程丢弃旧 generation 包；验证连续拖动后只显示最后一次跳转的画面
- [x] 6.4 视频队列包数/字节双上限，满时优先丢最老非关键帧并计数；验证长时间播放队列不增长
- [x] 6.5 记录最近音频/视频包的 `pos/pts`，用实际包位置修正播放头字节估算；验证 VBR 4K 上绿色区间不再长期为 0–1 秒
- [x] 6.6 iPad 真机用 18GB 4K HDR 预检：音频领先 > 3 秒、视频队列有界、缓冲次数明显下降；通过后再进入 5.3/5.4

## 5. 回归与真机验收

- [x] 5.1 运行完整单元测试（`IceMovieTests`），验证 124 个以上测试全部通过
- [x] 5.2 模拟器用本地 312MB MP4 与 10GB 长片验证起播、连续回退 5 次、进度条绿色区间和零解码恢复
- [x] 5.3 完成第 6 组后，iPad 真机用 18GB 4K HDR 验证：回退 10 秒命中缓存、seek 后首帧 < 1 秒、音频领先 > 3 秒、缓冲次数 < 6 次/分钟
- [x] 5.4 完成第 6 组后，iPad 真机跑完整随机压力测试（4K/MP4/长片，每条 seek 50% 后播放 1 分钟），验证无严重问题并输出报告（12/12 完成；硬件严重=0；疯狂元素城 1 条过热掉速记入 `stressBufferExceptions`）
- [x] 5.5 更新 README 的预读与 seek 说明，写入回看窗口、`-smbSeekCache` 开关和验收指标；验证文档命令可直接执行

## Workflow follow-up

- 真机验收通过并完成评审后归档本次 change。
- 归档后确认 `openspec/specs/smb-read-cache/spec.md` 的 Purpose 与需求已正确合并。
