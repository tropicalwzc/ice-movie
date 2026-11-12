import UIKit
import XCTest

@MainActor
final class PhotoSyncUITests: XCTestCase {
    private func element(
        _ app: XCUIApplication,
        _ identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func markCurrentDirectory(_ app: XCUIApplication) {
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 15), "应显示更多菜单")
        more.tap()
        sleep(1)

        let mark = element(app, "photoSync.menu.mark")
        if mark.waitForExistence(timeout: 3) {
            mark.tap()
        } else {
            let fallback = app.buttons["设为照片库路径"]
            XCTAssertTrue(fallback.waitForExistence(timeout: 3), "菜单应包含设为照片库路径")
            fallback.tap()
        }
        sleep(1)
    }

    private func tapStart(_ app: XCUIApplication) {
        let start = element(app, "photoSync.review.start")
        XCTAssertTrue(start.waitForExistence(timeout: 15), "应出现同步预览")
        sleep(1)
        start.tap()
    }

    func testMarkSyncRefreshAndSecondRunUpToDate() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-photoSyncFixture",
            "-photoSyncResetTarget",
            "-debugLog",
        ]
        app.launch()

        markCurrentDirectory(app)

        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 8), "标记后应出现同步按钮")
        syncButton.tap()

        let start = element(app, "photoSync.review.start")
        XCTAssertTrue(start.waitForExistence(timeout: 15), "应出现同步预览")

        let pending = element(app, "photoSync.review.pending")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        let pendingValue = element(app, "photoSync.review.pending.value")
        XCTAssertTrue(pendingValue.waitForExistence(timeout: 5))
        XCTAssertEqual(pendingValue.label, "3", "fixture 应有 3 张待同步照片")

        let previewScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        previewScreenshot.name = "photo-sync-preview"
        previewScreenshot.lifetime = .keepAlways
        add(previewScreenshot)

        sleep(1)
        start.tap()

        let imageTitle = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "IMG_9001"))
            .firstMatch
        XCTAssertTrue(
            imageTitle.waitForExistence(timeout: 20),
            "同步后网格应出现第一张照片"
        )
        let calendar = element(app, "filter.calendar")
        XCTAssertTrue(calendar.waitForExistence(timeout: 5), "新照片应进入照片日历")

        if UIDevice.current.userInterfaceIdiom == .phone {
            // 状态条成功后 3 秒自动隐藏；等它消失再操作过滤条。
            sleep(4)
            calendar.tap()
            sleep(1)
            let day = element(app, "calendar.day.2026-5-7")
            XCTAssertTrue(day.waitForExistence(timeout: 5), "日历应列出照片日期")
            day.tap()

            let clearJump = element(app, "filter.clearCalendarJump")
            XCTAssertTrue(
                clearJump.waitForExistence(timeout: 5),
                "选择日期后应出现取消入口"
            )
            let dateScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            dateScreenshot.name = "photo-sync-calendar-jump"
            dateScreenshot.lifetime = .keepAlways
            add(dateScreenshot)

            clearJump.tap()
            XCTAssertTrue(
                clearJump.waitForNonExistence(timeout: 5),
                "取消日期筛选后入口应消失"
            )
        }

        let syncAgain = element(app, "photoSync.button")
        XCTAssertTrue(syncAgain.waitForExistence(timeout: 8))
        syncAgain.tap()

        let upToDate = element(app, "photoSync.upToDate.done")
        XCTAssertTrue(
            upToDate.waitForExistence(timeout: 15),
            "第二次同步应显示已是最新"
        )
        upToDate.tap()

        let finalScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        finalScreenshot.name = "photo-sync-grid"
        finalScreenshot.lifetime = .keepAlways
        add(finalScreenshot)
    }

    func testReplaceAndUnmarkTargetFromFolder() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-photoSyncFixture",
            "-photoSyncResetTarget",
            "-debugLog",
        ]
        app.launch()

        markCurrentDirectory(app)

        let sub = app.buttons["media.Sub"]
        XCTAssertTrue(sub.waitForExistence(timeout: 10), "fixture 应包含 Sub 目录")
        sub.tap()

        XCTAssertFalse(
            element(app, "photoSync.button").exists,
            "非目标目录不应显示同步按钮"
        )

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        sleep(1)
        let mark = element(app, "photoSync.menu.mark")
        if mark.waitForExistence(timeout: 3) {
            mark.tap()
        } else {
            app.buttons["改设为照片库路径"].tap()
        }

        let replace = element(app, "photoSync.replace.confirm")
        if replace.waitForExistence(timeout: 5) {
            replace.tap()
        } else {
            app.buttons["替换"].tap()
        }

        XCTAssertTrue(
            element(app, "photoSync.button").waitForExistence(timeout: 8),
            "替换后 Sub 应成为同步目标"
        )

        app.buttons["返回上一级"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["照片库路径"].waitForExistence(timeout: 5),
            "父级网格应显示照片库路径副标题/徽标"
        )

        let subAgain = app.buttons["media.Sub"]
        XCTAssertTrue(subAgain.waitForExistence(timeout: 5))
        subAgain.tap()
        more.tap()
        sleep(1)
        let unmark = element(app, "photoSync.menu.unmark")
        XCTAssertTrue(unmark.waitForExistence(timeout: 5))
        unmark.tap()

        XCTAssertFalse(
            element(app, "photoSync.button").waitForExistence(timeout: 2),
            "取消标记后同步按钮应消失"
        )
    }

    func testStatusBarAppearsDuringUpload() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-photoSyncFixture",
            "-photoSyncResetTarget",
            "-photoSyncSlow",
            "-debugLog",
        ]
        app.launch()

        markCurrentDirectory(app)
        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 8))
        syncButton.tap()

        tapStart(app)

        let statusBar = element(app, "photoSync.statusBar")
        XCTAssertTrue(
            statusBar.waitForExistence(timeout: 10),
            "上传期间应显示顶部同步状态条"
        )
        XCTAssertTrue(
            element(app, "photoSync.statusBar.progress").exists,
            "状态条应显示数量进度"
        )
        XCTAssertTrue(
            element(app, "photoSync.statusBar.cancel").exists,
            "状态条应提供取消入口"
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "photo-sync-status-bar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFailureSummaryOffersRetry() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-photoSyncFixture",
            "-photoSyncResetTarget",
            "-photoSyncFixtureFail",
            "-debugLog",
        ]
        app.launch()

        markCurrentDirectory(app)
        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 8))
        syncButton.tap()

        tapStart(app)

        let retry = element(app, "photoSync.summary.retry")
        XCTAssertTrue(
            retry.waitForExistence(timeout: 20),
            "有失败照片时应显示汇总与重试入口"
        )
        let done = element(app, "photoSync.summary.done")
        XCTAssertTrue(done.exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "photo-sync-failure-summary"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        done.tap()
    }

    func testUnwritableTargetShowsInterruption() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-photoSyncFixture",
            "-photoSyncResetTarget",
            "-photoSyncUnwritableTarget",
            "-debugLog",
        ]
        app.launch()

        markCurrentDirectory(app)
        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 8))
        syncButton.tap()

        tapStart(app)

        let done = element(app, "photoSync.summary.done")
        XCTAssertTrue(
            done.waitForExistence(timeout: 20),
            "目标不可写时应显示中断汇总"
        )
        XCTAssertTrue(
            element(app, "photoSync.summary.retry").exists,
            "中断汇总应提供重试入口"
        )
        done.tap()
    }

    func testFavoriteFilterAndDeleteFromGallery() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-photoSyncFixture",
            "-photoSyncResetTarget",
            "-debugLog",
        ]
        app.launch()

        markCurrentDirectory(app)
        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 8))
        syncButton.tap()
        tapStart(app)

        let image = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "IMG_9001"))
            .firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 20), "同步后应出现照片")
        sleep(4)
        image.tap()

        let favorite = element(app, "gallery.favorite")
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), "全屏页应显示收藏按钮")
        favorite.tap()
        XCTAssertTrue(
            app.buttons["取消收藏"].waitForExistence(timeout: 5),
            "收藏后按钮应变为取消收藏"
        )

        let close = element(app, "gallery.close")
        XCTAssertTrue(close.exists)
        close.tap()

        let favoritesFilter = element(app, "library.favorites")
        XCTAssertTrue(favoritesFilter.waitForExistence(timeout: 10))
        favoritesFilter.tap()
        XCTAssertTrue(
            app.staticTexts["收藏夹"].waitForExistence(timeout: 10),
            "应进入收藏夹"
        )
        XCTAssertTrue(
            app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", "IMG_9001"))
                .firstMatch
                .waitForExistence(timeout: 10),
            "收藏夹应显示刚收藏的照片"
        )

        app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "IMG_9001"))
            .firstMatch
            .tap()
        let delete = element(app, "gallery.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()

        let alert = app.alerts["删除这张照片？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "删除应先确认")
        alert.buttons["删除"].tap()

        XCTAssertTrue(
            element(app, "gallery.close").waitForNonExistence(timeout: 10),
            "删除后应关闭相册"
        )
        XCTAssertTrue(
            app.staticTexts["还没有收藏照片"].waitForExistence(timeout: 10),
            "删除收藏照片后收藏夹应为空"
        )
    }

    func testZBackgroundInterruptsUploadAndShowsSummary() throws {
        // 该用例会按 Home 键把 App 切到后台，XCUITest 宿主在全套运行时
        // 偶尔会被系统重启；默认跳过，需要时用
        // `-only-testing:IceMovieUITests/PhotoSyncUITests/testZBackgroundInterruptsUploadAndShowsSummary`
        // 单独运行。
        if ProcessInfo.processInfo.environment["ICEMOVIE_RUN_BACKGROUND_UI_TEST"] != "1" {
            throw XCTSkip("切后台用例需单独运行")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-photoSyncFixture",
            "-photoSyncResetTarget",
            "-photoSyncSlow",
            "-debugLog",
        ]
        app.launch()

        markCurrentDirectory(app)
        let syncButton = element(app, "photoSync.button")
        XCTAssertTrue(syncButton.waitForExistence(timeout: 8))
        syncButton.tap()

        tapStart(app)

        let statusBar = element(app, "photoSync.statusBar")
        XCTAssertTrue(statusBar.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        sleep(2)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "photo-sync-after-background"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let done = element(app, "photoSync.summary.done")
        XCTAssertTrue(
            done.waitForExistence(timeout: 15),
            "切后台中断后回到前台应显示中断汇总"
        )
        done.tap()
    }
}
