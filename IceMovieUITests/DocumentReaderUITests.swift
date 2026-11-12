import XCTest

@MainActor
final class DocumentReaderUITests: XCTestCase {
    private func element(
        _ app: XCUIApplication,
        _ identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    func testMarkdownReaderTOCAndScrolling() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/icemovie-docs",
            "-libraryPath", "面试知识库",
            "-debugLog",
        ]
        app.launch()

        let document = element(app, "document.row.AI-Agent编码实践-2026-10-29.md")
        XCTAssertTrue(document.waitForExistence(timeout: 15), "应列出 Markdown 文档")
        document.tap()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15), "应打开 Markdown WebView")

        let toc = element(app, "document.toc")
        XCTAssertTrue(toc.waitForExistence(timeout: 10), "有标题的文档应显示目录按钮")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "markdown-reader-top"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        for _ in 0..<12 {
            webView.swipeUp()
        }
        XCTAssertTrue(webView.exists, "滚动到底部后 WebView 应仍然存在")

        let bottomScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        bottomScreenshot.name = "markdown-reader-scrolled"
        bottomScreenshot.lifetime = .keepAlways
        add(bottomScreenshot)

        toc.tap()
        let tocNavigation = app.navigationBars["目录"]
        XCTAssertTrue(tocNavigation.waitForExistence(timeout: 5), "应打开目录 sheet")
        let firstHeading = app.buttons["〇、一页速览"]
        XCTAssertTrue(firstHeading.waitForExistence(timeout: 5), "应列出文档标题")
        firstHeading.tap()
    }

    func testSearchFindsMarkdownAndPDFAndOpensReader() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/icemovie-docs",
            "-libraryPath", "面试知识库",
            "-debugLog",
        ]
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "应显示搜索框")
        search.tap()
        search.typeText("swift")

        let markdown = element(app, "search.document.swift.md")
        let pdf = element(app, "search.document.swift.pdf")
        XCTAssertTrue(markdown.waitForExistence(timeout: 10), "搜索结果应包含 swift.md")
        XCTAssertTrue(pdf.waitForExistence(timeout: 10), "搜索结果应包含 swift.pdf")

        markdown.tap()
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 15),
            "点击文档搜索结果应直接打开阅读器"
        )
    }

    func testBrokenPDFShowsFailureAndRetry() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/icemovie-docs",
            "-libraryPath", "broken",
            "-debugLog",
        ]
        app.launch()

        let document = element(app, "document.row.broken.pdf")
        XCTAssertTrue(document.waitForExistence(timeout: 15), "应列出损坏 PDF")
        document.tap()

        XCTAssertTrue(
            app.staticTexts["无法打开文档"].waitForExistence(timeout: 15),
            "损坏 PDF 应显示失败态"
        )
        XCTAssertTrue(app.buttons["重试"].exists, "失败态应提供重试")
    }

    func testEmptyDirectoryShowsNoContentState() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/icemovie-docs",
            "-libraryPath", "empty",
            "-debugLog",
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["这里还没有可浏览的内容"].waitForExistence(timeout: 15),
            "空目录应显示明确的空状态"
        )
    }

    func testOpenDocumentWhilePlayingKeepsPlayback() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/icemovie-docs",
            "-libraryPath", "playback",
            "-resetPlaybackProgress",
            "-libraryInlinePlayback",
            "-debugLog",
        ]
        app.launch()

        let video = app.buttons["Episode 01.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 15), "应列出视频")
        video.tap()

        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 60), "视频应开始播放")
        XCTAssertTrue(
            app.buttons["全屏"].waitForExistence(timeout: 10),
            "诊断参数应让视频以内联方式播放"
        )

        let time = app.staticTexts["player.time"]
        _ = time.waitForExistence(timeout: 2)
        let before = time.exists ? time.label : ""

        let document = element(app, "document.row.notes.md")
        for _ in 0..<8 where !document.exists {
            app.swipeUp()
        }
        XCTAssertTrue(document.waitForExistence(timeout: 8), "应能看到文档行")
        document.tap()
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 15),
            "应打开文档阅读器"
        )

        sleep(3)
        if !pause.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.15)).tap()
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "打开文档后视频应仍在播放")
        if time.exists, !before.isEmpty {
            XCTAssertNotEqual(time.label, before, "打开文档后视频进度应继续推进")
        }
    }

    func testPDFReaderPageNavigation() {        let app = XCUIApplication()
        app.launchArguments = [
            "-libraryLocal", "/private/tmp/icemovie-docs",
            "-libraryPath", "pdfonly",
            "-debugLog",
        ]
        app.launch()

        let document = element(app, "document.row.swift.pdf")
        XCTAssertTrue(document.waitForExistence(timeout: 15), "应列出 PDF 文档")
        document.tap()

        let indicator = element(app, "document.pageIndicator")
        XCTAssertTrue(indicator.waitForExistence(timeout: 15), "应显示页码")
        XCTAssertTrue(indicator.label.contains("1 / 11"), "应从第 1 页开始")

        let pages = element(app, "document.pages")
        XCTAssertTrue(pages.waitForExistence(timeout: 5), "应显示页面缩略图入口")
        pages.tap()

        let page10 = element(app, "document.page.10")
        XCTAssertTrue(page10.waitForExistence(timeout: 10), "应显示第 10 页缩略图")
        page10.tap()

        let updated = element(app, "document.pageIndicator")
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
        XCTAssertTrue(updated.label.contains("10 / 11"), "应跳转到第 10 页")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "pdf-reader-page-10"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
