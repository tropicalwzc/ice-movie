# 2 小时随机打开视频测试报告

- 日期：2026-11-10
- 设备：iPad 真机，局域网 SMB
- 构建：Release
- 测试方式：随机打开视频，播放 60 秒后 seek 到 66.67%，再播放 25 秒
- 时间上限：7200 秒
- 实际覆盖：第一阶段 02:52–04:03（45 条），第二阶段 04:07–05:08（33 条），合计约 2 小时 11 分钟；78 条

## 总体结果

- 完成视频：**78** 条
- 候选样本：580，计划抽取：78
- 硬件严重问题：0
- 环境缓冲异常（已记录）：2
- 音画同步异常：0（同步通过 78/78，100.0%）
- seek 命中缓存：7/78（9.0%）
- 解码恢复总数：223，视频队列丢包总数：362
- 文件/内容异常（已记录）：4
- 总结状态：completed，严重=False，环境缓冲=2，同步异常=0

## 启动耗时

- 点击 → 首帧：最小 866ms / 平均 10558ms / 最大 85702ms
- 准备（SMB 打开 + 探测 + 字幕 + 引擎）：最小 811ms / 平均 9838ms / 最大 85644ms
- 容器打开：最小 665ms / 平均 6544ms / 最大 56324ms
- 流信息探测：最小 0ms / 平均 1945ms / 最大 24595ms
- 播放开始 → 首帧：最小 0ms / 平均 720ms / 最大 25907ms

> 起播优化：首次点击不再预填 512MB；预读在首帧真正开播后才启动。播放首开优先使用容器头流信息，缺少参数时才回退完整探测。

## 音画同步

- 整体 maxDrift：最小 0.000s / 平均 0.099s / 最大 0.179s
- seek 后 lastSeekDrift：最小 0.000s / 平均 0.049s / 最大 0.265s
- 显示层 maxVideoOffset（有效值）：最小 0.000s / 平均 0.031s / 最大 0.551s
- maxVideoOffset > 10s 的采样瞬态：23 条（显示层绑定/seek 瞬间指标，不参与同步判定）
- `clockJumpCount > 0` 的样本：0

## Seek 与缓冲

- seek 延迟：最小 22ms / 平均 5597ms / 最大 53901ms
- 每条总缓冲次数：最小 0 次 / 平均 1 次 / 最大 12 次
- seek 后新增缓冲次数：最小 0 次 / 平均 1 次 / 最大 10 次
- 每条累计缓冲：最小 0.000s / 平均 4.327s / 最大 56.833s

## 字幕

- 字幕条数：最小 0 条 / 平均 6 条 / 最大 65 条
- 字幕错误：0 条

## 启动最慢的 10 条

| # | 文件 | 点击→首帧 | 准备 | 打开 | 探测 | 首帧 |
|---|---|---|---|---|---|---|
| 49 | Study/FSDSS-114.mp4 | 85702ms | 85644ms | 56324ms | 23701ms | 58ms |
| 53 | …- 01 [WebRip][1080P][AVC 8bit][CHS].mp4 | 60187ms | 60133ms | 30193ms | 24595ms | 54ms |
| 52 | …igokuraku][06][GB][1080P][x264_AAC].mp4 | 53884ms | 53831ms | 25418ms | 22838ms | 53ms |
| 57 | ….1080p.BluRay.x265.10bit.AC3-BitsTV.mkv | 51957ms | 26050ms | 19947ms | 0ms | 25907ms |
| 56 | ….HK.BD-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 49958ms | 49944ms | 22949ms | 20484ms | 14ms |
| 50 | …on.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 48567ms | 48567ms | 32394ms | 0ms | 0ms |
| 51 | ….HK.BD-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 48039ms | 48026ms | 19509ms | 21850ms | 13ms |
| 54 | …1080p.NF.WEB-DL.H264.DDP5.1-NexusNF.mkv | 27810ms | 27785ms | 22023ms | 0ms | 25ms |
| 55 | …on.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 27418ms | 27418ms | 21741ms | 0ms | 0ms |
| 48 | ….WEB-DL.DDP.7.1.Atmos.H.265-DreamHD.mkv | 25300ms | 25288ms | 19883ms | 0ms | 12ms |

