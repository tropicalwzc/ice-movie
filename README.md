# IceMovie

iPad 优先的 iOS SMB 视频播放器：直接连接局域网 SMB 共享，用 FFmpeg 解封装、VideoToolbox 硬解、AVAudioEngine 输出音频，支持 MKV/MP4、内封与外挂字幕、内联/全屏、画中画与续播。点击视频默认直接全屏播放；播放结束后按目录顺序自动播放下一集。同一主机存在多个共享时，可在媒体库左栏直接切换，无需断开重连。

## 环境

- macOS + Xcode 26（部署目标 iOS 26.0）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 本地已放置依赖：
  - `Vendor/AMSMB2`（含 libsmb2 源码）
  - `Vendor/ffmpeg/ffmpeg-src` 与已构建的 `Vendor/ffmpeg/lib/{iphoneos,iphonesimulator}`
  - `Vendor/libass`（实验性，当前未接入构建）

## 生成工程

```bash
xcodegen generate
```

新增 Swift 文件或调整 `project.yml` 后必须重新执行。

## App 图标

图标源文件在 `IceMovie/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`（1024×1024、无 alpha）。
需要重新生成时：

```bash
swift Scripts/make-app-icon.swift IceMovie/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

## FFmpeg

构建脚本：`Vendor/ffmpeg/build.sh`。

- 版本：`Vendor/ffmpeg/ffmpeg-src` 中的源码快照
- 架构：`arm64-apple-ios26.0`（真机）与 `arm64-apple-ios26.0-simulator`（模拟器）
- 关闭编码器、复用器、网络与设备层，只保留播放所需：
  - 解封装：matroska、mov/mp4、avi、mpegts
  - 解码：H.264、HEVC、AAC、Opus、FLAC、AC3/EAC3、DCA、Vorbis，以及 ass/ssa/subrip/webvtt 字幕
- 产物：`Vendor/ffmpeg/lib/iphoneos` 与 `Vendor/ffmpeg/lib/iphonesimulator`

重新构建：

```bash
cd Vendor/ffmpeg && ./build.sh
```

## libass

构建脚本：`Vendor/libass/build.sh`。

- libass 0.17.1 + freetype 2.13.2 + fribidi 1.0.15 + HarfBuzz 6.0.0
- 两套架构：`out/iphoneos` 与 `out/iphonesimulator`
- macOS 需要 `glibtoolize`（Homebrew libtool）；脚本会自动设置 `LIBTOOLIZE`，不需要 meson
- freetype 源码从 GNU Savannah 获取（GitHub Release 不附带源码包）

```bash
cd Vendor/libass && ./build.sh
```

接入方式：`IceMovie/Core/CLibass/module.modulemap` 暴露 `ass.h`；App 侧链接
`libass.a`、`libharfbuzz.a`、`libfreetype.a`、`libfribidi.a`、`libiconv` 与 CoreText。
ASS/SSA 走 libass 位图渲染（保留定位、颜色、描边与 OP 特效），SRT 仍走系统文字；
中文字体优先使用容器附件，其次内置 `Resources/Fonts/NotoSansCJKsc-Regular.otf`，
最后用 CoreText 系统字体兜底。

- 特效脚本超过 4MB 或 5000 事件时自动降级为对白，避免 OP/ED 逐字动画拖垮主线程。
- ≥800MB 的大文件内封文本字幕（ASS/SRT/mov_text）直接复用播放泵读到的字幕包，边播边解析，字幕与音画共用同一读流，不再为字幕二次扫描 SMB；45 秒内没有任何字幕包时才回退到分片加载（4s→16s→60s 递增窗口 + 后台预取）。分片读取使用独立的 `subtitle` 优先级，避免被播放预读拖住；窗口顶到片尾时停止预取，读取失败按 2–8 秒退避。这类文件用系统文字层显示对白。
- SMB 短读不再当作 EOF：每块循环续读直到补满或真正到文件末尾，修复小 MP4 播不出和 4K 视频中途黑屏/截断。
- 旋转、重建视频层或显示层解码恢复时，从当前位置重新解出一段关键帧，而不是把旧帧硬塞进新层；避免新层从非关键帧起解导致的黑屏和恢复刷屏。
- 内封 SRT/mov_text/webvtt 由 FFmpeg 放在 `rect.ass` 里（`ReadOrder,Layer,Style,...,Text`），提取时按字段拆分，界面只显示正文；字幕脚本缓存命中时会重新注册容器字体附件。
- PGS/DVD/DVB 等位图内封字幕暂无文本渲染路径，发现时直接跳过，不参与默认选轨。
- 大文件分片字幕连续失败时会回退到后续字幕候选，并在播放器顶部显示错误提示。
- 音频供给不足时冻结主时钟与音频，缓冲恢复后从同一位置继续，避免声音恢复后落后于画面；音频不足会压过视频领先回压，保证拉流线程继续补音频。

## 构建与签名

模拟器：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovie \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test build \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

必须使用 `CODE_SIGN_IDENTITY='-'`；`CODE_SIGNING_ALLOWED=NO` 会让钥匙串返回 `-34018`。

真机：在 Xcode 中为 `IceMovie` target 选择自己的 Team，或传入 `DEVELOPMENT_TEAM=<TEAM_ID>`。

## 测试

单元测试：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovieTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test test \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

引擎级回归（第 4–7 组，一条命令）：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovieTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test test \
  -only-testing:IceMovieTests/PlaybackRegressionTests \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

UI 测试：

```bash
xcodebuild -project IceMovie.xcodeproj -scheme IceMovieUITests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build-test test \
  CODE_SIGN_IDENTITY='-' OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

