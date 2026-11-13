import XCTest

@MainActor
final class TempDetailsBadgeUITest: XCTestCase {
    func testIPadSplitInlineDetailsBadgeStaysVisible() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "只在 iPad 分栏下截图"
        )

        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-libraryPath", "白箱",
            "-playerStatusDetails",
            "-resetPlaybackProgress",
            "-debugLog",
        ]
        app.launch()

        let firstVideo = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS %@", "Shirobako 01")
        ).firstMatch
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 30), "白箱目录应出现视频")
        firstVideo.tap()

        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 20), "应开始播放")
        // 等控件自动隐藏，验证诊断状态条仍然常驻。
        sleep(6)

        let status = app.descendants(matching: .any)
            .matching(identifier: "player.status")
            .firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "内嵌播放也应显示诊断状态")
        XCTAssertTrue(status.label.contains("内存"), "诊断状态应包含内存，实际=\(status.label)")
        XCTAssertTrue(status.label.contains("CPU"), "诊断状态应包含 CPU，实际=\(status.label)")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "ipad-inline-details-badge"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