## Seek 最慢的 10 条

| # | 文件 | seek | 命中 | maxDrift | seek 后缓冲 |
|---|---|---|---|---|---|
| 50 | …on.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 53901ms | False | 0.000s | 0 次 |
| 55 | …on.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 53748ms | False | 0.000s | 0 次 |
| 54 | …1080p.NF.WEB-DL.H264.DDP5.1-NexusNF.mkv | 50662ms | False | 0.021s | 0 次 |
| 47 | ….DDP.5.1.Atmos.DV.HDR.H.265-DreamHD.mkv | 44891ms | False | 0.021s | 0 次 |
| 48 | ….WEB-DL.DDP.7.1.Atmos.H.265-DreamHD.mkv | 44508ms | False | 0.021s | 0 次 |
| 57 | ….1080p.BluRay.x265.10bit.AC3-BitsTV.mkv | 23471ms | False | 0.064s | 0 次 |
| 51 | ….HK.BD-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 22605ms | False | 0.069s | 1 次 |
| 56 | ….HK.BD-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 17529ms | False | 0.064s | 1 次 |
| 46 | …- Google Chrome 2025-05-10 15-47-45.mp4 | 10738ms | False | 0.084s | 1 次 |
| 2 | ….DDP.5.1.Atmos.DV.HDR.H.265-DreamHD.mkv | 4944ms | False | 0.123s | 10 次 |

## 逐条明细

