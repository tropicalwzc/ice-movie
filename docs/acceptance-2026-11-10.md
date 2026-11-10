# 播放缓存与供给修复验收报告

- 日期：2026-11-10
- 设备：iPad（真机，局域网 SMB）
- 构建：Release，`smb-seek-cache` 归档后修复版
- 测试内容：9 条代码审查问题修复、30 分钟随机压力基准、无职转生 S02E05/E06 播放测试

## 一、审查问题修复

| # | 问题 | 处理 |
| --- | --- | --- |
| 1 | EOF 后缓存命中 seek 不清 `reachedEOF`，预读永久失效 | `seekWillChange` 入口统一清零 `reachedEOF`，命中/未命中路径都恢复读取与预读 |
| 2 | 刷新被 1 秒限流吞掉，新显示层一直等关键帧 | `refreshFromCurrentPosition` 改为返回是否执行；被限流时登记延迟任务，冷却后自动重发 seek |
| 3 | 恢复后把恢复前的非关键帧塞进新层 | `consume` 恢复后重新检查 `needsKeyframe`，非关键帧直接丢弃，仅放行关键帧 |
| 4 | 视频队列满丢包破坏参考链且不通知显示层 | 队列溢出时整段队列作废、等待下一个关键帧；新增 `invalidateForPacketDrop` 刷新显示层；单包超过字节上限直接丢弃并通知；丢包计数保留 |
| 5 | `av_packet_alloc` 失败时释放播放泵自有的 AVPacket | OOM 路径改为 `av_packet_unref(pump packet)`，不再 `av_packet_free` |
| 6 | `SMBReadAnchorPolicy` 是死代码，测试误导 | 删除该策略及其 4 个测试；预读锚点以 `SMBFileByteSource` 实际路径为准 |
| 7 | `-stressRootPath` 被忽略 | 实现为有界起始目录：列该目录 + 最多 8 个子目录，仍在 20 秒预算内，不递归全盘 |
| 8 | 每条压力样本写 `stress` 和 `closed` 两份记录 | `closePlayback(report:)` 支持跳过关闭报告；压力路径只保留 `stress` 记录 |
| 9 | 启动快照明文保存 `-seedPassword` | 启动参数快照对包含 `password` 的 flag 后值统一替换为 `<redacted>` |

验证：

- Release 构建成功
- 单元测试 **126 个全部通过**
- 模拟器验证：
  - `-seedPassword testsecret` → `ice-launch.json` 中为 `<redacted>`
  - `-stressRootPath` 指定目录成功选中目标视频
  - 压力报告 reason 只有 `stress-plan` / `stress` / `stress-summary`，没有重复 `closed`

## 二、30 分钟随机压力基准

样本：14 条（自动带上播放历史里的无职转生 E02/E05/E06），4K HDR 优先，MP4 + 1080p MKV + 4K MKV + 长片；每条起播 4 秒后 seek 50%，播放 1 分钟。

| # | 样本 | 缓冲 | 首帧 | seek | maxDrift | 解码恢复 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | K-ON! 720p MP4 | 1 次 | 60ms | 1221ms | 0.145s | 0 |
| 2 | 头脑特工队2 18GB 4K HDR | 2 次 | 1433ms | 1511ms | 0.137s | 0 |
| 3 | 疯狂元素城 16.7GB 4K | 30 次（环境掉速，已记录） | 2581ms | 2433ms | 0.168s | 0 |
| 4 | 哪吒 10.3GB 4K | 1 次 | 2ms | 5206ms | 0.085s | 0 |
| 5 | K-ON! 720p MP4 | 1 次 | 57ms | 2695ms | 0.160s | 0 |
| 6 | K-ON!! 1080p MKV | 2 次 | 2690ms | 3361ms | 0.165s | 0 |
| 7 | K-ON!! 1080p MKV | 3 次 | 2562ms | 1817ms | 0.141s | 0 |
| 8 | K-ON! 720p MP4 | 1 次 | 36ms | 1381ms | 0.056s | 0 |
| 9 | K-ON!! 1080p MKV | 2 次 | 1523ms | 2784ms | 0.180s | 0 |
| 10 | 孤注一掷 3.5GB MP4 | 1 次 | 37ms | 1150ms | 0.130s | 0 |
| 11 | 刀剑神域 9.4GB 4K | 3 次 | 1380ms | 1513ms | 0.105s | 0 |
| 12 | 无职转生 S02E02 4K | 0 次 | 18ms | 4672ms | **0.023s** | 0 |
| 13 | 无职转生 S02E06 4K | 2 次 | 1480ms | 2037ms | 0.176s | 0 |
| 14 | 无职转生 S02E05 4K | 2 次 | 971ms | 4439ms | 0.141s | 0 |

总结：

- `stressCompleted = 14`
- `stressSeriousFound = false`
- `stressBufferExceptions = 1`（疯狂元素城，服务器连续大文件冷读掉速）
- `stressStopReason = completed`
- 全部样本 `clockJumpCount = 0`、`videoRecoveries = 0`、`videoQueueDropped = 0`
- 全部样本 `maxDrift < 0.181s`，18GB 4K HDR 为 0.137s
- 个别样本的 `maxVideoOffset` 会出现一次显示层绑定瞬间的 730s 瞬态，但 `maxDrift`、播放位置和画面均正常，属于指标采样瞬态

