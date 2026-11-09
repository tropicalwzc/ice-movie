import MediaLibraryKit
import XCTest
@testable import IceMovie

/// 字幕脚本缓存必须按数据源隔离，切换共享或本地根目录后不能串用。
final class SubtitleScriptCacheTests: XCTestCase {
    func testNamespacePreventsCrossSourceHit() throws {
        let entry = MediaEntry(
            path: "cache-test-\(UUID().uuidString).mkv",
            name: "cache-test.mkv",
            isDirectory: false,
            size: 1,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let script = "[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,同一路径"
        SubtitleScriptCache.save(
            script,
            entry: entry,
            streamIndex: 1,
            namespace: "host|share-a"
        )

        XCTAssertEqual(
            SubtitleScriptCache.load(entry: entry, streamIndex: 1, namespace: "host|share-a"),
            script
        )
        XCTAssertNil(
            SubtitleScriptCache.load(entry: entry, streamIndex: 1, namespace: "host|share-b"),
            "切换共享后不能命中另一数据源的缓存"
        )
        XCTAssertNil(
            SubtitleScriptCache.load(entry: entry, streamIndex: 2, namespace: "host|share-a"),
            "不同字幕流不能共用缓存"
        )
    }
}
