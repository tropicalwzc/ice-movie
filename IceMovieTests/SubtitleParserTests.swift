import XCTest
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

    func testOverlappingCuesBothReturned() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(start: 0, end: 4, text: "对白"),
            SubtitleCue(start: 1, end: 3, text: "顶部注释"),
        ])
        XCTAssertEqual(timeline.active(at: 2).count, 2)
    }
}
