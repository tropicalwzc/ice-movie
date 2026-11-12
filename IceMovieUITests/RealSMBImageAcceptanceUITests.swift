import XCTest

/// 真机验收：复用 iPad 上已保存的 `tropical-advpc.lan` / `Photos` 凭据。
final class RealSMBImageAcceptanceUITests: XCTestCase {
    func testPhotosShareLoadsAndOpensImage() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-smbHost", "tropical-advpc.lan",
            "-smbShare", "Photos",
            "-library",
            "-debugLog",
        ]
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 60), "应连接 Photos 共享并进入媒体库")

        let firstMedia = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.")
        ).firstMatch
        XCTAssertTrue(firstMedia.waitForExistence(timeout: 90), "Photos 根目录应显示图片网格")

        let gridShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        gridShot.name = "real-smb-photos-grid"
        gridShot.lifetime = .keepAlways
        add(gridShot)

        let videoChip = app.buttons["filter.video"]
        if videoChip.exists {
            videoChip.tap()
            XCTAssertTrue(firstMedia.waitForExistence(timeout: 15), "取消视频后真实图片应保留")
            videoChip.tap()
        }

        let openBegan = Date()
        firstMedia.tap()
        let close = app.buttons["gallery.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 60), "应打开全屏图片相册")
        XCTAssertTrue(
            app.buttons["gallery.save"].waitForExistence(timeout: 15),
            "保存菜单应常驻，不依赖旋转"
        )
        print(
            "PERF real-smb first image gallery presentation: "
                + "\(String(format: "%.2f", Date().timeIntervalSince(openBegan)))s"
        )

        let galleryShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        galleryShot.name = "real-smb-photos-gallery"
        galleryShot.lifetime = .keepAlways
        add(galleryShot)

        let swipeBegan = Date()
        for _ in 0..<10 {
            app.swipeLeft()
        }
        print(
            "PERF real-smb gallery 10 swipes: "
                + "\(String(format: "%.2f", Date().timeIntervalSince(swipeBegan)))s"
        )
        XCTAssertTrue(close.exists, "真实照片左右滑不应关闭相册")
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 5), "相册应完全关闭")
        XCTAssertTrue(search.waitForExistence(timeout: 15), "关闭相册应回到媒体库")

        sleep(1)
        // 按拍摄时间倒序后，旧的 LIVP 可能在网格很后面；用搜索直接定位，
        // 同时避免依赖测试机当前停留在哪一屏。
        search.tap()
        search.typeText("livp")
        let livpHit = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@",
                "search.image.",
                ".livp"
            )
        ).firstMatch
        XCTAssertTrue(livpHit.waitForExistence(timeout: 20), "真实共享搜索应命中 LIVP")
        livpHit.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 60), "真实 LIVP 应打开相册")
        XCTAssertTrue(
            app.staticTexts["LIVE"].waitForExistence(timeout: 10),
            "LIVP 相册页应显示 LIVE 标识"
        )

        let motionShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        motionShot.name = "real-smb-livp"
        motionShot.lifetime = .keepAlways
        add(motionShot)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.5)
        XCTAssertTrue(close.exists, "真实 LIVP 长按后应仍可关闭")
        close.tap()
    }

    /// 不传连接参数，直接使用 iPad 上已保存的连接恢复上次会话；
    /// 返回根目录后确认 `sensei/1[AnimiAll]` 目录卡片可见。
    func testExistingConnectionRestoresAndShowsCachedFolderCover() {
        let app = XCUIApplication()
        app.launchArguments = ["-debugLog"]
        app.launch()

        let back = app.buttons["返回上一级"]
        XCTAssertTrue(back.waitForExistence(timeout: 60), "应恢复已保存的 SMB 连接")
        var taps = 0
        while back.isEnabled, taps < 6 {
            back.tap()
            taps += 1
            sleep(1)
        }

        let folder = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "media.1[AnimiAll]")
        ).firstMatch
        XCTAssertTrue(
            folder.waitForExistence(timeout: 30),
            "根目录应显示 1[AnimiAll] 目录卡片"
        )
        sleep(2)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "existing-connection-animiall-cover"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(folder.exists, "返回根目录后目录卡片应仍可用")
    }

    /// 视频与子目录混排的目录：目录封面读取内部视频时，网格滚动仍应保持流畅。
    func testVideosStudyFolderCoversAndScrollFluidity() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-smbHost", "tropical-bigpc.lan",
            "-smbShare", "Videos",
            "-libraryPath", "Study",
            "-library",
            "-debugLog",
            "-fpsMonitor",
        ]
        app.launch()

        let firstMedia = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.")
        ).firstMatch
        XCTAssertTrue(
            firstMedia.waitForExistence(timeout: 90),
            "Videos/Study 应显示视频与子目录混排网格"
        )

        let gridShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        gridShot.name = "real-smb-study-folder-covers"
        gridShot.lifetime = .keepAlways
        add(gridShot)

        let began = Date()
        for _ in 0..<10 {
            app.swipeUp()
        }
        print(
            "PERF real-smb study grid 10 swipes: "
                + "\(String(format: "%.2f", Date().timeIntervalSince(began)))s"
        )
        XCTAssertTrue(firstMedia.exists, "滚动后网格应仍可用")
    }

    /// 真机网格滚动诊断：清空缩略图缓存后第一次滚动会同时生成封面，
    /// 用墙钟时间观察瀑布流是否因解码/重排明显变慢。
    func testPhotosGridScrollFluidity() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-smbHost", "tropical-advpc.lan",
            "-smbShare", "Photos",
            "-library",
            "-debugLog",
            "-fpsMonitor",
        ]
        app.launch()

        let firstMedia = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.")
        ).firstMatch
        XCTAssertTrue(firstMedia.waitForExistence(timeout: 90), "Photos 根目录应显示图片网格")

        let began = Date()
        for _ in 0..<10 {
            app.swipeUp()
        }
        print(
            "PERF real-smb grid 10 swipes: "
                + "\(String(format: "%.2f", Date().timeIntervalSince(began)))s"
        )
        XCTAssertTrue(firstMedia.exists, "滚动后网格应仍可用")
    }
}
