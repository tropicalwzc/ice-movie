import Foundation
import XCTest
@testable import IceMovie

final class LocalLibrarySourceCreateFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-sync-local-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Photos", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func testCreateFileWritesAndRejectsExistingTarget() async throws {
        let source = LocalLibrarySource(rootURL: root)
        let path = "Photos/IMG_0001_20260505222609.jpg"
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let modified = Date(timeIntervalSince1970: 1_700_000_000)

        try await source.createFile(
            path: path,
            data: data,
            modified: modified,
            onProgress: { _ in true }
        )

        let url = root.appending(path: path)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualModified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(
            actualModified.timeIntervalSince1970,
            modified.timeIntervalSince1970,
            accuracy: 1
        )

        do {
            try await source.createFile(
                path: path,
                data: Data([0x09]),
                modified: nil,
                onProgress: { _ in true }
            )
            XCTFail("已存在的目标必须拒绝覆盖")
        } catch LibrarySourceError.fileExists {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: url), data, "原文件不得被修改")
    }

    func testCancelCleansTemporaryFile() async throws {
        let source = LocalLibrarySource(rootURL: root)
        let path = "Photos/IMG_0002_20260505222609.jpg"

        do {
            try await source.createFile(
                path: path,
                data: Data(repeating: 0x7F, count: 1024),
                modified: nil,
                onProgress: { _ in false }
            )
            XCTFail("取消必须抛错")
        } catch is CancellationError {
            // expected
        }

        let directory = root.appendingPathComponent("Photos", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.isEmpty, "取消后不应留下临时文件或最终文件")
    }

    func testMissingTargetDirectoryFails() async throws {
        let source = LocalLibrarySource(rootURL: root)
        do {
            try await source.createFile(
                path: "Missing/IMG_0003_20260505222609.jpg",
                data: Data([0x01]),
                modified: nil,
                onProgress: { _ in true }
            )
            XCTFail("目标目录不存在应失败")
        } catch LibrarySourceError.writeFailed {
            // expected
        }
    }

    func testProgressReportsTotalBytes() async throws {
        let source = LocalLibrarySource(rootURL: root)
        let recorder = ProgressRecorder()
        let data = Data(repeating: 0x11, count: 4096)

        try await source.createFile(
            path: "Photos/IMG_0004_20260505222609.jpg",
            data: data,
            modified: nil,
            onProgress: { bytes in
                recorder.record(bytes)
                return true
            }
        )

        XCTAssertEqual(recorder.values.last, Int64(data.count))
    }

    func testDeleteFileRemovesFile() async throws {
        let source = LocalLibrarySource(rootURL: root)
        let path = "Photos/IMG_0005_20260505222609.jpg"
        let url = root.appending(path: path)
        try await source.createFile(
            path: path,
            data: Data([0x01]),
            modified: nil,
            onProgress: { _ in true }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try await source.deleteFile(path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        do {
            try await source.deleteFile(path: path)
            XCTFail("删除不存在的文件应失败")
        } catch {
            // expected
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: Int64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
