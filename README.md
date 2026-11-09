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
- `-throughputReport <秒>`：播放指定秒数后把吞吐/跳转统计写入 `Documents/ice-throughput.json`
- `-smbHost <地址> -smbShare <共享> -library`：SMB 库
- `-resetPlaybackProgress`：清空续播记录
- `-resetSubtitlePreferences`：清空字幕偏好
- `-debugLog` / `-logDebug`：打开调试日志
- `-diagnostics`：直接打开诊断页

## 真机实测（iPad Air 11 英寸 M2，iOS 27.0.1，SMB `192.168.5.2` / `TROPICAL-ADVPC.local`）

通过 `-libraryOpenFirst -throughputReport <秒>` 让真机按产品路径播放并写回
`Documents/ice-throughput.json`，用 `devicectl device copy from` 取回：

| 样本 | 编码 | 平均码率 | 实测读取 | 时长 | 欠载 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 强风吹拂 01（1080p） | HEVC + AAC | 2.00 Mbps | 0.21 MB/s | 60s | 0 | 无失败 |
| Re:Zero 01（2160p） | HEVC + AAC | 3.12 Mbps | 0.91 MB/s | 60s | 0 | 无失败 |

4K 样本跳转到 300 秒：首包 311ms、预滚 40 帧、落点偏差 0.38s、无欠载。

预读窗口维持 24 MB：按 3.12 Mbps 可缓存约 61 秒内容，按高码率 4K（80 Mbps）
仍有约 19 秒余量，足以覆盖实测网络抖动。

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
