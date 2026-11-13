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

    /// OOM 验收：冷目录预热跑起来后切后台，让 BGProcessingTask 接管，
    /// 观察后台预热的内存采样。必须单独运行，避免宿主被 Home 键挂起。
    @MainActor
    func testBackgroundPrewarmMemoryProbe() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真机专用")
        #else
        let app = XCUIApplication()
        app.launchArguments = [
            "-smbHost", "tropical-bigpc.lan",
            "-smbShare", "sensei",
            "-library",
            "-libraryPath", "American/伞学院/1",
            "-debugLog",
        ]
        app.launch()

        let banner = app.descendants(matching: .any)["prewarm.banner"].firstMatch
        _ = banner.waitForExistence(timeout: 90)
        sleep(5)
        XCUIDevice.shared.press(.home)
        // 等 BGProcessingTask 在后台接管；日志里看“后台预热采样”。
        sleep(180)
        #endif
    }

    /// OOM 验收：根目录全量搜索触发后台索引，命中后直接播放，
    /// 关闭时 ice-acceptance.json 里的 memoryPeakMB 覆盖“搜索累积 + 播放”。
    @MainActor
    func testSearchThenPlayMemoryProbe() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真机专用")
        #else
        let app = XCUIApplication()
        app.launchArguments = [
            "-smbHost", "tropical-bigpc.lan",
            "-smbShare", "sensei",
            "-library",
            "-resetAcceptanceReport",
            "-acceptanceReport",
            "-debugLog",
        ]
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 90), "应连接并进入媒体库")
        search.tap()
        search.typeText("Dopesick")

        let hit = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search.video.")
        ).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 300), "全量索引应命中 Dopesick")

        hit.tap()
        // 视频搜索结果先 reveal 到所在目录，再点目录里的条目才会起播。
        let target = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@",
                "media.",
                "Dopesick"
            )
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 30), "应定位到 Dopesick 条目")
        target.tap()

        let surface = app.descendants(matching: .any)["player.surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 90), "应开始播放")
        sleep(60)

        // 分栏内联播放只有 inline.close；player.close 在非全屏时存在但不可点。
        surface.tap()
        sleep(1)
        let inlineClose = app.buttons["inline.close"]
        let close = inlineClose.exists && inlineClose.isHittable
            ? inlineClose
            : app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "应能关闭播放")
        close.tap()
        sleep(8)
        #endif
    }
}
