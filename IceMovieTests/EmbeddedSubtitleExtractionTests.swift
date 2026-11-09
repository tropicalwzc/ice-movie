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