| # | 文件 | 启动 | 准备 | 打开 | 探测 | 首帧 | 同步 | 文件异常 | maxDrift | seek | 命中 | seek后缓冲 | 总缓冲 | 恢复 | 字幕 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | …WebRip][1080P][AVC 8bit][CHS].mp4 | 2478ms | 2422ms | 1143ms | 945ms | 56ms | ✓ | — | 0.022s | 68ms | ✓ | 0 次 | 0 次 | 0 | 0 |
| 2 | ….1.Atmos.DV.HDR.H.265-DreamHD.mkv | 1509ms | 1490ms | 1375ms | 0ms | 19ms | ✓ | — | 0.123s | 4944ms | ✗ | 10 次 | 11 次 | 0 | 0 |
| 3 | …L.DDP.7.1.Atmos.H.265-DreamHD.mkv | 2157ms | 2138ms | 1642ms | 0ms | 19ms | ✓ | — | 0.104s | 3250ms | ✗ | 2 次 | 2 次 | 0 | 0 |
| 4 | ….WEB-DL.DDP.5.1.H.265-BlackTV.mkv | 2467ms | 2446ms | 1770ms | 0ms | 21ms | ✓ | — | 0.119s | 1774ms | ✗ | 1 次 | 1 次 | 0 | 31 |
| 5 | Study/IPX-451.mp4 | 6933ms | 6880ms | 6305ms | 5ms | 53ms | ✓ | — | 0.105s | 2231ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 6 | …-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 4655ms | 4633ms | 1978ms | 1998ms | 22ms | ✓ | — | 0.130s | 2006ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 7 | …80 x264 AAC Sub(GB,Big5,Jap)].mkv | 11449ms | 11426ms | 11166ms | 0ms | 23ms | ✓ | — | 0.110s | 1838ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 8 | …p 1080p HEVC-10bit AAC ASSx2].mkv | 2451ms | 2446ms | 1784ms | 0ms | 5ms | ✓ | — | 0.138s | 2091ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 9 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4095ms | 2229ms | 1566ms | 0ms | 1866ms | ✓ | — | 0.104s | 2390ms | ✗ | 1 次 | 2 次 | 0 | 20 |
| 10 | …1280x720][x264_AAC][3F22932C].mp4 | 4545ms | 4508ms | 1789ms | 2048ms | 37ms | ✓ | — | 0.082s | 1930ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 11 | …-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 4413ms | 4408ms | 1749ms | 1940ms | 5ms | ✓ | — | 0.120s | 2034ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 12 | Study/FSDSS-489.mp4 | 1930ms | 1909ms | 1742ms | 12ms | 21ms | ✓ | — | 0.124s | 1027ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 13 | Study/PPPE-062.mp4 | 3847ms | 3788ms | 2695ms | 948ms | 59ms | ✓ | — | 0.118s | 1034ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 14 | …X264.AAC.English.CHS-ENG.BDE4.mp4 | 869ms | 811ms | 665ms | 2ms | 58ms | ✓ | — | 0.121s | 1230ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 15 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 2845ms | 1715ms | 1523ms | 0ms | 1130ms | ✓ | — | 0.177s | 1131ms | ✗ | 1 次 | 2 次 | 0 | 15 |
| 16 | …80 x264 AAC Sub(GB,Big5,Jap)].mkv | 5888ms | 4566ms | 4368ms | 0ms | 1322ms | ✓ | — | 0.120s | 1124ms | ✗ | 1 次 | 2 次 | 0 | 46 |
| 17 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 3207ms | 1028ms | 815ms | 0ms | 2179ms | ✓ | — | 0.106s | 1781ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 18 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4046ms | 1867ms | 1385ms | 0ms | 2179ms | ✓ | — | 0.125s | 1810ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 19 | Study/MIAA-466.mp4 | 3228ms | 3210ms | 2751ms | 11ms | 18ms | ✓ | — | 0.095s | 1689ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 20 | Study/ssni-477-C.mp4 | 6593ms | 6539ms | 4424ms | 1606ms | 54ms | ✓ | — | 0.073s | 1700ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 21 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 3858ms | 1831ms | 1319ms | 0ms | 2027ms | ✓ | — | 0.107s | 1746ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 22 | …-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 2407ms | 2391ms | 1738ms | 0ms | 16ms | ✓ | — | 0.138s | 2206ms | ✗ | 2 次 | 2 次 | 0 | 0 |
| 23 | Study/FSDSS-099.mp4 | 7722ms | 7669ms | 5288ms | 1837ms | 53ms | ✓ | — | 0.114s | 2043ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 24 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4367ms | 2142ms | 1447ms | 0ms | 2225ms | ✓ | — | 0.157s | 1875ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 25 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4154ms | 2088ms | 1337ms | 0ms | 2066ms | ✓ | — | 0.158s | 1818ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 26 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 3927ms | 1847ms | 1332ms | 0ms | 2080ms | ✓ | — | 0.102s | 1920ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 27 | …80p HEVC-yuv420p10 AAC ASSx2].mkv | 2221ms | 2217ms | 1658ms | 0ms | 4ms | ✓ | — | 0.051s | 2099ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 28 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4078ms | 1862ms | 1335ms | 0ms | 2216ms | ✓ | — | 0.116s | 1731ms | ✗ | 1 次 | 2 次 | 0 | 1 |
| 29 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4079ms | 2051ms | 1525ms | 0ms | 2028ms | ✓ | — | 0.155s | 1749ms | ✗ | 1 次 | 2 次 | 0 | 7 |
| 30 | …p 2160p HEVC OPUS Multi-Subs].mkv | 15696ms | 15680ms | 15021ms | 0ms | 16ms | ✓ | — | 0.151s | 3296ms | ✗ | 1 次 | 1 次 | 0 | 26 |
| 31 | …p 2160p HEVC OPUS Multi-Subs].mkv | 16529ms | 16504ms | 16026ms | 0ms | 25ms | ✓ | — | 0.150s | 3129ms | ✗ | 1 次 | 1 次 | 0 | 24 |
| 32 | …x1080][x264_FLAC_3][A6E60001].mkv | 2580ms | 2574ms | 1890ms | 0ms | 6ms | ✓ | — | 0.112s | 1997ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 33 | …x1080][x264_FLAC_3][C63BCC0C].mkv | 6335ms | 6326ms | 3482ms | 0ms | 9ms | ✓ | — | 0.159s | 2916ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 34 | …1280x720][x264_AAC][C8CD064B].mp4 | 6559ms | 6522ms | 2732ms | 2653ms | 37ms | ✓ | — | 0.074s | 3532ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 35 | …WebRip][1080P][AVC 8bit][CHS].mp4 | 6622ms | 6586ms | 3075ms | 2734ms | 36ms | ✓ | — | 0.088s | 2444ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 36 | …x1080][x264_FLAC_3][7C265FA9].mkv | 1147ms | 1134ms | 877ms | 0ms | 13ms | ✓ | — | 0.139s | 986ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 37 | …80 x264 AAC Sub(GB,Big5,Jap)].mkv | 12026ms | 10754ms | 10587ms | 0ms | 1272ms | ✓ | — | 0.174s | 1038ms | ✗ | 1 次 | 2 次 | 0 | 50 |
| 38 | …80p HEVC-yuv420p10 AAC ASSx2].mkv | 1084ms | 1064ms | 884ms | 0ms | 20ms | ✓ | — | 0.085s | 1919ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 39 | …-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 4031ms | 4009ms | 1721ms | 1702ms | 22ms | ✓ | — | 0.081s | 3648ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 40 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4185ms | 2198ms | 1539ms | 1ms | 1987ms | ✓ | — | 0.162s | 981ms | ✗ | 1 次 | 2 次 | 0 | 11 |
| 41 | …-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 1071ms | 1048ms | 882ms | 0ms | 23ms | ✓ | — | 0.144s | 944ms | ✗ | 1 次 | 1 次 | 0 | 26 |
| 42 | …1280x720][x264_AAC][03D96245].mp4 | 4801ms | 4762ms | 1833ms | 2460ms | 39ms | ✓ | — | 0.124s | 1905ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 43 | …X264.AAC.English.CHS-ENG.BDE4.mp4 | 1933ms | 1877ms | 1373ms | 3ms | 56ms | ✓ | — | 0.147s | 1791ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 44 | … S2 - 03 [BD 1080p x265 FLAC].mkv | 5999ms | 5976ms | 5826ms | 0ms | 23ms | ✓ | — | 0.106s | 1906ms | ✗ | 1 次 | 1 次 | 0 | 65 |
| 45 | …p 1080p HEVC-10bit AAC ASSx2].mkv | 988ms | 973ms | 813ms | 0ms | 15ms | ✓ | ✓ | 0.023s | 81ms | ✓ | 3 次 | 12 次 | 222 | 0 |
| 46 | …le Chrome 2025-05-10 15-47-45.mp4 | 21478ms | 21418ms | 11095ms | 9752ms | 60ms | ✓ | — | 0.084s | 10738ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 47 | ….1.Atmos.DV.HDR.H.265-DreamHD.mkv | 24740ms | 24727ms | 19876ms | 0ms | 13ms | ✓ | — | 0.021s | 44891ms | ✗ | 0 次 | 1 次 | 0 | 0 |
| 48 | …L.DDP.7.1.Atmos.H.265-DreamHD.mkv | 25300ms | 25288ms | 19883ms | 0ms | 12ms | ✓ | — | 0.021s | 44508ms | ✗ | 0 次 | 1 次 | 0 | 0 |
| 49 | Study/FSDSS-114.mp4 | 85702ms | 85644ms | 56324ms | 23701ms | 58ms | ✓ | — | 0.065s | 22ms | ✗ | 0 次 | 4 次 | 0 | 0 |
| 50 | …-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 48567ms | 48567ms | 32394ms | 0ms | 0ms | ✓ | ✓ | 0.000s | 53901ms | ✗ | 0 次 | 0 次 | 0 | 0 |
| 51 | …-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 48039ms | 48026ms | 19509ms | 21850ms | 13ms | ✓ | — | 0.069s | 22605ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 52 | …aku][06][GB][1080P][x264_AAC].mp4 | 53884ms | 53831ms | 25418ms | 22838ms | 53ms | ✓ | — | 0.079s | 37ms | ✗ | 1 次 | 4 次 | 0 | 0 |
| 53 | …WebRip][1080P][AVC 8bit][CHS].mp4 | 60187ms | 60133ms | 30193ms | 24595ms | 54ms | ✓ | — | 0.061s | 39ms | ✗ | 0 次 | 3 次 | 0 | 0 |
| 54 | …NF.WEB-DL.H264.DDP5.1-NexusNF.mkv | 27810ms | 27785ms | 22023ms | 0ms | 25ms | ✓ | — | 0.021s | 50662ms | ✗ | 0 次 | 1 次 | 0 | 0 |
| 55 | …-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 27418ms | 27418ms | 21741ms | 0ms | 0ms | ✓ | ✓ | 0.000s | 53748ms | ✗ | 0 次 | 0 次 | 0 | 0 |
| 56 | …-1080p.X264.AAC.CHS.ENG-UUMp4.mp4 | 49958ms | 49944ms | 22949ms | 20484ms | 14ms | ✓ | — | 0.064s | 17529ms | ✗ | 1 次 | 2 次 | 0 | 0 |
| 57 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 51957ms | 26050ms | 19947ms | 0ms | 25907ms | ✓ | — | 0.064s | 23471ms | ✗ | 0 次 | 3 次 | 0 | 2 |
| 58 | ….BluRay.x265.10bit.AC3-BitsTV.mkv | 4382ms | 2376ms | 1803ms | 0ms | 2006ms | ✓ | — | 0.179s | 1772ms | ✗ | 1 次 | 2 次 | 0 | 20 |
| 59 | …le Chrome 2025-03-27 22-08-17.mp4 | 4504ms | 4447ms | 1990ms | 1670ms | 57ms | ✓ | — | 0.030s | 84ms | ✓ | 0 次 | 0 次 | 0 | 0 |
| 60 | …nd Blue][06][x264 1080p][CHS].mp4 | 4020ms | 3894ms | 1826ms | 1564ms | 126ms | ✓ | — | 0.024s | 51ms | ✓ | 0 次 | 0 次 | 0 | 0 |
| 61 | …p 1080p HEVC-10bit AAC ASSx2].mkv | 1249ms | 1239ms | 1032ms | 0ms | 10ms | ✓ | — | 0.145s | 1753ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 62 | …le Chrome 2025-08-21 00-57-46.mp4 | 4923ms | 4867ms | 2344ms | 1817ms | 56ms | ✓ | — | 0.031s | 73ms | ✓ | 0 次 | 0 次 | 0 | 0 |
| 63 | …x1080][x264_FLAC_3][F71736B7].mkv | 1264ms | 1252ms | 1023ms | 0ms | 12ms | ✓ | — | 0.102s | 1036ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 64 | …p 2160p HEVC OPUS Multi-Subs].mkv | 7648ms | 7602ms | 7287ms | 1ms | 46ms | ✓ | ✓ | 0.151s | 1617ms | ✗ | 1 次 | 2 次 | 1 | 29 |
| 65 | Study/miaa-484.mp4 | 2286ms | 2227ms | 2039ms | 8ms | 59ms | ✓ | — | 0.112s | 992ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 66 | …x1080][x264_FLAC_3][A6E60001].mkv | 866ms | 842ms | 744ms | 0ms | 24ms | ✓ | — | 0.105s | 881ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 67 | …-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 973ms | 968ms | 847ms | 0ms | 5ms | ✓ | — | 0.023s | 2062ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 68 | …80 x264 AAC Sub(GB,Big5,Jap)].mkv | 24316ms | 22463ms | 21761ms | 0ms | 1853ms | ✓ | — | 0.137s | 1063ms | ✗ | 1 次 | 2 次 | 0 | 34 |
| 69 | …le Chrome 2025-05-10 15-59-10.mp4 | 1969ms | 1911ms | 929ms | 782ms | 58ms | ✓ | — | 0.024s | 71ms | ✓ | 0 次 | 0 次 | 0 | 0 |
| 70 | …le Chrome 2026-02-05 00-50-45.mp4 | 2327ms | 2272ms | 1300ms | 792ms | 55ms | ✓ | — | 0.024s | 69ms | ✓ | 0 次 | 0 次 | 0 | 0 |
| 71 | Study/SSIS-469.mp4 | 5169ms | 5114ms | 3877ms | 953ms | 55ms | ✓ | — | 0.067s | 983ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 72 | …p 2160p HEVC OPUS Multi-Subs].mkv | 7082ms | 7076ms | 6880ms | 0ms | 6ms | ✓ | — | 0.151s | 1138ms | ✗ | 1 次 | 1 次 | 0 | 23 |
| 73 | …x1080][x264_FLAC_3][E06A2B14].mkv | 1269ms | 1265ms | 1045ms | 0ms | 4ms | ✓ | — | 0.108s | 1199ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 74 | … S2 - 08 [BD 1080p x265 FLAC].mkv | 6098ms | 6093ms | 5971ms | 0ms | 5ms | ✓ | — | 0.103s | 1840ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 75 | …NF.WEB-DL.H264.DDP5.1-NexusNF.mkv | 2339ms | 2313ms | 1726ms | 0ms | 26ms | ✓ | — | 0.114s | 3157ms | ✗ | 2 次 | 2 次 | 0 | 25 |
| 76 | Study/IPX-885.mp4 | 4354ms | 4297ms | 3706ms | 5ms | 57ms | ✓ | — | 0.117s | 1751ms | ✗ | 1 次 | 1 次 | 0 | 0 |
| 77 | …80p HEVC-yuv420p10 AAC ASSx2].mkv | 2323ms | 2317ms | 1840ms | 0ms | 6ms | ✓ | — | 0.069s | 2958ms | ✗ | 1 次 | 1 次 | 0 | 58 |
| 78 | …NF.WEB-DL.H264.DDP5.1-NexusNF.mkv | 1191ms | 1178ms | 1012ms | 0ms | 13ms | ✓ | — | 0.156s | 3103ms | ✗ | 1 次 | 1 次 | 0 | 1 |