### 测试样本

- 本地库通过启动参数注入，不写死主机：`-libraryLocal /private/tmp/animi`
- 回归样本至少需要：
  - `[www.domp4.com]大逃杀.2000.DC.BD1080p.中文字幕.mp4`（H.264 + AC3）
  - `强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv`（HEVC 10-bit + AAC，内封 ASS）
  - `强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - Sub/Kaze ga Tsuyoku Fuiteiru 01.{chs,cht,jpn}.ass`（三语外挂）
  - `re0 s3/… - 01 [IEM 2160p WEB-DL AAC Multi-Subs].mkv`（4K HEVC）
- 缺样本时回归用例会 `XCTSkip` 对应条目。
- 损坏样本：`错误样本/损坏的视频.mp4`（随机字节，用于播放失败提示）。

## 启动参数（调试/自动化）

- `-libraryLocal <路径>`、`-libraryPath <相对路径>`：本地库
- `-libraryOpenFirst`、`-libraryOpenName <关键字>`：加载目录后自动按产品播放路径打开首个匹配视频
- `-librarySeekTo <秒>`：起播 3 秒后执行一次跳转
- `-librarySeekBackTo <秒>`：首次跳转 3 秒后再回跳，用于验收
- `-libraryCloseAfter <秒>`：播放若干秒后关闭，验证续播
- `-libraryRewindAt <秒> -libraryRewindTo <秒>`：每集播到指定秒后自动回退，用于长片压力验收
- `-acceptanceReport`：每集结束/切换时把缓冲、字幕、偏差指标追加到 `Documents/ice-acceptance.json`
- `-resetAcceptanceReport`：启动时清空逐集验收报告
- `-keepControlsVisible`：验收时让控件常显（仅测试）
- `-stressRandom`：随机抽样压力测试开关；配合 `-stressRootPath <相对路径>`（默认共享根）
- `-stressCount <条数>`、`-stressPlaySeconds <秒>`、`-stressSeekAfter <秒>`、`-stressSeekFraction <0–1>`
- `-stressTimeLimit <秒>`：压力测试时间上限（默认 1800）；发现无视频帧、显示层解码恢复、单分钟缓冲 ≥6 次、播放失败或显示层 failed 时自动停止
- `-stressFilter <子串>`：只测路径包含该子串的视频，用于单文件复现
- `-stressHDFirst`：验收时把最大的 4K 排在小 MP4 之后，优先覆盖高码率片
- `-stressTolerateBufferStalls`：把缓冲超标记录为环境异常（`stressBufferException`）并继续，只有无视频帧/解码恢复/播放失败才中断
- `-stressSeekBackSeconds <秒>` / `-stressSeekBackFraction <0–1>`：播放中段再回退指定秒数或比例，用于验证回退命中缓存
- `-stressSeekForwardSeconds <秒>`：播放后段再前进指定秒数，用于验证邻近前跳命中
- `-smbChunkMB <MB>` / `-smbRingMB <MB>`：SMB 播放读块与预读窗口（默认 1MB / 512MB）
- `-smbSeekCache 0`：关闭新的 seek 缓存复用，回退到旧的“seek 清空预读环”行为
- `-playbackRate <倍速>`：加速长片回归（0.5–2.0）
- `-throughputReport <秒>`：播放指定秒数后把吞吐/跳转统计写入 `Documents/ice-throughput.json`
- `-shardedThresholdMB <MB>`：自检时降低分片字幕阈值（默认 800MB）
- `-smbHost <地址> -smbShare <共享> -library`：SMB 库
- `-resetPlaybackProgress`：清空续播记录
- `-resetSubtitlePreferences`：清空字幕偏好
- `-debugLog` / `-logDebug`：打开调试日志
- `-diagnostics`：直接打开诊断页

