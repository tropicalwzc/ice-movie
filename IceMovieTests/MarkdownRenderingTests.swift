import XCTest
@testable import IceMovie

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    func testTablesCodeHighlightTOCAndScroll() async throws {
        let markdown = """
        # 标题

        | 列 A | 列 B |
        |---|---|
        | 1 | 2 |

        ```swift
        let value = 1
        print(value)
        ```

        ## 第二节

        正文
        """
        let result = try await MarkdownDOMProbe().snapshot(
            html: MarkdownHTMLTemplate.make(markdown: markdown)
        )

        XCTAssertEqual(result.tables, 1)
        XCTAssertEqual(result.codeBlocks, 1)
        XCTAssertEqual(result.highlighted, 1)
        XCTAssertEqual(result.headings, 2)
        XCTAssertGreaterThan(result.documentHeight, 100)
        XCTAssertTrue(result.reachedBottom, "应能滚动到文档底部")
    }

    func testScriptAndEventAttributesAreRemoved() async throws {
        let markdown = """
        # 安全

        <script>window.__pwned = 1;</script>
        <img src="https://example.com/tracker.png" onerror="window.__pwned = 2;">
        <a href="javascript:window.__pwned = 3">危险链接</a>
        """
        let result = try await MarkdownDOMProbe().snapshot(
            html: MarkdownHTMLTemplate.make(markdown: markdown)
        )

        XCTAssertFalse(result.pwned)
        XCTAssertEqual(result.inlineScripts, 0)
        XCTAssertEqual(result.eventAttributes, 0)
        XCTAssertEqual(result.remoteResources, 0)
    }
}
