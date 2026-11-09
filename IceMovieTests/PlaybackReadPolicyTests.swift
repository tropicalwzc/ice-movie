import XCTest
@testable import RenderKit

/// 预读水位回归：音频和视频都要补到 15 秒高水位才停止读包，避免网络抖动直接进入“缓冲中”。
final class PlaybackReadPolicyTests: XCTestCase {
    func testAudioStarvationOverridesVideoBackpressure() {
        XCTAssertFalse(
            PlaybackEngine.isReadAheadEnough(audioAhead: 0.05, videoAhead: 15.1),
            "音频接近欠载时不能因为视频领先而停止读包，否则缓冲永远无法恢复"
        )
    }

    func testAudioBelowTargetKeepsReading() {
        XCTAssertFalse(PlaybackEngine.isReadAheadEnough(audioAhead: 0.6, videoAhead: 15.1))
        XCTAssertFalse(PlaybackEngine.isReadAheadEnough(audioAhead: 14.9, videoAhead: 15.1))
    }

    func testVideoBelowTargetKeepsReadingEvenWhenAudioHealthy() {
        XCTAssertFalse(
            PlaybackEngine.isReadAheadEnough(audioAhead: 15.2, videoAhead: 2.0),
            "音频已够但视频不足时仍要继续读，提前把视频缓冲垫高"
        )
    }

    func testBothBuffersHealthyStopsReading() {
        XCTAssertTrue(PlaybackEngine.isReadAheadEnough(audioAhead: 15.2, videoAhead: 15.2))
    }

    func testAudioOnlyUsesAudioTarget() {
        XCTAssertFalse(PlaybackEngine.isReadAheadEnough(audioAhead: 14.9, videoAhead: nil))
        XCTAssertTrue(PlaybackEngine.isReadAheadEnough(audioAhead: 15.1, videoAhead: nil))
    }

    func testPureVideoUsesVideoTarget() {
        XCTAssertFalse(PlaybackEngine.isReadAheadEnough(audioAhead: nil, videoAhead: 14.9))
        XCTAssertTrue(PlaybackEngine.isReadAheadEnough(audioAhead: nil, videoAhead: 15.1))
    }
}
