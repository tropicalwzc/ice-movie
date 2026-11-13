import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import ThumbnailKit
import ImageKit
import XCTest
@testable import IceMovie

@MainActor
final class LibraryStoreFolderCoverTests: XCTestCase {
    func testFolderCoverUsesDirectVideo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try copyFixtureVideo(named: "E01.mov", to: root.appendingPathComponent("Show/E01.mov"))

        let store = try LibraryStore(source: LocalLibrarySource(rootURL: root))
        let cover = await store.folderCover(for: directory("Show"))

        XCTAssertNotNil(cover, "直接包含视频的目录应生成封面")
    }

    func testFolderCoverScansShallowSubdirectoryWhenNoDirectVideo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try copyFixtureVideo(
            named: "E01.mov",
            to: root.appendingPathComponent("Show/Season 1/E01.mov")
        )

        let store = try LibraryStore(source: LocalLibrarySource(rootURL: root))
        let cover = await store.folderCover(for: directory("Show"))

        XCTAssertNotNil(cover, "没有直接视频时应向下扫描一层子目录")
    }

    func testFolderWithoutVideoHasNoCover() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let store = try LibraryStore(source: LocalLibrarySource(rootURL: root))
        let cover = await store.folderCover(for: directory("Empty"))

        XCTAssertNil(cover, "没有视频的目录应回退文件夹图标")
    }

    func testFolderCoverCacheKeyChangesWithVideoIdentity() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(
            source: LocalLibrarySource(rootURL: root),
            cacheCapacityBytes: 1024 * 1024
        )
        let first = MediaEntry(
            path: "Show/E01.mov",
            name: "E01.mov",
            isDirectory: false,
            size: 100,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = MediaEntry(
            path: "Show/E01.mov",
            name: "E01.mov",
            isDirectory: false,
            size: 100,
            modified: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertNotEqual(
            store.folderCoverCacheKey(folderPath: "Show", video: first),
            store.folderCoverCacheKey(folderPath: "Show", video: second)
        )
    }

    func testBrokenVideoFallsBackToNoCover() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("Broken/E01.mov")
        try FileManager.default.createDirectory(
            at: broken.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a video".utf8).write(to: broken)

        let store = try LibraryStore(source: LocalLibrarySource(rootURL: root))
        let cover = await store.folderCover(for: directory("Broken"))

        XCTAssertNil(cover, "候选视频全部抽帧失败时应回退文件夹图标")
    }

    func testPersistedSelectionSkipsDirectoryEnumerationOnCacheHit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try copyFixtureVideo(named: "E01.mov", to: root.appendingPathComponent("Show/E01.mov"))

        let firstSource = CountingFolderCoverSource(base: LocalLibrarySource(rootURL: root))
        let firstStore = try LibraryStore(source: firstSource)
        let firstCover = await firstStore.folderCover(for: directory("Show"))
        XCTAssertNotNil(firstCover)
        // 等待选择文件落盘（500ms 防抖）。
        try await Task.sleep(for: .milliseconds(900))

        let secondSource = CountingFolderCoverSource(base: LocalLibrarySource(rootURL: root))
        let secondStore = try LibraryStore(source: secondSource)
        let before = await secondSource.listCallCount
        let secondCover = await secondStore.folderCover(for: directory("Show"))
        let after = await secondSource.listCallCount

        XCTAssertNotNil(secondCover, "第二次启动应命中持久化选择 + 本地封面")
        XCTAssertEqual(after, before, "命中缓存时不得再枚举 SMB 目录")
    }

    func testMiddleFrameThumbnailGenerates() throws {
        let url = try fixtureURL("motion.mov")
        let image = try DemuxProbe.thumbnail(
            path: url.path,
            maxWidth: 192,
            positionFraction: 0.5
        )

        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        XCTAssertFalse(image.data.isEmpty)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(image.data as CFData, nil)
        )
        XCTAssertNotNil(
            CGImageSourceCreateImageAtIndex(source, 0, nil),
            "抽帧 PNG 必须能被 ImageIO 完整解码"
        )
        let jpeg = try XCTUnwrap(ImageDecoder.encodeJPEG(image.data))
        let jpegSource = try XCTUnwrap(
            CGImageSourceCreateWithData(jpeg as CFData, nil)
        )
        XCTAssertNotNil(
            CGImageSourceCreateImageAtIndex(jpegSource, 0, nil),
            "侧车 JPEG 必须能被 ImageIO 完整解码"
        )
    }

    private func directory(_ path: String) -> MediaEntry {
        MediaEntry(
            path: path,
            name: (path as NSString).lastPathComponent,
            isDirectory: true,
            size: 0,
            modified: nil
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderCover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func copyFixtureVideo(named name: String, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: try fixtureURL("motion.mov"), to: destination)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let pathExtension = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        if let url = bundle.url(
            forResource: base,
            withExtension: pathExtension,
            subdirectory: "ImageGallery"
        ) {
            return url
        }
        if let url = bundle.url(forResource: base, withExtension: pathExtension) {
            return url
        }
        throw XCTSkip("缺少测试 fixture：\(name)")
    }
}

/// 统计目录枚举次数，验证持久化选择命中后不再访问 SMB 目录。
private actor CountingFolderCoverSource: LibrarySource {
    private let base: LocalLibrarySource
    private(set) var listCallCount = 0

    nonisolated var hostName: String { base.hostName }
    nonisolated var shareName: String { base.shareName }
    nonisolated var cacheNamespace: String { base.cacheNamespace }
    nonisolated var thumbnailSidecar: (any ThumbnailSidecarProviding)? {
        base.thumbnailSidecar
    }

    init(base: LocalLibrarySource) {
        self.base = base
    }

    func listDirectory(path: String) async throws -> [MediaEntry] {
        listCallCount += 1
        return try await base.listDirectory(path: path)
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        try await base.listAllEntries(path: path)
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        try await base.openByteSource(path: path)
    }
}
