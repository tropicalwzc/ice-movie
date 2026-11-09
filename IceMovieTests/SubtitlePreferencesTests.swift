import SubtitleKit
import XCTest

final class SubtitlePreferencesTests: XCTestCase {
    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.wangzicheng.icemovie.tests.subtitle.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        SubtitlePreferences.defaults = suite
        SubtitlePreferences.reset()
    }

    override func tearDown() {
        SubtitlePreferences.reset()
        SubtitlePreferences.defaults = .standard
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertTrue(SubtitlePreferences.enabled)
        XCTAssertNil(SubtitlePreferences.lastLanguage)
        XCTAssertEqual(SubtitlePreferences.fontSize, 22)
        XCTAssertEqual(SubtitlePreferences.bottomPadding, 130)
        XCTAssertEqual(SubtitlePreferences.offset, 0)
    }

    func testLanguageAndEnabledPersist() {
        SubtitlePreferences.lastLanguage = .traditionalChinese
        SubtitlePreferences.enabled = false

        XCTAssertEqual(SubtitlePreferences.lastLanguage, .traditionalChinese)
        XCTAssertFalse(SubtitlePreferences.enabled)

        SubtitlePreferences.enabled = true
        XCTAssertTrue(SubtitlePreferences.enabled)
    }

    func testStyleValuesClamp() {
        SubtitlePreferences.fontSize = 100
        XCTAssertEqual(SubtitlePreferences.fontSize, 36)
        SubtitlePreferences.fontSize = 1
        XCTAssertEqual(SubtitlePreferences.fontSize, 14)

        SubtitlePreferences.bottomPadding = 1000
        XCTAssertEqual(SubtitlePreferences.bottomPadding, 260)
        SubtitlePreferences.bottomPadding = -10
        XCTAssertEqual(SubtitlePreferences.bottomPadding, 60)

        SubtitlePreferences.offset = 100
        XCTAssertEqual(SubtitlePreferences.offset, 10)
        SubtitlePreferences.offset = -100
        XCTAssertEqual(SubtitlePreferences.offset, -10)
    }

    func testSubtitleOffsetShiftsActiveWindow() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(start: 10, end: 12, text: "测试"),
        ])
        // offset = +0.5 表示字幕延后 0.5s：主时钟 10.4s 时查询 9.9s，尚未显示。
        XCTAssertTrue(timeline.active(at: 10.4 - 0.5).isEmpty)
        XCTAssertEqual(timeline.active(at: 10.5 - 0.5).count, 1)
        XCTAssertEqual(timeline.active(at: 12.4 - 0.5).count, 1)
        XCTAssertTrue(timeline.active(at: 12.5 - 0.5).isEmpty)
    }
}
