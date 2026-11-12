import XCTest

/// 使用模拟器真实照片库验证 PhotoKit 枚举与导出。
/// 运行前需要通过 `simctl addmedia` 注入照片并授予照片权限；
/// 没有可访问照片时跳过，不影响常规模拟器测试。
@MainActor
final class PhotoSyncRealLibraryUITests: XCTestCase {
    private func element(
        _ app: XCUIApplication,
        _ identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    func testRealPhotoKitPreviewAndExport() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/icemovie-photosync-real",
            "-photoSyncResetTarget",
            "-debugLog",
        ]
        app.launch()

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let mark = element(app, "photoSync.menu.mark")
        if mark.waitForExistence(timeout: 3) {
            mark.tap()
        } else {
            let fallback = app.buttons["设为照片库路径"]
            guard fallback.waitForExistence(timeout: 3) else {
                throw XCTSkip("当前目录已经是照片库目标或无标记入口")
            }
            fallback.tap()
        }

        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 8))
        syncButton.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["允许完全访问"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
        }

        let start = element(app, "photoSync.review.start")
        XCTAssertTrue(start.waitForExistence(timeout: 30), "应完成真实照片库扫描")
        let pending = element(app, "photoSync.review.pending.value")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        let pendingCount = Int(pending.label) ?? 0
        guard pendingCount > 0 else {
            start.tap()
            throw XCTSkip("模拟器照片库没有可访问照片")
        }

        start.tap()

        let image = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "media."))
            .firstMatch
        XCTAssertTrue(
            image.waitForExistence(timeout: 45),
            "真实 PhotoKit 导出后网格应出现照片"
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "photo-sync-real-photokit"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
