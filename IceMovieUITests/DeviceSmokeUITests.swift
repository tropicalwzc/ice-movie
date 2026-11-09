import XCTest

/// 真机专用冒烟：验证局域网授权、SMB 自动恢复、目录浏览与 MKV 播放。
/// 模拟器没有真实 SMB 环境，直接跳过。
final class DeviceSmokeUITests: XCTestCase {
    @MainActor
    func testSMBPermissionLibraryAndPlayback() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真机专用")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-debugLog"]
        app.launch()

        // 首次访问局域网会出现系统授权框；已授权时不存在。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["允许"]
        if allow.waitForExistence(timeout: 8) {
            allow.tap()
        }

        // 若授权发生在自动恢复失败之后，点最近连接重试。
        var folder = app.buttons["强风吹拂"].firstMatch
        if !folder.waitForExistence(timeout: 8) {
            let recent = app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", "192.168.5.2"))
                .firstMatch
            if recent.waitForExistence(timeout: 3) {
                recent.tap()
            }
        }

        folder = app.buttons["强风吹拂"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 60), "应自动恢复并进入强风吹拂")
        folder.tap()

        let episode = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Kaze ga Tsuyoku Fuiteiru - 01"))
            .firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 30), "应列出第 1 集")
        episode.tap()

        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 45), "应开始播放")
        let time = app.staticTexts["player.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 10))
        sleep(15)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "subtitle.libass")
                .firstMatch
                .exists,
            "ASS 字幕应由 libass 渲染"
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad-real-device-playback"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #endif
    }
}
