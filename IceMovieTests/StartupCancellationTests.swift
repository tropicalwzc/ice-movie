import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

private struct SlowLibrarySource: LibrarySource {
    let hostName = "slow"
    let shareName = "share"

    func listDirectory(path: String) async throws -> [MediaEntry] { [] }
    func listAllEntries(path: String) async throws -> [MediaEntry] { [] }

    func openByteSource(path: String) async throws -> any ByteSource {
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
    }
}

final class StartupCancellationTests: XCTestCase {
    @MainActor
    func testPreparePlaybackCancellationReturnsNil() async throws {
        let store = try LibraryStore(
            source: SlowLibrarySource(),
            initialPath: "",
            cacheCapacityBytes: 1024 * 1024
        )
        let entry = MediaEntry(
            path: "episode.mkv",
            name: "episode.mkv",
            isDirectory: false,
            size: 1024,
            modified: nil
        )

        let task = Task { await store.preparePlayback(entry) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        let prepared = await task.value

        XCTAssertNil(prepared)
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(store.preparingPlaybackID, "取消后应清理加载态")
    }
}
