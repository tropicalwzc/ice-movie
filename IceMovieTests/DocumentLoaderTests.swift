import MediaLibraryKit
import UIKit
import XCTest
@testable import IceMovie

final class DocumentLoaderTests: XCTestCase {
    func testReadAllAcceptsExactlyAtLimit() async throws {
        let data = Data(repeating: 0x41, count: 10)
        let read = try await DocumentLoader.readAll(
            StaticDocumentByteSource(data),
            limit: 10,
            format: .markdown
        )
        XCTAssertEqual(read, data)
    }

    func testReadAllRejectsOneByteOverLimit() async {
        let data = Data(repeating: 0x41, count: 11)
        do {
            _ = try await DocumentLoader.readAll(
                StaticDocumentByteSource(data),
                limit: 10,
                format: .markdown
            )
            XCTFail("Expected tooLarge")
        } catch let error as DocumentLoadError {
            XCTAssertEqual(error, .tooLarge(.markdown, limit: 10))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadAllStopsEarlyWhenDeclaredLengthExceedsLimit() async {
        let source = CountingDocumentByteSource(
            data: Data(repeating: 0x41, count: 10),
            declaredLength: 200
        )
        do {
            _ = try await DocumentLoader.readAll(source, limit: 100, format: .markdown)
            XCTFail("Expected tooLarge")
        } catch let error as DocumentLoadError {
            XCTAssertEqual(error, .tooLarge(.markdown, limit: 100))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let readCount = await source.readCount
        XCTAssertEqual(readCount, 0)
    }

    func testReadAllRejectsShortReadBeforeDeclaredLength() async {
        let source = CountingDocumentByteSource(
            data: Data(repeating: 0x41, count: 10),
            declaredLength: 50
        )
        do {
            _ = try await DocumentLoader.readAll(source, limit: 100, format: .markdown)
            XCTFail("Expected readFailed")
        } catch let error as DocumentLoadError {
            XCTAssertEqual(error, .readFailed("文件读取不完整（10/50 字节）"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadAllCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DocumentLoader.readAll(
                StaticDocumentByteSource(Data(repeating: 0x41, count: 100)),
                limit: 100,
                format: .markdown
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testDecodeUTF8() throws {
        let text = "Swift 面试资料"
        let data = Data(text.utf8)
        XCTAssertEqual(try DocumentLoader.decodeMarkdown(data), text)
    }

    func testDecodeGB18030() throws {
        let text = "中文文档"
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let encoding = String.Encoding(rawValue: gbRaw)
        let data = try XCTUnwrap(text.data(using: encoding))
        XCTAssertEqual(try DocumentLoader.decodeMarkdown(data), text)
    }

    func testDecodeRandomBinaryFails() {
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try DocumentLoader.decodeMarkdown(data)) { error in
            XCTAssertEqual(error as? DocumentLoadError, .decodeFailed)
        }
    }

    func testLoadMarkdownSuccessClosesByteSource() async throws {
        let markdown = "# 标题\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        let data = Data(markdown.utf8)
        let source = DocumentLoaderTestSource(data: data)
        let loader = DocumentLoader(source: source)
        let entry = makeDocumentEntry("notes.md", size: Int64(data.count))

        let loaded = try await loader.load(entry)
        guard case .markdown(let text) = loaded.content else {
            return XCTFail("Expected markdown content")
        }
        XCTAssertEqual(text, markdown)
        XCTAssertEqual(loaded.byteCount, Int64(data.count))
        let closeCount = await source.byteSource.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testLoadRejectsTooLargeBeforeOpening() async {
        let source = DocumentLoaderTestSource(data: Data())
        let loader = DocumentLoader(source: source)
        let entry = makeDocumentEntry("huge.md", size: 5 * 1024 * 1024 + 1)

        do {
            _ = try await loader.load(entry)
            XCTFail("Expected tooLarge")
        } catch let error as DocumentLoadError {
            XCTAssertEqual(error, .tooLarge(.markdown, limit: 5 * 1024 * 1024))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let openCount = await source.openCount
        XCTAssertEqual(openCount, 0)
    }

    func testLoadReadFailureClosesByteSource() async {
        struct TestError: Error {}
        let source = DocumentLoaderTestSource(data: Data(), readError: TestError())
        let loader = DocumentLoader(source: source)
        let entry = makeDocumentEntry("notes.md", size: 10)

        do {
            _ = try await loader.load(entry)
            XCTFail("Expected readFailed")
        } catch let error as DocumentLoadError {
            if case .readFailed = error {
                // expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let closeCount = await source.byteSource.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testLoadPDFSuccess() async throws {
        let data = makePDFData()
        let source = DocumentLoaderTestSource(data: data)
        let loader = DocumentLoader(source: source)
        let entry = makeDocumentEntry("sample.pdf", size: Int64(data.count))

        let loaded = try await loader.load(entry)
        guard case .pdf(let box) = loaded.content else {
            return XCTFail("Expected pdf content")
        }
        XCTAssertEqual(box.document.pageCount, 1)
        XCTAssertEqual(loaded.byteCount, Int64(data.count))
    }

    func testLoadInvalidPDF() async {
        let source = DocumentLoaderTestSource(data: Data("not a pdf".utf8))
        let loader = DocumentLoader(source: source)
        let entry = makeDocumentEntry("broken.pdf", size: 9)

        do {
            _ = try await loader.load(entry)
            XCTFail("Expected invalidPDF")
        } catch let error as DocumentLoadError {
            XCTAssertEqual(error, .invalidPDF)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makePDFData() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            context.beginPage()
            "Hello".draw(
                at: CGPoint(x: 20, y: 20),
                withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
            )
        }
    }
}
