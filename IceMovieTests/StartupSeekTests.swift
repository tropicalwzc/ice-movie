import DemuxKit
import RenderKit
import XCTest

final class StartupSeekTests: XCTestCase {
    func testPrepareSeekPositionsBeforePlay() async throws {
        let path = "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("强风吹拂样本未挂载")
        }
        let reader = try MediaReader.open(path: path)
        let engine = try PlaybackEngine(reader: reader)
        let observedTarget = SeekTargetRecorder()
        let seekObserved = expectation(description: "seek observer called")
        engine.setSeekObserver { target in
            observedTarget.record(target)
            seekObserved.fulfill()
        }
        defer {
            engine.stop()
            reader.close()
        }

        let located = await engine.prepareSeek(to: 20)
        XCTAssertTrue(located)
        await fulfillment(of: [seekObserved], timeout: 1)
        XCTAssertEqual(observedTarget.value ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(engine.clock.currentTime, 20, accuracy: 0.75)
        XCTAssertFalse(engine.clock.isPlaying, "起播前定位不应启动主时钟")
    }

    func testStopJoinsPumpBeforeReaderClose() async throws {
        let path = "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("强风吹拂样本未挂载")
        }
        let reader = try MediaReader.open(path: path)
        let engine = try PlaybackEngine(reader: reader)

        _ = await engine.prepareSeek(to: 20)
        engine.stop()
        // stop() 必须已经汇合 FFmpeg 播放泵；否则 close 会释放其仍在使用的上下文。
        reader.close()
        XCTAssertFalse(engine.isPlaying)
    }

}

private final class SeekTargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Double?

    var value: Double? {
        lock.withLock { storedValue }
    }

    func record(_ value: Double) {
        lock.withLock { storedValue = value }
    }
}