## 缓存策略

App 不缓存视频。播放时使用 **512 MB 内存预读环 + 15 秒音视频缓冲**（只占内存、不落盘，关闭播放即释放）；落盘缓存只有两类，合计上限 **200 MB**：

| 缓存 | 上限 | 淘汰 | 说明 |
| --- | --- | --- | --- |
| 缩略图 `Caches/Thumbnails` | 150 MB | LRU，按文件修改时间 | 每个封面约几十 KB，命中后刷新访问时间 |
| 内封字幕 `Caches/SubtitleScripts` | 50 MB | LRU，按文件修改时间 | 只存降级后的 ASS 文本（通常 60 KB–1 MB），不缓存字体与视频 |

- 内存中的封面另有 64 MB `NSCache`，退出即释放。
- 播放预读：SMB 播放块默认 1 MB、内存环约 512 MB（512 块，可用 `-smbChunkMB` / `-smbRingMB` 调整）；音频/视频各补到 15 秒，起播先垫 3 秒音频 + 2 秒视频。局域网带宽足够时提前读、提前解码，网络抖动不再立刻触发“缓冲中”；该缓冲只占内存，不写硬盘。
- 预读是持续的后台任务：环形窗口填满后不会停死，播放消耗后从新的读位置继续补下一段。
- 视频包封装/投递在独立有界队列和线程完成，播放泵只做读包与音频/字幕处理；音频低于 1 秒时暂停后台预读，把 SMB 带宽让给播放读，避免高码率 4K 反复缓冲。
- 关闭视频或切换文件时会立即取消旧文件的预读任务并递增 generation，旧任务最多完成手头一个 1MB 读就退出，不会在后台继续下载抢下一部的带宽。
- 视频队列默认上限 96 包 / 96MB，满时优先丢最老非关键帧；seek 时清空队列并用 generation 隔离旧包。
- seek 先查连续缓存：回退或邻近跳转命中时不重置预读环、不重新下载；未命中时只丢弃前向窗口，先读目标位置第一块，再从解封装读头向前预读。
- 读窗口显式区分播放头、解封装读头和预读最远点：缓冲区间从播放头算到预读最远点，包含已解封装但尚未播放的数据；进度条不会只显示读头之后的一小段。
- 回看窗口默认约 20 秒、最多 64 MB，其余内存留给未来窗口；淘汰先丢回看窗口外的远端块，再丢前向窗口外和窗口内离播放头最远的数据。
- 播放器 HUD：iPad 右上角在控件可见时显示实时下载速度和电量；返回/关闭按钮与状态栏随控件一起淡入淡出；标题在 iPad 允许两行。进度条用浅绿色显示当前播放点到预读窗口末端的已缓冲区间。
- 缩略图与字幕脚本的缓存键都带数据源命名空间（SMB 为主机 + 共享，本地源为根目录绝对路径），切换共享或根目录不会串用。
- 字幕脚本缓存键还带格式版本；解析或降级逻辑升级后，旧缓存会自动失效。
- 最坏会先写入一个新文件再触发淘汰，瞬时可能略微超过上限，但下一次读取前就会回到预算内。
- 媒体库「更多 > 清空缓存」可立即删除缩略图与字幕脚本。

## 真机实测（iPad Air 11 英寸 M2，iOS 27.0.1，SMB `192.168.5.2` / `TROPICAL-ADVPC.local`）

通过 `-libraryOpenFirst -throughputReport <秒>` 让真机按产品路径播放并写回
`Documents/ice-throughput.json`，用 `devicectl device copy from` 取回：

| 样本 | 编码 | 平均码率 | 实测读取 | 时长 | 欠载 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 强风吹拂 01（1080p） | HEVC + AAC | 2.00 Mbps | 0.21 MB/s | 60s | 0 | 无失败 |
| Re:Zero 01（2160p） | HEVC + AAC | 3.12 Mbps | 0.91 MB/s | 60s | 0 | 无失败 |

4K 样本跳转到 300 秒：首包 311ms、预滚 40 帧、落点偏差 0.38s、无欠载。

### 长跑验收（iPad 模拟器，冷启动）

清空 `Thumbnails` 与 `SubtitleScripts` 后，用四月第 4、5 集（1.13GB / 1.44GB，内封 ASS 分片）走完整流程：

1. 第 4 集从 0 秒完整播放 1372.2 秒：0 欠载，最大音频偏差 0.032s、显示偏差 0.002s，625 条分片字幕；播完自动进入第 5 集。
2. 第 5 集播放到 13:07 自动关闭并保存续播位置 787.4s；重开后从 787.4s 续播。
3. 回退到 600s（10:00）：seek 出画 19ms，字幕窗口 590–660s 约 0.1 秒就绪。
4. 从 600s 继续播到 1372.1s：0 欠载，最大音频偏差 0.03s、显示偏差 0.001s，累计 341 条字幕；播完自动进入第 6 集。

