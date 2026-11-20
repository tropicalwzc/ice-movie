import Foundation
import IceCore
import MediaLibraryKit
import ThumbnailKit
import XCTest
@testable import IceMovie

@MainActor
final class LibraryStorePrewarmTests: XCTestCase {
    func testPrewarmWritesSidecarAndRemovesDeletedEntries() async throws {
        let sidecarRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStorePrewarm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sidecarRoot) }

        let imageURL = try fixtureURL()
        let first = entry("A.jpg", size: 10)
        let second = entry("B.jpg", size: 20)
        let third = entry("C.jpg", size: 30)
        let source = PrewarmStubSource(
            entries: [first, second],
            imageURL: imageURL,
            sidecarProvider: LocalThumbnailSidecar(rootURL: sidecarRoot)
        )
        let store = try LibraryStore(
            source: source,
            initialPath: "",
            cacheCapacityBytes: 4 * 1024 * 1024
        )
        let sidecar = try XCTUnwrap(store.thumbnailSidecarCache)
        // 子目录里已有的有效封面不能在进入根目录时被前缀清理误删。
        await sidecar.store(
            thumbnailData: Data([1, 2, 3]),
            width: 10,
            height: 10,
            path: "Sub/Keep.jpg",
            size: 5,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await sidecar.flush()

        await store.loadCurrent()
        try await waitForSidecarEntries(
            sidecar,
            expected: ["A.jpg", "B.jpg", "Sub/Keep.jpg"]
        )

        await source.setEntries([first, third])
        await store.loadCurrent(force: true)
        try await waitForSidecarEntries(
            sidecar,
            expected: ["A.jpg", "C.jpg", "Sub/Keep.jpg"]
        )

        let entries = await sidecar.entries()
        XCTAssertNotNil(entries["A.jpg"])
        XCTAssertNotNil(entries["C.jpg"])
        XCTAssertNotNil(entries["Sub/Keep.jpg"], "子目录条目不能被根目录清理误删")
        XCTAssertNil(entries["B.jpg"], "删除的文件应从侧车索引清理")
    }

    func testSwitchShareRebuildsSidecarCacheForNewShare() async throws {
        let sidecarRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreSwitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sidecarRoot) }

        let router = ShareRoutingSidecar(rootURL: sidecarRoot, share: "prewarm-share")
        let source = PrewarmStubSource(
            entries: [entry("A.jpg", size: 10)],
            imageURL: try fixtureURL(),
            sidecarProvider: router
        )
        let store = try LibraryStore(
            source: source,
            cacheCapacityBytes: 4 * 1024 * 1024
        )
        let old = try XCTUnwrap(store.thumbnailSidecarCache)
        await store.loadCurrent()
        try await waitForSidecarEntries(old, expected: ["A.jpg"])

        // 新共享放不同文件；如果旧缓存/索引被带过去，B 的索引会混入 A。
        await source.setEntries([entry("B.jpg", size: 20)])
        let switched = await store.switchShare("other-share")
        XCTAssertTrue(switched)
        let new = try XCTUnwrap(store.thumbnailSidecarCache)
        XCTAssertFalse(old === new, "切换共享后必须重建侧车实例，不能沿用旧共享索引")
        let oldWritable = await old.isWritable
        XCTAssertFalse(oldWritable, "旧侧车实例必须停用，避免把旧索引写到新共享")

        await store.loadCurrent(force: true)
        try await waitForSidecarEntries(new, expected: ["B.jpg"])

        let firstIndex = try decodeIndex(
            sidecarRoot.appendingPathComponent("prewarm-share/.icemovie/index.json")
        )
        let secondIndex = try decodeIndex(
            sidecarRoot.appendingPathComponent("other-share/.icemovie/index.json")
        )
        XCTAssertEqual(Set(firstIndex.entries.keys), ["A.jpg"])
        XCTAssertEqual(Set(secondIndex.entries.keys), ["B.jpg"], "新共享不能继承旧共享索引")
    }

    private func decodeIndex(_ url: URL) throws -> SharedThumbnailIndex {
        try JSONDecoder().decode(SharedThumbnailIndex.self, from: Data(contentsOf: url))
    }

    private func waitForSidecarEntries(
        _ sidecar: SharedThumbnailCache,
        expected: Set<String>
    ) async throws {
        for _ in 0..<200 {
            let entries = await sidecar.entries()
            if Set(entries.keys) == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let entries = await sidecar.entries()
        XCTFail("侧车条目未达到 \(expected)，实际 \(Set(entries.keys))")
    }

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: LibraryStorePrewarmTests.self)
        if let url = bundle.url(
            forResource: "sample",
            withExtension: "jpg",
            subdirectory: "ImageGallery"
        ) {
            return url
        }
        guard let url = bundle.url(forResource: "sample", withExtension: "jpg") else {
            throw NSError(domain: "LibraryStorePrewarmTests", code: 1)
        }
        return url
    }

    private func entry(_ name: String, size: Int64) -> MediaEntry {
        MediaEntry(
            path: name,
            name: name,
            isDirectory: false,
            size: size,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private actor PrewarmStubSource: LibrarySource {
    nonisolated let hostName = "prewarm-host"
    nonisolated(unsafe) private var shareNameValue = "prewarm-share"
    nonisolated var shareName: String { shareNameValue }
    nonisolated let thumbnailSidecar: (any ThumbnailSidecarProviding)?
    private let sidecarRouter: ShareRoutingSidecar?
    private var entries: [MediaEntry]
    private let imageURL: URL

    init(
        entries: [MediaEntry],
        imageURL: URL,
        sidecarProvider: any ThumbnailSidecarProviding
    ) {
        self.entries = entries
        self.imageURL = imageURL
        self.thumbnailSidecar = sidecarProvider
        self.sidecarRouter = sidecarProvider as? ShareRoutingSidecar
    }

    func setEntries(_ entries: [MediaEntry]) {
        self.entries = entries
    }

    func availableShares() async throws -> [String] {
        ["prewarm-share", "other-share"]
    }

    func changeShare(_ share: String) async throws {
        shareNameValue = share
        await sidecarRouter?.setShare(share)
    }

    func listDirectory(path: String) async throws -> [MediaEntry] { entries }
    func listAllEntries(path: String) async throws -> [MediaEntry] { entries }

    func openByteSource(path: String) async throws -> any ByteSource {
        try LocalFileByteSource(url: imageURL)
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        try LocalFileByteSource(url: imageURL)
    }
}

/// 测试用：把同一套侧车协议路由到“当前共享”的独立目录，模拟 SMB 共享切换。
private actor ShareRoutingSidecar: ThumbnailSidecarProviding {
    private let rootURL: URL
    private var share: String
    private var providers: [String: LocalThumbnailSidecar] = [:]

    init(rootURL: URL, share: String) {
        self.rootURL = rootURL
        self.share = share
    }

    func setShare(_ share: String) {
        self.share = share
    }

    private func provider() -> LocalThumbnailSidecar {
        if let existing = providers[share] { return existing }
        let provider = LocalThumbnailSidecar(
            rootURL: rootURL.appendingPathComponent(share, isDirectory: true)
        )
        providers[share] = provider
        return provider
    }

    func prepare() async throws {
        try await provider().prepare()
    }

    func loadIndex() async throws -> Data? {
        try await provider().loadIndex()
    }

    func storeIndex(_ data: Data) async throws {
        try await provider().storeIndex(data)
    }

    func loadThumbnail(relativePath: String) async throws -> Data? {
        try await provider().loadThumbnail(relativePath: relativePath)
    }

    func storeThumbnail(_ data: Data, relativePath: String) async throws {
        try await provider().storeThumbnail(data, relativePath: relativePath)
    }

    func removeThumbnail(relativePath: String) async throws {
        try await provider().removeThumbnail(relativePath: relativePath)
    }

    func removeAll() async throws {
        try await provider().removeAll()
    }
}