## 文件/内容异常

| # | 文件 | 原因 | 恢复次数 | 状态 | 启动 |
|---|---|---|---|---|---|
| 45 | …S3 - 07 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv | 无视频帧（内容异常，已记录） | 222 | failed:Cannot Complete Action | 988ms |
| 50 | …022.Amazon.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 无视频帧（内容异常，已记录） | 0 | rendering | 48567ms |
| 55 | …022.Amazon.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv | 无视频帧（内容异常，已记录） | 0 | rendering | 27418ms |
| 64 | …BILIBILI WebRip 2160p HEVC OPUS Multi-Subs].mkv | 显示层恢复1次（内容异常，已记录） | 1 | rendering | 7648ms |

## 长时间运行退化

第二阶段（04:07 之后）出现明显的启动/seek 退化：

- 第一阶段启动 1–16 秒，第二阶段启动 20–85 秒
- 第二阶段 seek 10–53 秒，第一阶段通常 1–5 秒
- 第二阶段仍有 `syncOK=true`、`clockJumpCount=0`，解码恢复主要来自已知内容异常文件
- 测试结束后重启 App，用同一 K-ON 文件复测：准备 1.97 秒、点击→首帧 2.03 秒

因此起播代码本身没有随时长退化；退化更像服务器冷读/长时间运行后的存储或热降速，也可能是进程资源累积。本轮已把每条启动拆分和 seek 指标写入 JSON，后续可用重启对照继续定位。

## 结论

2 小时随机测试完成；没有硬件严重问题；文件/内容异常 4 条、音画同步异常 0 条，已在上方列出。长时间运行后启动/seek 明显变慢，重启 App 可恢复，建议后续单独排查服务器长时间读取或进程资源累积。

原始 JSON：`docs/acceptance-2026-11-10-2h-random.json`