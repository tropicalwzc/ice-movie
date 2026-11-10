import MediaLibraryKit
import XCTest
@testable import IceMovie
@testable import RenderKit

final class StartupPolicyTests: XCTestCase {
    func testFastModeWhenThroughputIsComfortable() {
        XCTAssertEqual(
            PlaybackEngine.startupPrerollMode(
                measuredBytesPerSecond: 20 * 1024 * 1024,
                bitrateBytesPerSecond: 2 * 1024 * 1024
            ),
            "fast"
        )
    }

    func testConservativeModeWhenThroughputIsBelowOneAndHalfBitrate() {
        XCTAssertEqual(
            PlaybackEngine.startupPrerollMode(
                measuredBytesPerSecond: 2 * 1024 * 1024,
                bitrateBytesPerSecond: 2 * 1024 * 1024
            ),
            "conservative"
        )
    }

    func testFastModeWithoutMeasuredSpeed() {
        XCTAssertEqual(
            PlaybackEngine.startupPrerollMode(
                measuredBytesPerSecond: 0,
                bitrateBytesPerSecond: 2 * 1024 * 1024
            ),
            "fast"
        )
    }

    func testPrerollThresholdsForBothModes() {
        let fast = PlaybackEngine.startupPreroll(mode: "fast")
        XCTAssertEqual(fast.audio, 0.3, accuracy: 0.001)
        XCTAssertEqual(fast.video, 0.05, accuracy: 0.001)

        let conservative = PlaybackEngine.startupPreroll(mode: "conservative")
        XCTAssertEqual(conservative.audio, 2.0, accuracy: 0.001)
        XCTAssertEqual(conservative.video, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testPendingPlaybackMeasuresPresentation() {
        let entry = MediaEntry(
            path: "show/episode.mkv",
            name: "episode.mkv",
            isDirectory: false,
            size: 1024,
            modified: nil
        )
        let pending = PendingPlayback(
            entry: entry,
            label: "episode",
            poster: nil,
            requestedAt: 100
        )
        pending.presentedAt = 100.2
        XCTAssertEqual(pending.presentedMilliseconds, 200)
    }
}
