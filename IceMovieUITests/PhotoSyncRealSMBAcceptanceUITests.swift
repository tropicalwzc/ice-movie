import XCTest

/// 真机 + 真实 SMB：tropical-advpc.lan / Photos 只读预览。
/// 不使用 fixture，复用设备 Keychain 中已保存的凭据；不开始上传。
final class PhotoSyncRealSMBAcceptanceUITests: XCTestCase {
    private func element(
        _ app: XCUIApplication,
        _ identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func value(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = element(app, identifier)
        return element.exists ? element.label : "0"
    }

    private func number(_ text: String) -> Int {
        Int(text.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    func testPhotosShareReadOnlyPreview() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真机专用")
        #else
        let app = XCUIApplication()
        app.launchArguments = [
            "-library",
            "-smbHost", "tropical-advpc.lan",
            "-smbShare", "Photos",
            "-photoSyncResetTarget",
            "-debugLog",
        ]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLocalNetwork = springboard.buttons["允许"]
        if allowLocalNetwork.waitForExistence(timeout: 5) {
            allowLocalNetwork.tap()
        }

        let more = app.buttons["更多"]
        XCTAssertTrue(
            more.waitForExistence(timeout: 120),
            "应连接 Photos 共享并显示媒体库"
        )
        more.tap()
        sleep(1)

        let mark = element(app, "photoSync.menu.mark")
        if mark.waitForExistence(timeout: 5) {
            mark.tap()
        } else {
            let fallback = app.buttons["设为照片库路径"]
            XCTAssertTrue(
                fallback.waitForExistence(timeout: 5),
                "应能标记当前目录为照片库路径"
            )
            fallback.tap()
        }

        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(
            syncButton.waitForExistence(timeout: 15),
            "标记后应出现同步按钮"
        )
        syncButton.tap()

        let allowPhotos = springboard.buttons["允许完全访问"]
        if allowPhotos.waitForExistence(timeout: 15) {
            allowPhotos.tap()
        }

        let start = element(app, "photoSync.review.start")
        XCTAssertTrue(
            start.waitForExistence(timeout: 180),
            "应完成系统相册与 Photos 共享的只读扫描"
        )

        let accessible = value(app, "photoSync.review.accessible.value")
        let live = value(app, "photoSync.review.live.value")
        let video = value(app, "photoSync.review.video.value")
        let unsupported = value(app, "photoSync.review.unsupported.value")
        let missingDate = value(app, "photoSync.review.missingDate.value")
        let remote = value(app, "photoSync.review.remoteImages.value")
        let matched = value(app, "photoSync.review.matched.value")
        let pending = value(app, "photoSync.review.pending.value")
        let authorization = value(app, "photoSync.review.authorization")
        let dateRange = value(app, "photoSync.review.dateRange")

        let report = """
        PHOTO_SYNC_REAL_SMB accessible=\(accessible) live=\(live) video=\(video) \
        unsupported=\(unsupported) missingDate=\(missingDate) remote=\(remote) \
        matched=\(matched) pending=\(pending) authorization=\(authorization) \
        dateRange=\(dateRange)
        """
        print(report)
        XCTContext.runActivity(named: "Photos 只读预览计数") { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = "photo-sync-real-smb-counts"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "photo-sync-real-smb-preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertGreaterThan(
            number(remote),
            3_000,
            "Photos 共享应已有约 3,596 张图片"
        )
        XCTAssertGreaterThan(
            number(accessible),
            0,
            "iPad 系统相册应可访问照片"
        )
        XCTAssertGreaterThanOrEqual(
            number(pending),
            0,
            "待同步计数应可读"
        )

        let cancel = element(app, "photoSync.review.cancel")
        XCTAssertTrue(cancel.exists, "只读预览应可取消")
        cancel.tap()
        #endif
    }

    func testPhotosShareSmallBatchUpload() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("真机专用")
        #else
        let app = XCUIApplication()
        app.launchArguments = [
            "-library",
            "-smbHost", "tropical-advpc.lan",
            "-smbShare", "Photos",
            "-photoSyncResetTarget",
            "-photoSyncUploadLimit", "2",
            "-debugLog",
        ]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLocalNetwork = springboard.buttons["允许"]
        if allowLocalNetwork.waitForExistence(timeout: 5) {
            allowLocalNetwork.tap()
        }

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 120))
        more.tap()
        sleep(1)
        let mark = element(app, "photoSync.menu.mark")
        if mark.waitForExistence(timeout: 5) {
            mark.tap()
        } else {
            app.buttons["设为照片库路径"].tap()
        }

        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 15))
        syncButton.tap()

        let allowPhotos = springboard.buttons["允许完全访问"]
        if allowPhotos.waitForExistence(timeout: 15) {
            allowPhotos.tap()
        }

        let start = element(app, "photoSync.review.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180))
        let beforePending = number(value(app, "photoSync.review.pending.value"))
        let beforeRemote = number(value(app, "photoSync.review.remoteImages.value"))
        let beforeMatched = number(value(app, "photoSync.review.matched.value"))
        XCTAssertGreaterThanOrEqual(beforePending, 2, "至少应有 2 张可上传照片")

        start.tap()

        let statusBar = element(app, "photoSync.statusBar")
        XCTAssertTrue(
            statusBar.waitForExistence(timeout: 10),
            "上传期间应显示状态条"
        )
        XCTAssertTrue(
            statusBar.waitForNonExistence(timeout: 180),
            "限定 2 张的上传应在完成后自动隐藏状态条"
        )

        let syncAgain = element(app, "photoSync.button")
        XCTAssertTrue(syncAgain.waitForExistence(timeout: 10))
        syncAgain.tap()

        let startAgain = element(app, "photoSync.review.start")
        XCTAssertTrue(startAgain.waitForExistence(timeout: 180))
        let afterPending = number(value(app, "photoSync.review.pending.value"))
        let afterRemote = number(value(app, "photoSync.review.remoteImages.value"))
        let afterMatched = number(value(app, "photoSync.review.matched.value"))

        let report = """
        PHOTO_SYNC_REAL_SMB_UPLOAD before(remote=\(beforeRemote) matched=\(beforeMatched) \
        pending=\(beforePending)) after(remote=\(afterRemote) matched=\(afterMatched) \
        pending=\(afterPending))
        """
        print(report)
        XCTContext.runActivity(named: "Photos 小批量上传计数") { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = "photo-sync-real-smb-upload-counts"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertEqual(
            afterRemote,
            beforeRemote + 2,
            "远端图片应增加 2 张"
        )
        XCTAssertEqual(
            afterMatched,
            beforeMatched + 2,
            "第二次扫描应匹配刚上传的 2 张"
        )
        XCTAssertEqual(
            afterPending,
            beforePending - 2,
            "待同步应减少 2 张且不重复上传"
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "photo-sync-real-smb-upload"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        element(app, "photoSync.review.cancel").tap()
        #endif
    }
}
