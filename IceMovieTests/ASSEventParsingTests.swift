import XCTest
@testable import DemuxKit

/// ASS 事件解析必须同时兼容 Matroska 字幕包与完整 Dialogue 行。
final class ASSEventParsingTests: XCTestCase {
    func testMatroskaPacketFields() {
        let event = MediaReader.parseASSEvent("0,0,CN,,0,0,0,,你好,世界")
        XCTAssertEqual(event?.layer, "0")
        XCTAssertEqual(event?.style, "CN")
        XCTAssertEqual(event?.name, "")
        XCTAssertEqual(event?.effect, "")
        XCTAssertEqual(event?.text, "你好,世界")
    }

    func testFullDialogueLineFields() {
        let event = MediaReader.parseASSEvent(
            "Dialogue: 0,0:00:01.00,0:00:02.00,CN,,0,0,0,,你好,世界"
        )
        XCTAssertEqual(event?.layer, "0")
        XCTAssertEqual(event?.style, "CN")
        XCTAssertEqual(event?.name, "")
        XCTAssertEqual(event?.marginLeft, "0")
        XCTAssertEqual(event?.effect, "")
        XCTAssertEqual(event?.text, "你好,世界")
    }

    func testMalformedEventReturnsNil() {
        XCTAssertNil(MediaReader.parseASSEvent("not,an,ass,event"))
        XCTAssertNil(MediaReader.parseASSEvent("Dialogue: 0,0:00:01.00,text-only"))
    }
}
