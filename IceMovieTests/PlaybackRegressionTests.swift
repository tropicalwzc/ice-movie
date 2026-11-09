import DemuxKit
import IceCore
import RenderKit
import SubtitleKit
import XCTest

/// 第 4 至 7 组的引擎级回归入口。
///
/// 覆盖解封装、硬解样本矩阵、起播、跳转与字幕轨发现；一条命令即可跑完：
/// `xcodebuild -scheme IceMovieTests test -only-testing:IceMovieTests/PlaybackRegressionTests`
///
/// 依赖本地样本库 `/private/tmp/animi`。样本缺失时跳过对应条目，
/// 不把开发机路径变成 CI 的硬依赖。
final class PlaybackRegressionTests: XCTestCase {
    private struct Sample {
        let name: String
        let path: String
        let videoCodec: String
        let audioCodec: String
    }

    private let samples: [Sample] = [
        Sample(
            name: "MP4 H.264 + AC3",
            path: "/private/tmp/animi/[www.domp4.com]大逃杀.2000.DC.BD1080p.中文字幕.mp4",
            videoCodec: "h264",
            audioCodec: "ac3"
        ),
        Sample(
            name: "MKV HEVC 10-bit + AAC（1080p）",
            path: "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv",
            videoCodec: "hevc",
            audioCodec: "aac"
        ),
        Sample(
            name: "MKV HEVC 10-bit + AAC（2160p）",
            path: "/private/tmp/animi/re0 s3/[New Fyy Raws] Re-Zero kara Hajimeru Isekai Seikatsu 3rd Season - 01 [IEM 2160p WEB-DL AAC Multi-Subs].mkv",
            videoCodec: "hevc",
            audioCodec: "aac"
        ),
    ]

    func testSampleMatrixPlaysAndSeeks() throws {
        var ran = 0
        for sample in samples {
            guard FileManager.default.fileExists(atPath: sample.path) else {
                continue
            }
            ran += 1
            try run(sample)
        }
        if ran == 0 {
            throw XCTSkip("本地样本库缺失，跳过引擎级回归")
        }
        XCTAssertGreaterThan(ran, 0)
    }

    private func run(_ sample: Sample) throws {
        let reader = try MediaReader.open(path: sample.path)
        XCTAssertNotNil(reader.videoTrack, "\(sample.name)：应检测到视频轨")
        XCTAssertGreaterThan(reader.duration, 60, "\(sample.name)：时长异常")

        let videoCodec = reader.videoTrack?.codec ?? ""
        let audioCodec = reader.audioTrack?.codec ?? ""
        XCTAssertEqual(videoCodec, sample.videoCodec, "\(sample.name)：视频编码不符")
        XCTAssertEqual(audioCodec, sample.audioCodec, "\(sample.name)：音频编码不符")

        let engine = try PlaybackEngine(reader: reader)
        engine.play()

        let started = Date()
        while Date().timeIntervalSince(started) < 6, engine.clock.currentTime < 2 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let stats = engine.statistics
        XCTAssertGreaterThan(engine.clock.currentTime, 1, "\(sample.name)：起播后主时钟未推进")
        XCTAssertGreaterThan(stats.packetsDecoded, 0, "\(sample.name)：没有解码任何包")
        XCTAssertNil(stats.failure, "\(sample.name)：播放失败 \(stats.failure ?? "")")
        Log.info(
            .render,
            "回归播放 \(sample.name) 位置=\(String(format: "%.2f", engine.clock.currentTime))s "
                + "视频包=\(stats.videoPackets) 首帧=\(stats.firstVideoMilliseconds)ms "
                + "起播=\(stats.startupMilliseconds)ms"
        )

        let target = min(max(30, engine.duration * 0.4), max(0, engine.duration - 5))
        engine.seek(to: target)
        let seekStarted = Date()
        while Date().timeIntervalSince(seekStarted) < 10,
              abs(engine.clock.currentTime - target) > 3 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(
            engine.clock.currentTime,
            target,
            accuracy: 3,
            "\(sample.name)：跳转未落到目标附近"
        )
        XCTAssertNil(engine.statistics.failure, "\(sample.name)：跳转后播放失败")
        engine.stop()
    }

    func testSubtitlePipelineForExternalASS() throws {
        let path = "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - Sub/Kaze ga Tsuyoku Fuiteiru 01.chs.ass"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("外挂字幕样本缺失，跳过")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        let cues = SubtitleParser.parse(text, format: .ass)
        XCTAssertGreaterThan(cues.count, 100, "外挂 ASS 应解析出足量字幕")
        let timeline = SubtitleTimeline(cues: cues)
        XCTAssertFalse(timeline.active(at: 75).isEmpty, "75 秒处应有字幕")
        XCTAssertFalse(cues.contains { $0.text.hasPrefix("m 0 0") }, "矢量绘图不应进入字幕文本")
    }
}
