import XCTest

@MainActor
final class PlayerStatusBadgeUITests: XCTestCase {
    /// iPhone 紧凑播放页只显示网速与电量；内存/CPU 留给 iPad。
    func testIPhoneStatusBadgeShowsBatteryAndNetwork() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "只在 iPhone 上校验紧凑状态条"
        )

        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-libraryPath", "白箱",
            "-resetPlaybackProgress",
            "-debugLog",
        ]
        app.launch()

        let firstVideo = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS %@", "Shirobako 01")
        ).firstMatch
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 25), "白箱目录应出现视频")
        firstVideo.tap()

        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15), "应开始播放")
        let status = app.descendants(matching: .any)
            .matching(identifier: "player.status")
            .firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "右上角应显示状态")
        XCTAssertTrue(status.label.contains("电量"), "状态应包含电量，实际=\(status.label)")
        XCTAssertFalse(status.label.contains("内存"), "iPhone 状态不应包含内存，实际=\(status.label)")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iphone-status-badge"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
