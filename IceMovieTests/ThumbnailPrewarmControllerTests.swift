import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class ThumbnailPrewarmControllerTests: XCTestCase {
    func testBackgroundPrewarmIsDeclaredInInfoPlist() {
        let identifiers = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String]
        XCTAssertTrue(
            identifiers?.contains(ThumbnailPrewarmBackground.identifier) == true,
            "BGTaskSchedulerPermittedIdentifiers 应包含预热任务"
        )
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(modes?.contains("processing") == true)
    }

    func testProcessesAllEntriesAndFinishes() async {
        var seen: [String] = []
        let entries = [entry("A"), entry("B"), entry("C")]
        let controller = ThumbnailPrewarmController(entries: entries) { entry in
            seen.append(entry.name)
            return true
        }

        controller.start()
        for _ in 0..<100 where !controller.isFinished {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(controller.isFinished)
        XCTAssertEqual(controller.completed, 3)
        XCTAssertEqual(controller.progress, 1)
        XCTAssertEqual(seen, ["A", "B", "C"])
        XCTAssertFalse(controller.isActive)
    }

    func testPauseAndResume() async {
        var generated = 0
        let entries = (0..<6).map { entry("P\($0)") }
        let controller = ThumbnailPrewarmController(entries: entries) { _ in
            generated += 1
            try? await Task.sleep(for: .milliseconds(40))
            return true
        }

        controller.start()
        try? await Task.sleep(for: .milliseconds(50))
        controller.pause()
        let pausedAt = generated
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThanOrEqual(generated, pausedAt + 1, "暂停后不应继续大批生成")
        XCTAssertTrue(controller.isPaused)

        controller.resume()
        for _ in 0..<100 where !controller.isFinished {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.isFinished)
        XCTAssertEqual(controller.completed, entries.count)
    }

    func testPrioritizeMovesVisibleEntriesToFront() async {
        var seen: [String] = []
        let entries = [entry("A"), entry("B"), entry("C")]
        let controller = ThumbnailPrewarmController(entries: entries) { entry in
            seen.append(entry.name)
            return true
        }
        controller.prioritize(["C"])
        controller.start()
        for _ in 0..<100 where !controller.isFinished {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(seen, ["C", "A", "B"])
    }

    func testCancelStopsRemainingWork() async {
        let entries = (0..<20).map { entry("X\($0)") }
        let controller = ThumbnailPrewarmController(entries: entries) { _ in
            try? await Task.sleep(for: .milliseconds(30))
            return true
        }
        controller.start()
        try? await Task.sleep(for: .milliseconds(50))
        controller.cancel()
        let completedAtCancel = controller.completed

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThanOrEqual(
            controller.completed,
            completedAtCancel + 1,
            "取消后最多让当前一张完成"
        )
        XCTAssertTrue(controller.isFinished)
        XCTAssertFalse(controller.isActive)
    }

    private func entry(_ name: String) -> MediaEntry {
        MediaEntry(
            path: name,
            name: name,
            isDirectory: false,
            size: 1,
            modified: nil
        )
    }
}
