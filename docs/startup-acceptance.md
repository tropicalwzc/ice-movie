# 起播延迟验收

## 产物

- App 沙盒 `Documents/ice-acceptance.json`：每条播放记录追加一条，`reason` 为 `closed` / `stress` / `replaced`。
- `Scripts/startup-acceptance.py`：汇总起播字段的中位、p90、均值与 1.5 秒达标率。

## 运行

```bash
# 模拟器：先取容器路径
DATA=$(xcrun simctl get_app_container <udid> com.wangzicheng.icemovie data)
python3 Scripts/startup-acceptance.py "$DATA/Documents/ice-acceptance.json"

# 真机：Xcode > Window > Devices and Simulators > Download Container
python3 Scripts/startup-acceptance.py <下载后的>/AppData/Documents/ice-acceptance.json
```

## 字段

| 字段 | 单位 | 含义 |
|---|---|---|
| `playerPresentedMilliseconds` | ms | 点击到播放页出现（占位图已可见） |
| `prepareMilliseconds` | ms | 点击到容器探测、字幕发现、引擎创建完成 |
| `openInputMilliseconds` | ms | `avformat_open_input` |
| `streamInfoMilliseconds` | ms | `avformat_find_stream_info` |
| `firstVideoMilliseconds` | ms | 播放开始到首帧入队 |
| `openBytesRead` | byte | 打开阶段真实网络读取量（不含容器头缓存命中） |
| `openReadCount` | 次 | 打开阶段字节源读取次数 |
| `avioFillCount` | 次 | AVIO 窗口填充次数 |
| `attachmentBytes` | byte | 附件总字节（不含已跳过字体） |
| `attachmentFontBytes` | byte | 附件中字体字节 |
| `skippedFontCount` | 个 | FFmpeg 跳过的字体数量 |
| `headerCacheHitBytes` | byte | 容器头缓存命中字节 |
| `headerCacheHitRatio` | 0–1 | 容器头缓存命中比例 |
| `subtitleScanMilliseconds` | ms | 起播后外挂字幕扫描耗时 |
| `startupBufferStalls` | 次 | 起播后 30 秒内缓冲次数 |
| `lastSeekTimebaseOffset` | s | seek 完成时的显示层时间基偏差；窗口内 tick 采样不会覆盖它 |
| `maxSeekTimebaseOffset` | s | seek 后 2 秒内该偏差的最大值；>1s 表示画面可能停住/追赶 |
| `seekTimebaseJumpCount` | 次 | 时间基偏差超过 1 秒的次数；每次 seek 最多计 1 次 |

## 目标

- `playerPresentedMilliseconds` < 200ms；
- `prepareMilliseconds` 中位 < 1.2s；
- 点击→首帧 1.5s 内比例 > 80%；
- 起播后 30 秒 `startupBufferStalls` ≤ 1。
