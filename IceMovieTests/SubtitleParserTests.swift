import XCTest
@testable import IceMovie
@testable import SubtitleKit

final class SubtitleParserTests: XCTestCase {
    func testSRTParsing() {
        let text = """
        1
        00:00:01,000 --> 00:00:03,500
        第一行
        第二行

        2
        00:01:00,000 --> 00:01:02,000
        <i>斜体</i>
        """
        let cues = SubtitleParser.parse(text, format: .srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "第一行\n第二行")
        XCTAssertEqual(cues[1].start, 60, accuracy: 0.001)
    }

    func testASSParsingWithTagsAndCommas() {
        let text = """
        [Script Info]
        Title: t

        [V4+ Styles]
        Format: Name, Fontname

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:02.00,0:00:04.50,Default,,0,0,0,,{\\pos(960,900)}你好，世界
        Dialogue: 0,0:01:00.00,0:01:02.00,Default,,0,0,0,,第一行\\N第二行
        Comment: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,注释不显示
        """
        let cues = SubtitleParser.parse(text, format: .ass)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 2.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 4.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "你好，世界")
        XCTAssertEqual(cues[1].text, "第一行\n第二行")
    }

    func testTimelineFindsActiveCues() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(start: 0, end: 2, text: "a"),
            SubtitleCue(start: 2, end: 4, text: "b"),
            SubtitleCue(start: 10, end: 12, text: "c"),
        ])
        XCTAssertEqual(timeline.active(at: 1).map(\.text), ["a"])
        XCTAssertEqual(timeline.active(at: 3).map(\.text), ["b"])
        XCTAssertEqual(timeline.active(at: 5).map(\.text), [])
        XCTAssertEqual(timeline.active(at: 11).map(\.text), ["c"])
    }

    func testUTF16LEASSWithBOMDecodesAndParses() {
        let text = """
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,UTF-16 字幕
        Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,第二行
        """
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)

        let decoded = SubtitleTextDecoder.decode(data)
        let cues = SubtitleParser.parse(decoded, format: .ass)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "UTF-16 字幕")
        XCTAssertEqual(cues[1].start, 4, accuracy: 0.001)
    }

    func testGB18030ASSDecodesWithSimplifiedChineseHint() {
        assertLegacyASS(
            text: """
            [Script Info]
            Title: 简体字幕

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,简体中文对白
            """,
            encoding: .GB_18030_2000,
            language: .simplifiedChinese
        )
    }

    func testBig5ASSDecodesWithTraditionalChineseHint() {
        assertLegacyASS(
            text: """
            [Script Info]
            Title: 繁體字幕

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,繁體中文對白
            """,
            encoding: .big5,
            language: .traditionalChinese
        )
    }

    func testOverlappingCuesBothReturned() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(start: 0, end: 4, text: "对白"),
            SubtitleCue(start: 1, end: 3, text: "顶部注释"),
        ])
        XCTAssertEqual(timeline.active(at: 2).count, 2)
    }

    func testSeekRefreshPolicyRejectsStaleOpeningTimeline() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(start: 0, end: 2, text: "开场")
        ])
        XCTAssertTrue(
            SubtitleSeekRefreshPolicy.shouldRefresh(timeline: timeline, at: 900)
        )
        XCTAssertTrue(
            SubtitleSeekRefreshPolicy.shouldRefresh(timeline: nil, at: 900),
            "nil 时间线应当刷新"
        )
    }

    func testSeekRefreshPolicyKeepsNearbySubtitleTimeline() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(start: 895, end: 905, text: "目标附近对白")
        ])
        XCTAssertFalse(
            SubtitleSeekRefreshPolicy.shouldRefresh(timeline: timeline, at: 900)
        )
        XCTAssertTrue(
            SubtitleSeekRefreshPolicy.shouldRefresh(timeline: timeline, at: 906),
            "目标时刻没有可见 cue 时应刷新，不能用已经结束的字幕覆盖空档"
        )
    }

    private func assertLegacyASS(
        text: String,
        encoding: CFStringEncodings,
        language: SubtitleLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let raw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(encoding.rawValue)
        )
        guard let data = text.data(using: String.Encoding(rawValue: raw)) else {
            return XCTFail("无法生成测试字幕编码 \(encoding)", file: file, line: line)
        }
        let decoded = SubtitleTextDecoder.decode(
            data,
            language: language,
            format: .ass
        )
        let cues = SubtitleParser.parse(decoded, format: .ass)
        XCTAssertEqual(cues.count, 1, file: file, line: line)
        XCTAssertTrue(
            cues[0].text.contains(language == .traditionalChinese ? "繁體" : "简体"),
            "解码文本不正确：\(cues[0].text)",
            file: file,
            line: line
        )
    }
}
