import XCTest
@testable import RenderKit

/// `-playbackRate` 必须统一钳制到音频与主时钟都支持的区间。
final class PlaybackRateTests: XCTestCase {
    func testRateIsClampedToSharedRange() {
        XCTAssertEqual(PlaybackEngine.clampedRate(0.1), 0.5)
        XCTAssertEqual(PlaybackEngine.clampedRate(0.5), 0.5)
        XCTAssertEqual(PlaybackEngine.clampedRate(1.25), 1.25)
        XCTAssertEqual(PlaybackEngine.clampedRate(2.0), 2.0)
        XCTAssertEqual(PlaybackEngine.clampedRate(3.0), 2.0)
    }
}
