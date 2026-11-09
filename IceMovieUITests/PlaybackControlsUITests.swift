import XCTest

@MainActor
final class PlaybackControlsUITests: XCTestCase {
    private let videoPath =
        "/private/tmp/animi/[www.domp4.com]大逃杀.2000.DC.BD1080p.中文字幕.mp4"

    /// 控件会自动隐藏；需要点击顶部返回/关闭或字幕按钮前先轻点画面唤出。
    private func revealPlayerControls(_ app: XCUIApplication) {
        let close = app.buttons["player.close"]
        if !close.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            _ = waitUntilHittable(close, timeout: 3)
        }
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            usleep(100_000)
        }
        return element.isHittable
    }

    func testPausePlayScrubAndAutoHide() {        let app = XCUIApplication()
        app.launchArguments = [
            "-videoTest", videoPath,
            "-videoTestSeconds", "120",
            "-debugLog",
        ]
        app.launch()

        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 12), "播放控件应出现")

        pause.tap()
        let play = app.buttons["播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 3), "暂停后应显示播放按钮")

        let time = app.staticTexts["player.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 3), "时间标签应可访问")
        let beforeForward = seconds(from: time.label)
        app.buttons["快进 10 秒"].tap()
        sleep(1)
        let afterForward = seconds(from: time.label)
        XCTAssertEqual(
            afterForward - beforeForward,
            10,
            accuracy: 2,
            "快进 10 秒后时间应前进约 10 秒"
        )

        app.buttons["快退 10 秒"].tap()
        sleep(1)
        let afterBackward = seconds(from: time.label)
        XCTAssertEqual(
            afterBackward,
            beforeForward,
            accuracy: 2,
            "快退 10 秒后应回到原位置"
        )

        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "恢复后应显示暂停按钮")

        // 暂停后用双击验证 ±10 秒的精确落点；同时检查手势提示。
        pause.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        let pausedTime = seconds(from: time.label)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)).doubleTap()
        let hint = app.descendants(matching: .any)
            .matching(identifier: "player.hint")
            .firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 2), "双击应显示手势提示")
        XCTAssertTrue(hint.label.contains("快进"), "提示应为快进，实际=\(hint.label)")
        sleep(1)
        XCTAssertEqual(
            seconds(from: time.label),
            pausedTime + 10,
            accuracy: 2,
            "右侧双击应快进 10 秒"
        )

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).doubleTap()
        sleep(1)
        XCTAssertEqual(
            seconds(from: time.label),
            pausedTime,
            accuracy: 2,
            "左侧双击应快退 10 秒"
        )

        // 右半屏竖向拖动调音量，左半屏调亮度。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.62))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.38)))
        let volumeHint = app.descendants(matching: .any)
            .matching(identifier: "player.hint")
            .firstMatch
        XCTAssertTrue(volumeHint.waitForExistence(timeout: 2), "右侧竖向拖动应显示提示")
        XCTAssertTrue(volumeHint.label.contains("音量"), "提示应为音量，实际=\(volumeHint.label)")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.62))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.38)))
        let brightnessHint = app.descendants(matching: .any)
            .matching(identifier: "player.hint")
            .firstMatch
        XCTAssertTrue(brightnessHint.waitForExistence(timeout: 2), "左侧竖向拖动应显示提示")
        XCTAssertTrue(brightnessHint.label.contains("亮度"), "提示应为亮度，实际=\(brightnessHint.label)")

        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "恢复后应显示暂停按钮")

        // 拖动到 60%，验证时间超过 1 小时。
        let progress = app.descendants(matching: .any)
            .matching(identifier: "player.progress")
            .firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 3), "进度条应可访问")

        let start = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        sleep(1)
        XCTAssertTrue(
            time.label.contains("1:"),
            "拖到 60% 后时间应超过 1 小时，实际=\(time.label)"
        )

        // 全屏进出后播放位置继续推进。
        app.buttons["全屏"].tap()
        XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 3), "应进入全屏")
        let timeBeforeFullscreenExit = seconds(from: app.staticTexts["player.time"].label)
        sleep(2)
        app.buttons["退出全屏"].tap()
        XCTAssertTrue(app.buttons["全屏"].waitForExistence(timeout: 3), "应退出全屏")
        sleep(1)
        let timeAfterFullscreenExit = seconds(from: app.staticTexts["player.time"].label)
        XCTAssertGreaterThan(
            timeAfterFullscreenExit,
            timeBeforeFullscreenExit,
            "全屏进出后播放位置应继续推进"
        )
    }

    func testProgressTapMatchesFingerPosition() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-videoTest", videoPath,
            "-videoTestSeconds", "120",
            "-debugLog",
        ]
        app.launch()

        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 12))
        pause.tap()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 3))

        let progress = app.descendants(matching: .any)
            .matching(identifier: "player.progress")
            .firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        let time = app.staticTexts["player.time"]
        let duration = app.staticTexts.allElementsBoundByIndex
            .compactMap { seconds(from: $0.label) }
            .max() ?? 0
        XCTAssertGreaterThan(duration, 60)

        let trackInset: CGFloat = 10

        func tapTrack(_ fraction: CGFloat) {
            let frame = progress.frame
            let usable = max(1, frame.width - trackInset * 2)
            let normalized = (trackInset + usable * fraction) / frame.width
            progress.coordinate(
                withNormalizedOffset: CGVector(dx: normalized, dy: 0.5)
            ).tap()
        }

        for fraction in [0.25, 0.5, 0.75] {
            tapTrack(fraction)
            sleep(1)
            let ratio = seconds(from: time.label) / duration
            print("PROGRESS-TAP fraction=\(fraction) ratio=\(ratio) time=\(time.label)")
            XCTAssertEqual(
                ratio,
                fraction,
                accuracy: 0.03,
                "点击进度条 \(fraction) 处应落在对应比例，实际=\(ratio)"
            )
        }

        // 连续拖动到 80%，落点也应对应手指所在位置。
        let frame = progress.frame
        let usable = max(1, frame.width - trackInset * 2)
        let startX = (trackInset + usable * 0.2) / frame.width
        let endX = (trackInset + usable * 0.8) / frame.width
        let start = progress.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
        let end = progress.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
        sleep(1)
        let draggedRatio = seconds(from: time.label) / duration
        print("PROGRESS-DRAG fraction=0.8 ratio=\(draggedRatio) time=\(time.label)")
        XCTAssertEqual(
            draggedRatio,
            0.8,
            accuracy: 0.03,
            "拖动到 80% 应落在对应比例，实际=\(draggedRatio)"
        )
    }

    func testPictureInPictureOnIPad() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-videoTest", videoPath,
            "-videoTestSeconds", "120",
            "-debugLog",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 12), "播放应开始")
        let pipButton = app.buttons["画中画"]
        XCTAssertTrue(pipButton.waitForExistence(timeout: 3), "iPad 应显示画中画按钮")
        pipButton.tap()

        let exitButton = app.buttons["退出画中画"]
        XCTAssertTrue(exitButton.waitForExistence(timeout: 8), "应进入画中画")
        sleep(2)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad-PictureInPicture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testInlinePlaybackOnIPad() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-resetPlaybackProgress",
            "-debugLog",
        ]
        app.launch()

        let folder = app.buttons["迷宫饭"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 12), "根目录应出现「迷宫饭」")
        folder.tap()

        let video = app.buttons["[Sakurato] Dungeon Meshi [01][AVC-8bit 1080p AAC][CHS].mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 10), "目录应出现视频")
        video.tap()

        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 12), "应开始播放")
        XCTAssertTrue(
            app.buttons["退出全屏"].waitForExistence(timeout: 6),
            "iPad 点击视频应直接全屏播放"
        )

        // 退出全屏后回到分栏内联播放，左栏应恢复。
        app.buttons["退出全屏"].tap()
        XCTAssertTrue(exitFullscreenToInline(app), "应回到内联")
        XCTAssertTrue(app.staticTexts["媒体库"].waitForExistence(timeout: 3), "分栏左栏应保持可见")
        XCTAssertTrue(pause.exists, "退出全屏后应继续播放")

        // 内联播放中切换目录，播放器与音频不应中断。
        let root = app.buttons["共享根"]
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        for _ in 0..<10 where !root.isHittable {
            sleep(1)
        }
        XCTAssertTrue(root.isHittable, "共享根应可点击")
        root.tap()
        XCTAssertTrue(
            app.buttons["迷宫饭"].firstMatch.waitForExistence(timeout: 6),
            "应回到共享根网格"
        )
        XCTAssertTrue(app.buttons["暂停"].exists, "切换目录后播放器应仍在")

        for _ in 0..<3 {
            showInlineControls(app)
            let fullscreen = app.buttons["全屏"]
            XCTAssertTrue(fullscreen.waitForExistence(timeout: 4), "内联应提供全屏入口")
            fullscreen.tap()
            sleep(1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "inline-fullscreen-\(UUID().uuidString.prefix(4))"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertTrue(
                app.buttons["退出全屏"].waitForExistence(timeout: 4),
                "应进入全屏"
            )
            sleep(1)
            app.buttons["退出全屏"].tap()
            XCTAssertTrue(exitFullscreenToInline(app), "应回到内联")
            XCTAssertTrue(
                app.staticTexts["媒体库"].waitForExistence(timeout: 3),
                "返回后左栏应恢复"
            )
        }

        XCTAssertTrue(app.buttons["暂停"].exists, "三次往返后应仍在播放")
    }

    func testKeyboardShortcutsAndMenuCommands() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-videoTest", videoPath,
            "-videoTestSeconds", "120",
            "-debugLog",
        ]
        app.launch()

        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 12), "播放应开始")

        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 3), "空格应暂停")

        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 3), "空格应恢复播放")

        let time = app.staticTexts["player.time"]
        let before = seconds(from: time.label)
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        sleep(1)
        XCTAssertGreaterThanOrEqual(
            seconds(from: time.label),
            before + 8,
            "右方向键应快进约 10 秒"
        )

        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        sleep(1)
        XCTAssertLessThan(
            seconds(from: time.label),
            before + 8,
            "左方向键应快退"
        )

        // 菜单栏命令的快捷键。
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 3), "菜单应进入全屏")
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["全屏"].waitForExistence(timeout: 3), "菜单应退出全屏")
    }

    func testExternalASSSubtitleInLibrary() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-resetPlaybackProgress",
            "-debugLog",
        ]
        app.launch()

        let folder = app.buttons["强风吹拂"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 12), "根目录应出现「强风吹拂」")
        folder.tap()

        let video = app.buttons[
            "[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        ]
        XCTAssertTrue(video.waitForExistence(timeout: 10), "目录应出现第 1 集")
        video.tap()

        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 12), "应开始播放")
        let subtitle = app.descendants(matching: .any)
            .matching(identifier: "subtitle.libass")
            .firstMatch
        XCTAssertTrue(
            subtitle.waitForExistence(timeout: 8),
            "外挂中文字幕应通过 libass 渲染"
        )
        let cue = app.staticTexts["subtitle.currentText"].firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 4), "应能读到当前台词")
        XCTAssertFalse(cue.label.isEmpty, "字幕文本不应为空")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "external-ass-subtitle"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPlaybackErrorReturnsToLibrary() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-libraryPath", "错误样本",
            "-resetPlaybackProgress",
            "-debugLog",
        ]
        app.launch()

        let broken = app.buttons["损坏的视频.mp4"]
        XCTAssertTrue(broken.waitForExistence(timeout: 10), "应出现损坏样本")
        broken.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "应弹出播放失败提示")
        XCTAssertTrue(
            alert.staticTexts["无法解析这个视频"].exists,
            "解封装失败应有独立提示，实际=\(alert.label)"
        )
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "文件可能已损坏")
            ).firstMatch.exists,
            "提示应说明可能原因"
        )

        alert.buttons["返回媒体库"].tap()
        XCTAssertTrue(broken.waitForExistence(timeout: 4), "关闭提示后应回到媒体库")
    }

    func testResumeFromLastPosition() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-libraryPath", "强风吹拂",
            "-resetPlaybackProgress",
            "-keepControlsVisible",
            "-debugLog",
        ]
        app.launch()

        let episode = app.buttons[
            "[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        ]
        XCTAssertTrue(episode.waitForExistence(timeout: 10), "应出现第 1 集")
        episode.tap()

        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 20), "应开始播放")
        let time = app.staticTexts["player.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 10), "时间标签应可访问")

        // 播放超过 5 秒续播阈值后关闭，确保进度被记录。
        // iPhone 进入/退出横屏时 XCUITest 的快照会短暂变慢，用固定等待避免反复查询。
        sleep(9)
        let beforeClose = seconds(from: time.label)
        XCTAssertGreaterThanOrEqual(beforeClose, 8, "应播放到 8 秒以上")

        revealPlayerControls(app)
        app.buttons["player.close"].tap()
        XCTAssertTrue(waitUntilHittable(episode, timeout: 15), "应回到目录且可点击")
        episode.tap()

        let notice = app.staticTexts["resume.text"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "重开应提示已续播")
        XCTAssertTrue(notice.label.contains("已续播"), "提示文案应说明已续播，实际=\(notice.label)")

        let resumedDeadline = Date().addingTimeInterval(6)
        while seconds(from: time.label) < beforeClose - 2, Date() < resumedDeadline {
            sleep(1)
        }
        let resumed = seconds(from: time.label)
        XCTAssertGreaterThanOrEqual(
            resumed,
            beforeClose - 2,
            "应从上次位置继续，关闭时=\(beforeClose)s 续播=\(resumed)s"
        )

        app.buttons["resume.restart"].tap()
        sleep(2)
        XCTAssertLessThan(seconds(from: time.label), 5, "从头播放应回到开头")
        XCTAssertFalse(notice.exists, "选择从头后提示应消失")
    }

    func testAutoPlayNextEpisode() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-libraryPath", "强风吹拂",
            "-resetPlaybackProgress",
            "-libraryOpenFirst",
            "-libraryOpenName", "[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01",
            "-librarySeekTo", "1364",
            "-debugLog",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15), "应开始播放")
        let time = app.staticTexts["player.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 3))

        // 起播 3 秒后自动跳到片尾附近。
        let seekDeadline = Date().addingTimeInterval(15)
        while seconds(from: time.label) < 1_000, Date() < seekDeadline {
            sleep(1)
        }
        XCTAssertGreaterThanOrEqual(
            seconds(from: time.label),
            1_000,
            "应跳到片尾附近，实际=\(time.label)"
        )

        // 播完后应自动打开同目录下一集，时间回到开头。
        let nextDeadline = Date().addingTimeInterval(30)
        while seconds(from: time.label) > 120, Date() < nextDeadline {
            sleep(1)
        }
        XCTAssertLessThan(
            seconds(from: time.label),
            120,
            "应自动播放下一集，实际=\(time.label)"
        )
        XCTAssertTrue(app.buttons["暂停"].exists, "下一集应处于播放状态")
    }

    func testOpenFromSearchPresentsPlayer() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-libraryPath", "re0 s3",
            "-resetPlaybackProgress",
            "-debugLog",
        ]
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "搜索框应出现")
        search.tap()
        search.typeText("Re-Zero")
        sleep(2)

        let result = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Re-Zero"))
            .firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "搜索结果应出现")
        result.tap()

        // 搜索结果是“定位到目录”，进入目录后再点视频，模拟真实使用路径。
        let video = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Re-Zero"))
            .firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10), "目录中的视频应出现")
        video.tap()

        // 键盘仍在收起动画中时，全屏播放器也必须真正出现。
        XCTAssertTrue(
            app.buttons["暂停"].waitForExistence(timeout: 15),
            "从搜索结果打开视频应进入播放器"
        )
    }

    func testSwitchShareWithoutDisconnect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-debugLog"]
        app.launch()

        // 依赖本机已保存的 SMB 测试主机；没有配置时跳过，避免污染普通回归。
        let target = app.buttons["iceBaseShare2"].firstMatch
        guard target.waitForExistence(timeout: 20) else {
            throw XCTSkip("未配置多共享测试主机")
        }

        target.tap()
        XCTAssertTrue(
            app.buttons["0bestGen"].firstMatch.waitForExistence(timeout: 20),
            "切换共享后应列出新共享根目录"
        )
        XCTAssertTrue(app.staticTexts["主机"].exists, "切换共享不应退出媒体库")
        XCTAssertFalse(app.staticTexts["连接 SMB"].exists, "不应回到连接页")

        let back = app.buttons["Animi"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(
            app.buttons["白箱"].firstMatch.waitForExistence(timeout: 20),
            "切回 Animi 后应恢复其根目录"
        )
    }

    func testSubtitleSwitchAndPreferencePersistence() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/animi",
            "-libraryPath", "强风吹拂",
            "-resetSubtitlePreferences",
            "-resetPlaybackProgress",
            "-keepControlsVisible",
            "-debugLog",
        ]
        app.launch()

        func openSubtitleMenu() {
            revealPlayerControls(app)
            let button = app.buttons["字幕"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            let panel = app.descendants(matching: .any)
                .matching(identifier: "subtitle.panel")
                .firstMatch
            if !panel.waitForExistence(timeout: 2) {
                sleep(1)
                button.tap()
            }
            XCTAssertTrue(panel.waitForExistence(timeout: 3), "字幕面板应打开")
        }

        let episode1 = app.buttons[
            "[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        ]
        XCTAssertTrue(episode1.waitForExistence(timeout: 10), "应出现第 1 集")
        episode1.tap()

        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 12), "应开始播放")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 3), "空格应暂停")

        let subtitle = app.descendants(matching: .any)
            .matching(identifier: "subtitle.libass")
            .firstMatch
        let cue = app.staticTexts["subtitle.currentText"].firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 8), "简体字幕应出现")
        XCTAssertTrue(cue.waitForExistence(timeout: 4), "应能读到当前字幕文本")
        XCTAssertTrue(cue.label.contains("诸神"), "默认应为简体，实际=\(cue.label)")

        openSubtitleMenu()
        let traditional = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "繁体中文"))
            .firstMatch
        XCTAssertTrue(traditional.waitForExistence(timeout: 3), "面板应包含繁体中文")
        traditional.tap()
        sleep(2)
        app.buttons["关闭字幕面板"].tap()
        sleep(1)

        XCTAssertEqual(
            app.buttons["字幕"].value as? String,
            "繁体中文",
            "切换后字幕菜单应显示繁体中文"
        )
        XCTAssertTrue(
            cue.label.contains("諸神"),
            "切换后应显示繁体文本，实际=\(cue.label)"
        )

        // 7.5：播放中关闭字幕后界面状态立即更新，再次打开可恢复。
        openSubtitleMenu()
        app.buttons["subtitle.track.off"].tap()
        app.buttons["关闭字幕面板"].tap()
        sleep(1)
        XCTAssertEqual(
            app.buttons["字幕"].value as? String,
            "关闭",
            "关闭字幕后状态应更新"
        )
        XCTAssertFalse(subtitle.exists, "关闭字幕后不应再显示字幕文本")
        openSubtitleMenu()
        XCTAssertTrue(traditional.waitForExistence(timeout: 3), "重新打开面板应仍可看到繁体轨")
        traditional.tap()
        app.buttons["关闭字幕面板"].tap()
        sleep(1)

        // 7.6：调整字号、位置与偏移，并确认面板数值立即变化。
        openSubtitleMenu()
        app.buttons["字号增大"].tap()
        app.buttons["字号增大"].tap()
        app.buttons["上移"].tap()
        app.buttons["字幕延迟"].tap()
        XCTAssertEqual(app.staticTexts["subtitle.fontSize"].label, "26")
        XCTAssertEqual(app.staticTexts["subtitle.bottomPadding"].label, "150")
        XCTAssertEqual(app.staticTexts["subtitle.offset"].label, "+0.5s")
        app.buttons["关闭字幕面板"].tap()
        sleep(1)

        // 恢复播放，确认字幕切换/调整不影响播放进度。
        let time = app.staticTexts["player.time"]
        let before = seconds(from: time.label)
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "空格应恢复播放")
        sleep(2)
        XCTAssertGreaterThan(
            seconds(from: time.label),
            before,
            "切换字幕与调整样式后播放应继续"
        )

        app.buttons["关闭播放"].tap()
        let episode2 = app.buttons[
            "[Kamigami] Kaze ga Tsuyoku Fuiteiru - 02 [BD 1080p x265 Ma10p AAC].mkv"
        ]
        XCTAssertTrue(episode2.waitForExistence(timeout: 6), "应回到第 2 集网格")
        episode2.tap()

        XCTAssertTrue(pause.waitForExistence(timeout: 12), "第 2 集应开始播放")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 3), "空格应暂停")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 8), "第 2 集字幕应出现")
        openSubtitleMenu()
        let menu = app.buttons["字幕"]
        XCTAssertEqual(
            menu.value as? String,
            "繁体中文",
            "下一集应沿用上次选择的繁体中文"
        )
        XCTAssertEqual(app.staticTexts["subtitle.fontSize"].label, "26", "字号应沿用")
        XCTAssertEqual(app.staticTexts["subtitle.bottomPadding"].label, "150", "位置应沿用")
        XCTAssertEqual(app.staticTexts["subtitle.offset"].label, "+0.5s", "偏移应沿用")
    }

    private func showInlineControls(_ app: XCUIApplication) {
        guard !app.buttons["全屏"].isHittable else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.15)).tap()
        sleep(1)
    }

    /// 退出全屏并等待内联播放器出现；控件自动隐藏时先唤出再点。
    private func exitFullscreenToInline(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if app.buttons["全屏"].exists { return true }
            if app.buttons["退出全屏"].exists {
                app.buttons["退出全屏"].tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.15)).tap()
            }
            sleep(1)
        }
        return app.buttons["全屏"].exists
    }

    private func seconds(from label: String) -> Double {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
