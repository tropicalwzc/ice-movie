import XCTest

final class ImageGalleryUITests: XCTestCase {
    private let fixturePath = "/private/tmp/icemovie-image-fixture"
    private let filterEmptyPath = "/private/tmp/icemovie-image-fixture-empty"
    private let largeFixturePath = "/private/tmp/icemovie-image-fixture-500"
    private let timestampedPath = "/private/tmp/icemovie-image-fixture-dates"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try buildFixtureDirectory()
    }

    func testFilterAndGallerySmoke() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let videoChip = app.buttons["filter.video"]
        let imageChip = app.buttons["filter.image"]
        XCTAssertTrue(videoChip.waitForExistence(timeout: 15), "混合目录应显示视频过滤按钮")
        XCTAssertTrue(imageChip.exists, "混合目录应显示图片过滤按钮")

        let video = element(app, "media.clip.mov")
        let image = element(app, "media.sample-landscape.png")
        XCTAssertTrue(video.waitForExistence(timeout: 10), "应显示视频条目")
        XCTAssertTrue(image.waitForExistence(timeout: 10), "应显示图片条目")

        videoChip.tap()
        XCTAssertFalse(video.waitForExistence(timeout: 2), "取消视频后不应再显示视频")
        XCTAssertTrue(image.exists, "取消视频后图片应保留")

        imageChip.tap()
        XCTAssertFalse(image.waitForExistence(timeout: 2), "取消图片后不应再显示图片")
        XCTAssertTrue(element(app, "media.sub").exists, "全部取消后应只显示子目录")

        imageChip.tap()
        videoChip.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 3), "恢复过滤后应重新显示视频")
        XCTAssertTrue(image.exists, "恢复过滤后应重新显示图片")

        image.tap()
        let close = app.buttons["gallery.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "点击图片应打开全屏相册")
        XCTAssertTrue(element(app, "gallery.counter").exists, "相册应显示页码")

        XCTAssertTrue(app.staticTexts["LIVE"].exists, "网格应显示 LIVP 标识")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "image-gallery"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.swipeLeft()
        XCTAssertTrue(close.exists, "左右滑不应关闭相册")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(close.exists, "双击缩放不应关闭相册")

        app.pinch(withScale: 1.8, velocity: 1)
        XCTAssertTrue(close.exists, "双指缩放不应关闭相册")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(close.waitForExistence(timeout: 5), "旋转后相册应保持打开")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(close.waitForExistence(timeout: 5), "恢复竖屏后相册应保持打开")

        XCTAssertTrue(close.isHittable, "关闭按钮应可点击")
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 5), "关闭按钮点击后相册应消失")
        XCTAssertTrue(videoChip.waitForExistence(timeout: 5), "关闭相册应回到网格")
    }

    func testSearchImageOpensGallery() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "应显示搜索框")
        search.tap()
        search.typeText("landscape")

        let imageHit = element(app, "search.image.sample-landscape.png")
        XCTAssertTrue(imageHit.waitForExistence(timeout: 10), "搜索应命中图片")
        imageHit.tap()

        let close = app.buttons["gallery.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "点击图片搜索结果应直接打开相册")
        close.tap()
    }

    func testLivePhotoLongPressSmoke() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let livp = scrollToMedia(app, "media.sample-stored.livp")
        XCTAssertTrue(livp.waitForExistence(timeout: 15), "应显示 LIVP 条目")
        livp.tap()

        let close = app.buttons["gallery.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "LIVP 应打开相册")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "live-photo-motion"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(close.exists, "长按动态后相册应保持可用")
        close.tap()
    }

    func testRotateAndOverwriteLocalImage() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let image = element(app, "media.sample-landscape.png")
        XCTAssertTrue(image.waitForExistence(timeout: 20), "应显示图片")
        image.tap()

        let close = app.buttons["gallery.close"]
        let rotate = app.buttons["gallery.rotate"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "应打开相册")
        XCTAssertTrue(rotate.waitForExistence(timeout: 10), "应显示旋转按钮")
        for _ in 0..<40 where !rotate.isEnabled {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(rotate.isEnabled, "图片加载完成后旋转按钮应可用")
        rotate.tap()

        let rotatedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rotatedShot.name = "gallery-rotated"
        rotatedShot.lifetime = .keepAlways
        add(rotatedShot)

        let save = app.buttons["gallery.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "旋转后应出现保存菜单")
        save.tap()
        XCTAssertTrue(
            app.buttons["覆盖原照片"].waitForExistence(timeout: 5),
            "保存菜单应包含覆盖原照片"
        )
        app.buttons["覆盖原照片"].tap()
        XCTAssertTrue(
            app.buttons["覆盖保存"].waitForExistence(timeout: 5),
            "应弹出覆盖确认"
        )
        app.buttons["覆盖保存"].tap()

        let overwriteNotice = element(app, "gallery.notice")
        XCTAssertTrue(
            overwriteNotice.waitForExistence(timeout: 20),
            "覆盖保存应成功"
        )
        XCTAssertTrue(overwriteNotice.label.contains("已覆盖"))
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 5), "关闭后应回到网格")
    }

    func testMasonryUsesNaturalImageAspect() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let landscape = element(app, "media.sample-landscape.png")
        let portrait = element(app, "media.sample-portrait.png")
        XCTAssertTrue(landscape.waitForExistence(timeout: 20), "应显示横图")
        XCTAssertTrue(portrait.waitForExistence(timeout: 20), "应显示竖图")

        XCTAssertEqual(
            landscape.frame.width,
            portrait.frame.width,
            accuracy: 1,
            "瀑布流各列宽度应一致"
        )
        XCTAssertNotEqual(
            landscape.frame.height,
            portrait.frame.height,
            accuracy: 20,
            "瀑布流应按图片比例使用不同单元格高度"
        )
        XCTAssertGreaterThan(
            portrait.frame.height,
            landscape.frame.height,
            "竖图单元格应明显高于横图"
        )
    }

    func testRotateAfterSwipingToAnotherImage() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let image = element(app, "media.sample-landscape.png")
        XCTAssertTrue(image.waitForExistence(timeout: 20), "应显示图片")
        image.tap()

        let close = app.buttons["gallery.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "应打开相册")

        app.swipeLeft()

        let rotate = app.buttons["gallery.rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10), "应显示旋转按钮")
        for _ in 0..<60 where !rotate.isEnabled {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(rotate.isEnabled, "翻到下一张后旋转按钮应可用")
        rotate.tap()

        let save = app.buttons["gallery.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "旋转后应出现保存菜单")
        save.tap()
        XCTAssertTrue(
            app.buttons["覆盖原照片"].waitForExistence(timeout: 5),
            "翻页后旋转也应进入覆盖保存流程"
        )

        // 关闭菜单，但不实际覆盖 fixture。
        if !close.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        close.tap()
    }

    func testSaveToSystemPhotosWithoutRotation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let image = element(app, "media.sample-portrait.png")
        XCTAssertTrue(image.waitForExistence(timeout: 20), "应显示图片")
        image.tap()

        XCTAssertTrue(app.buttons["gallery.close"].waitForExistence(timeout: 15), "应打开相册")
        let save = app.buttons["gallery.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 20), "保存按钮应常驻，不依赖旋转")
        save.tap()
        XCTAssertFalse(
            app.buttons["覆盖原照片"].exists,
            "没有旋转时不应提供覆盖原照片"
        )
        XCTAssertTrue(
            app.buttons["保存到系统相册"].waitForExistence(timeout: 5),
            "保存菜单应包含系统相册"
        )
        app.buttons["保存到系统相册"].tap()
        let photosNotice = element(app, "gallery.notice")
        XCTAssertTrue(
            photosNotice.waitForExistence(timeout: 30),
            "应成功加入系统照片库"
        )
        XCTAssertTrue(photosNotice.label.contains("系统相册"))
        app.buttons["gallery.close"].tap()
    }

    func testTimestampNewestFirstAndCalendarJump() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", timestampedPath,
            "-debugLog",
        ]
        app.launch()

        let mediaCells = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.")
        )
        let first = mediaCells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "应显示时间戳图片")
        XCTAssertTrue(
            first.identifier.contains("march_20220310"),
            "最新时间戳的图片应排在最前，实际=\(first.identifier)"
        )
        let captureDate = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "2022年3月10日")
        ).firstMatch
        XCTAssertTrue(
            captureDate.waitForExistence(timeout: 10),
            "图片下方应显示文件名中的拍摄日期，而不是文件修改时间"
        )

        let calendar = app.buttons["filter.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "照片目录应显示日历按钮")
        calendar.tap()

        let january = element(app, "calendar.month.1")
        XCTAssertTrue(january.waitForExistence(timeout: 10), "日历应能选择 2022 年 1 月")
        january.tap()

        let oldDay = element(app, "calendar.day.2022-1-1")
        XCTAssertTrue(oldDay.waitForExistence(timeout: 10), "日历应能选择 2022-01-01")
        oldDay.tap()

        let target = element(app, "media.target_20220101000000.jpg")
        XCTAssertTrue(
            target.waitForExistence(timeout: 10),
            "选择旧日期后应跳转到该日期的照片"
        )
        for _ in 0..<30 where !target.isHittable {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(target.isHittable, "跳转后目标照片应滚动到可见区域")
    }

    func testCalendarMonthJump() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", timestampedPath,
            "-debugLog",
        ]
        app.launch()

        let first = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.")
        ).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "应显示时间戳图片")

        let calendar = app.buttons["filter.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "照片目录应显示日历按钮")
        calendar.tap()

        let monthJump = app.buttons["calendar.monthJump"]
        XCTAssertTrue(monthJump.waitForExistence(timeout: 10), "日历应提供整月跳转")
        XCTAssertTrue(monthJump.label.contains("2022年3月"), "默认应指向最新月份")

        let yearPicker = app.buttons["calendar.yearPicker"]
        XCTAssertTrue(yearPicker.waitForExistence(timeout: 5), "应显示年份选择")
        yearPicker.tap()
        let yearButton = app.buttons["2021年"].firstMatch
        if yearButton.waitForExistence(timeout: 5) {
            yearButton.tap()
        } else {
            let yearText = app.staticTexts["2021年"].firstMatch
            XCTAssertTrue(yearText.waitForExistence(timeout: 5), "年份菜单应包含 2021 年")
            yearText.tap()
        }

        XCTAssertTrue(monthJump.label.contains("2021年12月"), "应切换到 2021 年 12 月")
        monthJump.tap()

        let target = element(app, "media.old_20211215000000.jpg")
        XCTAssertTrue(target.waitForExistence(timeout: 10), "整月跳转应定位到该月照片")
        for _ in 0..<30 where !target.isHittable {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(target.isHittable, "整月跳转后目标照片应滚动到可见区域")
    }

    func testFilterEmptyStateAndReset() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", filterEmptyPath,
            "-debugLog",
        ]
        app.launch()

        let videoChip = app.buttons["filter.video"]
        let imageChip = app.buttons["filter.image"]
        XCTAssertTrue(videoChip.waitForExistence(timeout: 15), "应显示过滤条")
        videoChip.tap()
        imageChip.tap()

        XCTAssertTrue(
            app.staticTexts["当前筛选下没有内容"].waitForExistence(timeout: 5),
            "全部取消且没有子目录时应显示筛选空状态"
        )
        app.buttons["显示全部"].tap()
        XCTAssertTrue(
            element(app, "media.clip.mov").waitForExistence(timeout: 5),
            "显示全部后应恢复视频"
        )
        XCTAssertTrue(element(app, "media.sample.jpg").exists, "显示全部后应恢复图片")
    }

    func testBrokenImageShowsRetry() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let broken = element(app, "media.broken.jpg")
        XCTAssertTrue(broken.waitForExistence(timeout: 15), "应列出损坏图片")
        broken.tap()

        XCTAssertTrue(app.buttons["gallery.close"].waitForExistence(timeout: 10), "应打开相册")
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 10), "损坏图片应显示重试")
        app.buttons["gallery.close"].tap()
    }

    func testVideoSearchRestoresHiddenFilter() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", fixturePath,
            "-debugLog",
        ]
        app.launch()

        let videoChip = app.buttons["filter.video"]
        XCTAssertTrue(videoChip.waitForExistence(timeout: 15), "应显示过滤条")
        videoChip.tap()
        XCTAssertFalse(
            element(app, "media.clip.mov").waitForExistence(timeout: 2),
            "先隐藏视频"
        )

        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("clip")
        let hit = element(app, "search.video.clip.mov")
        XCTAssertTrue(hit.waitForExistence(timeout: 10), "搜索应命中视频")
        hit.tap()

        XCTAssertTrue(
            element(app, "media.clip.mov").waitForExistence(timeout: 5),
            "定位被过滤的视频时应自动恢复视频类型"
        )
        XCTAssertEqual(videoChip.value as? String, "已选中")
    }

    func testLargeDirectoryScrollSmoke() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", largeFixturePath,
            "-debugLog",
        ]
        app.launch()

        let first = element(app, "media.IMG_0001.jpg")
        XCTAssertTrue(first.waitForExistence(timeout: 20), "500 张图片目录应显示首张")

        let began = Date()
        for _ in 0..<20 {
            app.swipeUp()
        }
        let elapsed = Date().timeIntervalSince(began)
        print("PERF image-gallery: 500-image directory, 20 swipes, elapsed=\(String(format: "%.2f", elapsed))s")
        let visibleImages = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.IMG_")
        )
        XCTAssertGreaterThan(visibleImages.count, 0, "滚动后网格应仍可用")
    }

    func testThumbnailPrewarmBannerPauseResumeCancel() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", largeFixturePath,
            "-debugLog",
            "-enableLocalThumbnailSidecar",
            "-prewarmTestDelayMs", "50",
        ]
        app.launch()

        let banner = element(app, "prewarm.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 90), "应显示缩略图预热进度")

        let pause = app.buttons["prewarm.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(
            app.buttons["prewarm.resume"].waitForExistence(timeout: 5),
            "暂停后应能继续"
        )
        app.buttons["prewarm.resume"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "继续后应恢复暂停按钮")

        app.buttons["prewarm.cancel"].tap()
        XCTAssertFalse(banner.waitForExistence(timeout: 10), "取消后进度条应消失")
    }

    func testGallery200PageMemory() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", largeFixturePath,
            "-debugLog",
        ]
        app.launch()

        let first = element(app, "media.IMG_0001.jpg")
        XCTAssertTrue(first.waitForExistence(timeout: 20), "应显示图片网格")
        first.tap()

        let close = app.buttons["gallery.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), "应打开相册")

        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()], options: options) {
            for _ in 0..<200 {
                app.swipeLeft()
            }
        }
        XCTAssertTrue(close.exists, "连续翻页后相册应仍可用")
        close.tap()
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// 网格是 LazyVGrid，靠后的条目只有滚到附近才会创建。
    private func scrollToMedia(
        _ app: XCUIApplication,
        _ identifier: String,
        maxSwipes: Int = 8
    ) -> XCUIElement {
        let target = app.buttons[identifier]
        var swipes = 0
        while (!target.exists || !target.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return target
    }

    private func buildFixtureDirectory() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: fixturePath)
        try fileManager.createDirectory(
            atPath: fixturePath,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            atPath: "\(fixturePath)/sub",
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(atPath: filterEmptyPath)
        try fileManager.createDirectory(
            atPath: filterEmptyPath,
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(atPath: largeFixturePath)
        try fileManager.createDirectory(
            atPath: largeFixturePath,
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(atPath: timestampedPath)
        try fileManager.createDirectory(
            atPath: timestampedPath,
            withIntermediateDirectories: true
        )

        let bundle = Bundle(for: Self.self)
        guard let fixtureRoot = bundle.url(
            forResource: "ImageGallery",
            withExtension: nil
        ) else {
            throw XCTSkip("UI 测试缺少 ImageGallery fixture 资源")
        }

        let copies: [(String, String)] = [
            ("sample.jpg", "sample.jpg"),
            ("sample.heic", "sample.heic"),
            ("sample-alpha.png", "sample-alpha.png"),
            ("sample-landscape.png", "sample-landscape.png"),
            ("sample-portrait.png", "sample-portrait.png"),
            ("sample-stored.livp", "sample-stored.livp"),
            ("motion.mov", "clip.mov"),
            ("broken.livp", "broken.jpg"),
        ]
        for (source, destination) in copies {
            try fileManager.copyItem(
                at: fixtureRoot.appendingPathComponent(source),
                to: URL(fileURLWithPath: "\(fixturePath)/\(destination)")
            )
        }
        try fileManager.copyItem(
            at: fixtureRoot.appendingPathComponent("sample.jpg"),
            to: URL(fileURLWithPath: "\(fixturePath)/sub/sample.jpg")
        )
        try fileManager.copyItem(
            at: fixtureRoot.appendingPathComponent("sample.jpg"),
            to: URL(fileURLWithPath: "\(filterEmptyPath)/sample.jpg")
        )
        try fileManager.copyItem(
            at: fixtureRoot.appendingPathComponent("motion.mov"),
            to: URL(fileURLWithPath: "\(filterEmptyPath)/clip.mov")
        )
        let imageSource = fixtureRoot.appendingPathComponent("sample.jpg")
        for index in 1...500 {
            let name = String(format: "IMG_%04d.jpg", index)
            try fileManager.copyItem(
                at: imageSource,
                to: URL(fileURLWithPath: "\(largeFixturePath)/\(name)")
            )
        }
        for index in 0..<20 {
            let name = String(format: "new_202201020000%02d.jpg", index)
            try fileManager.copyItem(
                at: imageSource,
                to: URL(fileURLWithPath: "\(timestampedPath)/\(name)")
            )
        }
        try fileManager.copyItem(
            at: imageSource,
            to: URL(fileURLWithPath: "\(timestampedPath)/target_20220101000000.jpg")
        )
        try fileManager.copyItem(
            at: imageSource,
            to: URL(fileURLWithPath: "\(timestampedPath)/march_20220310000000.jpg")
        )
        try fileManager.copyItem(
            at: imageSource,
            to: URL(fileURLWithPath: "\(timestampedPath)/old_20211215000000.jpg")
        )
    }
}
