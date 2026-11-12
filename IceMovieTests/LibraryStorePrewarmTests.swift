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

        await store.loadCurrent()
        try await waitForSidecarEntries(sidecar, expected: ["A.jpg", "B.jpg"])

        await source.setEntries([first, third])
        await store.loadCurrent(force: true)
        try await waitForSidecarEntries(sidecar, expected: ["A.jpg", "C.jpg"])

        let entries = await sidecar.entries()
        XCTAssertNotNil(entries["A.jpg"])
        XCTAssertNotNil(entries["C.jpg"])
        XCTAssertNil(entries["B.jpg"], "删除的文件应从侧车索引清理")
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
    nonisolated let shareName = "prewarm-share"
    nonisolated let thumbnailSidecar: (any ThumbnailSidecarProviding)?
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
    }

    func setEntries(_ entries: [MediaEntry]) {
        self.entries = entries
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
