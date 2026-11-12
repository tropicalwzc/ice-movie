import MediaLibraryKit
import XCTest

final class TransferRateMeterTests: XCTestCase {
    func testStableRate() {
        let clock = FakeClock()
        let meter = TransferRateMeter(window: 3, now: { clock.now })
        meter.record(totalBytes: 0)
        clock.now = 1
        meter.record(totalBytes: 1_000_000)
        clock.now = 2
        meter.record(totalBytes: 2_000_000)

        XCTAssertEqual(meter.totalBytes(), 2_000_000)
        XCTAssertEqual(meter.rate(), 1_000_000, accuracy: 1)
    }

    func testRateDropsToZeroAfterStall() {
        let clock = FakeClock()
        let meter = TransferRateMeter(window: 3, now: { clock.now })
        meter.record(totalBytes: 0)
        clock.now = 1
        meter.record(totalBytes: 1_000_000)
        clock.now = 10

        XCTAssertEqual(meter.rate(), 0, accuracy: 0.001)
    }

    func testResetClearsSamples() {
        let clock = FakeClock()
        let meter = TransferRateMeter(window: 3, now: { clock.now })
        meter.record(totalBytes: 0)
        clock.now = 1
        meter.record(totalBytes: 1_000_000)

        meter.reset()
        XCTAssertEqual(meter.totalBytes(), 0)
        XCTAssertEqual(meter.rate(), 0, accuracy: 0.001)
    }

    func testWindowPrunesOldSamples() {
        let clock = FakeClock()
        let meter = TransferRateMeter(window: 2, now: { clock.now })
        meter.record(totalBytes: 0)
        clock.now = 1
        meter.record(totalBytes: 1_000_000)
        clock.now = 2.5
        meter.record(totalBytes: 3_000_000)

        // 窗口从 2.5 回看 2 秒，0 秒的样本被淘汰；速率按 1 秒到 2.5 秒计算。
        XCTAssertEqual(meter.rate(), 1_333_333.333, accuracy: 1)
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval = 0

    var now: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
