import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class DocumentReaderModelTests: XCTestCase {
    func testSecondOpenUsesHTMLCacheWithoutReadingSMB() async throws {
        let markdown = "# 标题\n\n正文"
        let source = DocumentLoaderTestSource(data: Data(markdown.utf8))
        let entry = makeDocumentEntry("notes.md", size: Int64(markdown.utf8.count))

        let first = DocumentReaderModel(entry: entry, source: source)
        first.load()
        await waitForLoad(first)
        guard case .loaded(.markdownHTML(let firstHTML)) = first.state else {
            return XCTFail("Expected loaded markdown HTML")
        }
        XCTAssertFalse(firstHTML.isEmpty)

        let firstOpenCount = await source.openCount
        XCTAssertEqual(firstOpenCount, 1)

        let second = DocumentReaderModel(entry: entry, source: source)
        second.load()
        await waitForLoad(second)
        guard case .loaded(.markdownHTML(let secondHTML)) = second.state else {
            return XCTFail("Expected cached markdown HTML")
        }
        XCTAssertEqual(secondHTML, firstHTML)
        let secondOpenCount = await source.openCount
        XCTAssertEqual(secondOpenCount, 1, "缓存命中不应再次读取 SMB")
    }

    func testHTMLCacheKeyIncludesModifiedDate() {
        let source = DocumentLoaderTestSource(data: Data("# A".utf8))
        let entry = MediaEntry(
            path: "notes.md",
            name: "notes.md",
            isDirectory: false,
            size: 10,
            modified: Date(timeIntervalSince1970: 100)
        )
        let changed = MediaEntry(
            path: "notes.md",
            name: "notes.md",
            isDirectory: false,
            size: 10,
            modified: Date(timeIntervalSince1970: 200)
        )
        DocumentHTMLCache.shared.store("<html>A</html>", for: entry, namespace: "ns")
        XCTAssertNotNil(DocumentHTMLCache.shared.html(for: entry, namespace: "ns"))
        XCTAssertNil(DocumentHTMLCache.shared.html(for: changed, namespace: "ns"))
        XCTAssertNil(DocumentHTMLCache.shared.html(for: entry, namespace: "other"))
        _ = source
    }

    private func waitForLoad(_ model: DocumentReaderModel) async {
        for _ in 0..<100 {
            if case .loading = model.state {
                try? await Task.sleep(for: .milliseconds(20))
            } else {
                return
            }
        }
        XCTFail("文档加载超时")
    }
}
