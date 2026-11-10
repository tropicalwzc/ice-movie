# iPad 真机 30 分钟随机起播验收（2026-11-10）

- 设备：iPad Air 11-inch (M2)，iOS 27.0.1
- 主机：`TROPICAL-ADVPC.local`（SMB）
- 共享：`RecentWatched` + `Animi`
- 存储：PCIe 4.0 SSD（无服务端磁盘瓶颈）
- 运行：27 次播放，21 个唯一文件；约 32 分钟
- 构建：Release，`startup-latency` 实现版
- 原始数据：`docs/startup-acceptance-2026-11-10-ipad-30min.json`

## 总体结果

| 指标 | min | p50 | p90 | max | mean |
|---|---:|---:|---:|---:|---:|
| 播放页出现 `playerPresentedMilliseconds` | 18ms | 24ms | 27ms | 32ms | 23.5ms |
| prepare | 69ms | 359ms | 974ms | 1025ms | 422ms |
| `open_input` | 0ms | 146ms | 739ms | 946ms | 246ms |
| `stream_info` | 0ms | 2ms | 168ms | 282ms | 38ms |
| 播放→首帧 | 13ms | 43ms | 562ms | 1139ms | 150ms |
| 点击→首帧 ≤1.5s | **26/27（96.3%）** | | | | |
| `openBytesRead` | 64KB | 1.48MB | 11.2MB | 11.8MB | 3.0MB |
| `headerCacheHitRatio` | 0.8% | 6.7% | 79.7% | 83.3% | 23.4% |
| 起播后 30s 缓冲次数 | 0 | 0 | 1 | 2 | 0.44 |
| `maxDrift` | 0.022s | 0.065s | 0.120s | 0.128s | 0.066s |

- 严重问题：**0**
- 缓冲异常：**0**
- 文件异常：**0**
- `clockJumpCount > 0`：**0**
- 起播水位档位：26 次 `fast`，1 次 `conservative`（热打开被旧吞吐估算误判，已修正为“缓存命中/读取 <512KB 时按未知处理”）

## 对比基线

| 指标 | 旧基线（78 条 SMB） | 本次真机 27 次 |
|---|---:|---:|
| prepare p50 | 3788ms | **359ms** |
| open_input p50 | 1833ms | **146ms** |
| stream_info p50 | 0ms | 2ms |
| 点击→首帧 ≤1.5s | 14%（86% 超时） | **96.3%** |
| 播放→首帧 p50 | 37ms | 43ms |

## 分场景

### RecentWatched（15 次）

- `[Aideo` / `[Cideo` / `四月`
- 全部 `completed`，0 严重/缓冲/文件异常
- 多数 MP4：prepare 中位 ~378ms，播放页 24ms，首帧 42ms
- `四月` HEVC 10-bit + FLAC 两集：prepare 378~481ms，但播放→首帧 1.08~1.14s；其中第 13 集点击→首帧 1.62s，是唯一未达标样本，伴随 2 次起播后缓冲（0.81s）

### Animi（12 次）

- `无职转生第二季`、`LoliHouse`、`re0 s3`、 `四月` 等
- 4K Re:Zero S02E10：prepare 452ms、open 392ms、读取 1.5MB、`skippedFontCount=11`、首帧 55ms
- 1080p MKV：prepare 69~230ms，open 0~48ms，读取 64~130KB
- `Kono Kaisha` 热打开：prepare 69ms、读取 64KB、首帧 41ms

## 关键发现

1. **播放页即时呈现生效**：27 次全部 18~32ms 出现播放页，用户不再盯着媒体库网格等待。
2. **prepare 从 3.8s 降到 0.36s（p50）**：open_input 从 1.8s 降到 146ms；`stream_info` 基本为 0，说明快速探测与容器头信息路径在真机生效。
3. **字体附件跳过生效**：4 个样本有字体附件，`attachmentFontBytes` 全为 0，`skippedFontCount` 最大 21；4K Re:Zero 跳过 11 个字体仍正常起播。
4. **剩余慢点集中在“大索引 MP4”**：
   - `[Cideo/IPX-857.mp4`：open 946ms、读取 11.8MB（MP4 尾部 moov/索引）；
   - `隐入尘烟`：open 683ms、读取 10.3MB。
   这两类文件仍值得做“索引区预读/持久缓存”，但已不影响 1.5s 达标率。
5. **HEVC 10-bit + FLAC 的起播后首帧**：`四月` 两集播放→首帧 1.08~1.14s；prepare 本身很快，慢在音频/解码管线启动。后续可针对 FLAC/多音轨的首帧路径单独打点。
6. **缓存命中率**：随机测试以冷打开为主（p50 6.7%），重复打开的热样本可到 83.3%；这与“随机 21 个唯一文件”的测试方式一致，不代表缓存无效。

## 结论

- 本次 30 分钟真机测试达到目标：播放页 <200ms、prepare 中位 <1.2s、点击→首帧 1.5s 内 96.3%、起播后 30s 缓冲 ≤2 次。
- 唯一未达标样本是 `四月` 第 13 集（1.62s），属于 FLAC/HEVC 首帧路径，不是 SMB 读取瓶颈。
- 下一步优先级：大索引 MP4 的头/尾缓存命中（当前已有 11.8MB 读取上限）、FLAC 首帧启动、以及把热打开误判 conservative 的估算修正在真机复测中确认。
