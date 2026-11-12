import XCTest
@testable import IceMovie

final class MarkdownHTMLTemplateTests: XCTestCase {
    func testBundledAssetsAreAvailable() {
        XCTAssertTrue(MarkdownHTMLTemplate.hasBundledAssets)
    }

    func testTemplateEmbedsMarkdownAndRendererFeatures() {
        let markdown = """
        # 标题

        | A | B |
        |---|---|
        | 1 | 2 |

        ```swift
        let value = 1
        ```
        """
        let html = MarkdownHTMLTemplate.make(markdown: markdown)

        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("DOMPurify"))
        XCTAssertTrue(html.contains("hljs"))
        XCTAssertTrue(html.contains("table-wrap"))
        XCTAssertTrue(html.contains("document-heading-"))
        XCTAssertTrue(html.contains("copy-code"))
        XCTAssertFalse(html.contains(markdown))
        XCTAssertTrue(html.contains(Data(markdown.utf8).base64EncodedString()))
    }

    func testScriptClosingTagCannotBreakOutOfTemplate() {
        let markdown = "正文 </script><script>alert(1)</script>"
        let html = MarkdownHTMLTemplate.make(markdown: markdown)
        XCTAssertFalse(html.contains("正文 </script>"))
        XCTAssertTrue(html.contains(Data(markdown.utf8).base64EncodedString()))
    }
}