内存预读环 512 MB：按 3.12 Mbps 可缓存约 23 分钟内容，按 Solo Leveling 的
5.8 Mbps 约 12 分钟，按高码率 4K（80 Mbps）约 51 秒；起播先垫 3 秒音频 + 2 秒视频，
播放中音视频各补到 15 秒。该缓冲只占内存，不写入硬盘缓存。

### iPhone 横屏播放（iPhone 16 真机验证）

- 媒体库固定竖屏；点击视频进入全屏时自动切到横屏，即使系统开启“竖排方向锁定”。
- 全屏播放器在紧凑布局改用根视图覆盖层（不再使用 `fullScreenCover`），避免系统弹层的视图控制器只支持竖屏导致 `requestGeometryUpdate` 失败，也避免键盘退场动画期间覆盖层被丢弃。
- 播放 350MB H.264 MP4：横屏画面、进度条、±10 秒、画中画与字幕按钮正常；退出播放回到竖屏媒体库。
- 搜索定位后再点视频（键盘仍在退场）也能正常进入播放器，`testOpenFromSearchPresentsPlayer` 覆盖该路径。

### 随机起播 / 中间跳转压力验收

使用 `-stressRandom -stressRootPath "" -stressCount 16 -stressPlaySeconds 60 -stressSeekAfter 4 -stressSeekFraction 0.5 -stressTimeLimit 1800`：

- 不递归扫共享：样本来自 SwiftData 播放历史 + 当前目录 + 根目录里关键词命中的已知目录（Solo / American / 无职 / K-ON!）和名字带 2160p/4K/UHD/HDR 的电影目录，目录列举总预算 20 秒。
- 过滤小于 100MB 的广告占位文件与花絮；每个目录最多取 3 条，保证多样性。
- 第一条优先小 MP4（<1.5GB）让画面尽快出现，随后保证 1080p MKV、至少 3 条 4K MKV、超过 5GB 的长片都有覆盖。
- 每条起播 4 秒后跳到 50%，播放约 1 分钟。
- 逐条写 `Documents/ice-acceptance.json`：首帧耗时、视频入队/恢复次数、显示层状态、视频队列深度/丢包、缓冲次数/分钟、累计缓冲、seek 时延/偏差、`seekCacheHit`、`seekCacheHits`/`seekCacheMisses`、`ringResetCount`、字幕条数与错误。
- 无视频帧、显示层解码恢复、播放失败或显示层 failed 会自动停止；单分钟缓冲 ≥6 次默认也停止，加 `-stressTolerateBufferStalls` 时改为记录 `stressBufferException` 并继续，适合区分代码问题与服务器/过热掉速。最多 30 分钟。
- 总结条目包含 `stressCompleted`、`stressSeriousFound`、`stressBufferExceptions`、`stressStopReason`。

## 真机人工验证清单

以下项目无法靠模拟器闭环，必须在 iPad（主要场景）与 iPhone 上人工确认：

1. 首次访问局域网时出现系统授权框；拒绝后给出可恢复提示（1.3）
2. 分别用 IP（如 `192.168.5.2`）与 `.local` 名称连接同一主机
3. 锁屏后音频继续，锁屏/控制中心显示标题、进度，播放/暂停/±10 秒可用（8.2）
4. 画中画窗口内容正常、可暂停与关闭（模拟器窗口内容可能黑屏）
5. 1080p 与 4K 样本的实际可持续码率、预读窗口是否足够（8.5）
6. 解封装失败、编码不支持、主机不可达三种提示互不相同且都能返回媒体库（8.3）
7. iPad 分栏浏览、内联播放、全屏互转、外接键盘、分栏与滑动覆盖切换（8.7）
8. 六条验收标准在 iPhone 与 11 英寸 iPad Air 上逐条记录（8.6/8.7）

## 已知限制

- 模拟器画中画窗口内容可能黑屏，但音频与播放进度继续；以真机为准。
- 损坏文件在个别 demuxer 上探测较慢；已修正 FFmpeg 自定义 IO 的 EOF 与失败清理，并保证播放准备不阻塞媒体库。
- libass 的复杂特效（模糊、逐字动画等）仍受字体与脚本支持范围限制；常规对白、定位 OP、颜色与描边已保真。
- ≥800MB 的内封字幕按播放位置分片读取并使用系统文字层，以保证秒开；OP/ED 逐字特效会降级为对白。