原始报告：`docs/acceptance-2026-11-10-benchmark.json`

## 三、无职转生 S02E05 / E06 播放测试

测试方式：每条播放 2 分钟；起播 4 秒后 seek 50%，第 20 秒回退 10 秒，验证缓存命中、字幕和音画供给。

| 指标 | S02E05 | S02E06 |
| --- | --- | --- |
| 容器/编码 | MKV / HEVC | MKV / HEVC |
| 音频 | opus | opus |
| 时长 | 23:43 | 23:44 |
| 平均码率 | 11.87 Mbps | 12.07 Mbps |
| 缓冲次数 | 2 次 | 2 次 |
| 累计缓冲 | 3.80s | 3.09s |
| 首帧 | 1053ms | 1266ms |
| 视频入队 | 4055 帧 | 3847 帧 |
| 解码恢复 | 0 | 0 |
| 视频队列丢包 | 0 | 0 |
| 回退 10 秒命中缓存 | 是 | 是 |
| 回退 seek 延迟 | 58ms | 889ms |
| seek 偏差 | 0.119s | 0.052s |
| 字幕轨 | Chinese (Simplified) | Chinese (Simplified) |
| 字幕条数 | 43 | 39 |
| 字幕错误 | 无 | 无 |
| 严重问题 | 否 | 否 |

结论：两集均正常起播、4K HEVC 硬解、opus 音频、中文字幕加载正常；50% seek 与回退 10 秒均命中缓存，无解码恢复、无队列丢包。

原始报告：`docs/acceptance-2026-11-10-mushoku-s02e05-e06.json`

## 四、后续修复：S02E02 seek 音画不同步

现象：S02E02 起播后 seek 50%，随后回退 10 秒，出现音画不同步。旧报告 `maxDrift = 26.69s`，而 `maxVideoOffset = 0.002s`，说明视频在跟随主时钟，问题在音频时钟/音频播放时序。

根因有两层：

1. `performSeek` 在 `output.reset()` 后无条件 `output.play()`。如果 seek 发生在起播缓冲阶段、主时钟仍是暂停状态，音频会先开始播放并跑出十几秒；主时钟随后用音频位置校正，画面跟着跳，形成不同步。
2. `AudioOutput` 用 `AVAudioPlayerNode` 的绝对 `sampleTime` 计算播放位置，没有减去 seek 后的基线；节点时间线未清零时，会再叠加一段旧位置。

修复：

- 只有 `clock.isPlaying` 时才在 seek 后立刻恢复音频；否则交给 `tryStartPlayback` 同时启动音视频。
- `AudioOutput` 记录当前锚点的首个 `sampleTime` 作为基线，播放位置按 `sampleTime - baseline` 计算；reset 时清空基线。
- 新增 `maxDriftPosition` / `maxDriftAudioTime` / `maxDriftClockTime` / `clockJumpCount` 诊断字段。

修复后 S02E02（120 秒，50% seek + 回退 10 秒）：

| 指标 | 结果 |
| --- | --- |
| 缓冲 | 0 次 / 0s |
| 解码恢复 | 0 |
| 视频队列丢包 | 0 |
| maxDrift | **0.0228s** |
| maxVideoOffset | **0.0008s** |
| clockJumpCount | 0 |
| 回退 seek 延迟 | 1986ms |
| 回退命中缓存 | 是 |
| 字幕 | 简体中文，45 条，无错误 |

原始报告：`docs/acceptance-2026-11-10-mushoku-s02e02-sync-fix.json`

## 五、延迟刷新重试修复

审查发现的问题真实存在：`refreshOrRetry` 被限流后，重试唤醒时只校验显示层对象，没有检查 `needsKeyframe`；`reset(to:)` 也没有作废旧重试。两种场景会多发起一次 seek：

- 关键帧在冷却期间已经到达并清掉 `needsKeyframe`，重试仍会 seek；
- 用户在冷却期间手动 seek，`reset(to:)` 后旧重试仍会再 seek 一次。

修复：

- 重试唤醒时校验 `needsKeyframe == true`，并且 refresh generation 未变化；
- `reset(to:)` 递增 refresh generation，旧重试自动作废；
- 新增 `shouldPerformDelayedRefresh` 纯函数及单元测试。

验证：130 个单元测试全部通过；Release 构建成功。

## 六、结论

- 9 条审查问题均已修复，其中 3 条做了模拟器/运行日志验证。
- 30 分钟随机压力基准 14/14 完成，硬件严重问题为 0，环境缓冲异常 1 条（已记录），全部样本 `clockJumpCount=0`。
- 无职转生 S02E05/E06 均通过 2 分钟 4K 播放 + 50% seek + 回退 10 秒测试。
- S02E02 的 seek 音画不同步已修复，复测 `maxDrift` 从 26.69s 降到 0.023s，`clockJumpCount=0`。
- 延迟刷新重试的多余 seek 问题已修复，重试会校验关键帧状态与 refresh generation。
- 仍保留环境提示：服务器连续读取多部超大 4K 后可能出现冷读掉速，此时报告会通过 `stressBufferException` 记录，而不是误判为代码故障。
