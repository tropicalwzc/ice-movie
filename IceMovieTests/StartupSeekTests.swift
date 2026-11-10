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
        defer {
            engine.stop()
            reader.close()
        }

        let located = await engine.prepareSeek(to: 20)
        XCTAssertTrue(located)
        XCTAssertEqual(engine.clock.currentTime, 20, accuracy: 0.75)
        XCTAssertFalse(engine.clock.isPlaying, "起播前定位不应启动主时钟")
    }
}
