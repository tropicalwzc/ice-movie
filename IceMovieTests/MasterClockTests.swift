import XCTest
@testable import IceCore

/// 4.5 同步逻辑单元测试：时钟推进、暂停恢复、跳转后重设、速率变化与音频校正。
final class MasterClockTests: XCTestCase {
    /// 可手动推进的假时间源，避免依赖真实等待。
    private final class FakeTime: @unchecked Sendable {
        var value: Double = 0
    }

    private func makeClock() -> (MasterClock, FakeTime) {
        let time = FakeTime()
        let clock = MasterClock(now: { time.value })
        return (clock, time)
    }

    func testInitialStateIsPausedAtZero() {
        let (clock, _) = makeClock()
        XCTAssertEqual(clock.currentTime, 0, accuracy: 0.0001)
        XCTAssertFalse(clock.isPlaying)
        XCTAssertEqual(clock.rate, 1)
    }

    func testAdvancesWhilePlaying() {
        let (clock, time) = makeClock()
        clock.play()
        time.value = 3
        XCTAssertEqual(clock.currentTime, 3, accuracy: 0.001)
        time.value = 10
        XCTAssertEqual(clock.currentTime, 10, accuracy: 0.001)
    }

    func testPauseFreezesAndResumeDoesNotJump() {
        let (clock, time) = makeClock()
        clock.play()
        time.value = 5
        clock.pause()

        // 暂停 30 秒，时钟必须停在原地。
        time.value = 35
        XCTAssertEqual(clock.currentTime, 5, accuracy: 0.001)

        clock.play()
        time.value = 36
        XCTAssertEqual(clock.currentTime, 6, accuracy: 0.001)
        XCTAssertEqual(clock.lastSyncDrift, 0, accuracy: 0.0001)
    }

    func testSeekResetsAnchorWhilePlaying() {
        let (clock, time) = makeClock()
        clock.play()
        time.value = 4
        clock.seek(to: 120)
        XCTAssertEqual(clock.currentTime, 120, accuracy: 0.001)

        time.value = 6
        XCTAssertEqual(clock.currentTime, 122, accuracy: 0.001)
    }

    func testSeekWhilePausedDoesNotAdvance() {
        let (clock, time) = makeClock()
        clock.seek(to: 60)
        time.value = 20
        XCTAssertEqual(clock.currentTime, 60, accuracy: 0.001)
        XCTAssertFalse(clock.isPlaying)
    }

    func testRateChangeKeepsCurrentTime() {
        let (clock, time) = makeClock()
        clock.play()
        time.value = 5
        clock.setRate(2)
        XCTAssertEqual(clock.currentTime, 5, accuracy: 0.001)

        time.value = 6
        XCTAssertEqual(clock.currentTime, 7, accuracy: 0.001)

        clock.pause()
        time.value = 10
        XCTAssertEqual(clock.currentTime, 7, accuracy: 0.001)
    }

    func testRateIsClamped() {
        let (clock, _) = makeClock()
        clock.setRate(100)
        XCTAssertEqual(clock.rate, 4, accuracy: 0.001)
        clock.setRate(0.01)
        XCTAssertEqual(clock.rate, 0.25, accuracy: 0.001)
    }

    func testSyncIgnoresSmallDrift() {
        let (clock, time) = makeClock()
        clock.play()
        time.value = 10
        clock.sync(to: 10.02)
        XCTAssertEqual(clock.correctionCount, 0)
        XCTAssertEqual(clock.currentTime, 10, accuracy: 0.001)
    }

    func testSyncCorrectsLargeDrift() {
        let (clock, time) = makeClock()
        clock.play()
        time.value = 10
        // 音频落后时钟 0.2 秒（例如解码卡顿后的追赶）。
        clock.sync(to: 9.8)
        XCTAssertEqual(clock.correctionCount, 1)
        XCTAssertEqual(clock.currentTime, 9.8, accuracy: 0.001)

        time.value = 11
        XCTAssertEqual(clock.currentTime, 10.8, accuracy: 0.001)
    }

    func testSyncWhilePausedDoesNotStartClock() {
        let (clock, time) = makeClock()
        clock.seek(to: 30)
        time.value = 5
        clock.sync(to: 30.5)
        XCTAssertFalse(clock.isPlaying)
        XCTAssertEqual(clock.currentTime, 30.5, accuracy: 0.001)

        time.value = 9
        XCTAssertEqual(clock.currentTime, 30.5, accuracy: 0.001)
    }
}
