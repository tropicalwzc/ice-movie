import DemuxKit
import IceCore
import SubtitleKit
import XCTest

/// 内封 ASS 的字段与时长回归：Matroska 事件没有 `Dialogue:` 前缀，
/// 必须把 ReadOrder/Layer/Style/... 拆成字段，并使用容器包时长。
final class EmbeddedSubtitleExtractionTests: XCTestCase {
    private let samples: [(String, String, Int)] = [
        (
            "白箱",
            "/private/tmp/animi/白箱/[SAIO-Raws] Shirobako 01 [BD 1920x1080 HEVC-10bit OPUSx2 ASSx2].mkv",
            4
        ),
        (
            "强风吹拂",
            "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv",
            3
        ),
    ]

    func testShardedReadStopsAtWindow() throws {
        let path = "/private/tmp/recentw/四月/[Haruhana] Shigatsu wa Kimi no Uso [02][HEVC-10bit FLAC][CHS_CHT_JPN].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("四月第二集未挂载")
        }
        let reader = try MediaReader.open(path: path)
        guard let stream = reader.info.streams.first(where: { $0.kind == .subtitle }) else {
            reader.close()
            return XCTFail("应有内封字幕轨")
        }
        let began = CFAbsoluteTimeGetCurrent()
        let events = try reader.readSubtitleEvents(
            streamIndex: stream.index,
            from: 290,
            to: 360
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - began
        reader.close()
        XCTAssertFalse(events.isEmpty)
        XCTAssertLessThan(elapsed, 5, "分片读取不应扫描完整 1GB 文件")
        XCTAssertTrue(events.allSatisfy { $0.start <= 361.0 })
        Log.info(.subtitle, "分片读取 290-360s 事件=\(events.count) 耗时=\(String(format: "%.2f", elapsed))s")
    }

    func testEmbeddedSRTTextHasNoASSFieldPrefix() throws {
        let path = "/private/tmp/animi/[LoliHouse] Kono Kaisha ni Suki na Hito ga Imasu [01-12][WebRip 1080p HEVC-10bit AAC]/[LoliHouse] Kono Kaisha ni Suki na Hito ga Imasu - 01 [WebRip 1080p HEVC-10bit AAC SRTx2].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("内封 SRT 样本未挂载")
        }
        let reader = try MediaReader.open(path: path)
        defer { reader.close() }
        guard let stream = reader.info.streams.first(where: { $0.kind == .subtitle }) else {
            return XCTFail("应有内封字幕轨")
        }

        // 文本型解码器会通过 rect.ass 返回 "ReadOrder,Layer,Style,...,Text"，
        // 提取时必须拆字段，不能把 "0,0,Default,,0,0,0,," 当作对白正文。
        let document = try reader.readSubtitleScript(streamIndex: stream.index)
        XCTAssertFalse(
            document.contains("Default,,0,0,0,,0,0,"),
            "整段提取不应把 ASS 事件字段写进正文"
        )

        let events = try reader.readSubtitleEvents(streamIndex: stream.index, from: 0, to: 120)
        XCTAssertFalse(events.isEmpty, "前两分钟应有对白")
        for event in events {
            XCTAssertFalse(event.text.hasPrefix("0,0,"), "事件正文不应带 ASS 字段前缀：\(event.text)")
            guard let plain = ASSScriptSanitizer.plainText(event.text) else {
                return XCTFail("清理后不应为空：\(event.text)")
            }
            XCTAssertFalse(plain.isEmpty)
            XCTAssertFalse(plain.hasPrefix("0,0,"))
        }
        Log.info(.subtitle, "内封 SRT 解析 事件=\(events.count) 首条=\(events[0].text.prefix(40))")
    }

    func testEmbeddedASSFieldsAndDuration() throws {
        var ran = 0
        for (name, path, stream) in samples where FileManager.default.fileExists(atPath: path) {
            ran += 1
            let reader = try MediaReader.open(path: path)
            let script = try reader.readSubtitleScript(streamIndex: stream)
            reader.close()

            XCTAssertTrue(script.contains("[V4+ Styles]"), "\(name)：应保留容器样式头")
            XCTAssertTrue(script.contains("Style: "), "\(name)：应包含样式定义")
            let cues = SubtitleParser.parse(script, format: .ass)
            XCTAssertGreaterThan(cues.count, 100, "\(name)：字幕事件过少")

            let first = try XCTUnwrap(cues.first, "\(name)：应有第一条字幕")
            XCTAssertFalse(first.text.hasPrefix("0,"), "\(name)：不应把事件字段泄漏进文本")
            XCTAssertFalse(first.text.contains(",Default,"), "\(name)：不应包含样式字段")
            XCTAssertGreaterThan(
                first.end - first.start,
                1.0,
                "\(name)：首条字幕时长应按容器时长，而不是固定 0.5s"
            )
            Log.info(.subtitle, "内封 ASS 回归 \(name) 条目=\(cues.count) 首条=\(first.start)-\(first.end)s")
        }
        if ran == 0 {
            throw XCTSkip("内封 ASS 样本缺失")
        }
    }
}
