import CFFmpeg
@testable import DemuxKit
import Foundation
import IceCore
import SMBSession
import XCTest

private final class RecordingByteSource: ByteSource, ReadStatsProviding, @unchecked Sendable {
    let length: Int64?
    private(set) var requests: [Int] = []
    private(set) var bytes: Int64 = 0

    init(length: Int64) {
        self.length = length
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        requests.append(count)
        let available = max(0, Int(length! - offset))
        let actual = min(count, available)
        guard actual > 0 else { return Data() }
        bytes += Int64(actual)
        return Data(repeating: 0, count: actual)
    }

    func close() async {}

    var readStats: ByteSourceReadStats {
        ByteSourceReadStats(readCount: requests.count, bytesRead: bytes)
    }
}

private final class FailingByteSource: ByteSource, @unchecked Sendable {
    let length: Int64? = 1 << 20

    func read(at offset: Int64, count: Int) async throws -> Data {
        throw ByteSourceError.underlying("测试用读取失败")
    }

    func close() async {}
}

final class StartupReadTests: XCTestCase {
    func testReadFailureReturnsEIOInsteadOfEOF() throws {
        let source = FailingByteSource()
        let bridge = try AVIOBridge(source: source, startWindowSize: 64 << 10)
        let context = try XCTUnwrap(bridge.context)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }

        XCTAssertEqual(avio_read(context, buffer, 4096), Int32(-EIO))
    }
    func testAdaptiveWindowStartsSmallAndGrows() throws {
        let source = RecordingByteSource(length: 128 << 20)
        let bridge = try AVIOBridge(source: source, startWindowSize: 64 << 10)
        let context = try XCTUnwrap(bridge.context)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 << 10)
        defer { buffer.deallocate() }

        for _ in 0..<4 {
            XCTAssertEqual(avio_read(context, buffer, 64 << 10), 64 << 10)
        }
        XCTAssertTrue(
            source.requests.prefix(4).allSatisfy { $0 <= 256 << 10 },
            "打开阶段的小读不应放大成大窗口：\(source.requests.prefix(4))"
        )

        let big = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
        defer { big.deallocate() }
        for _ in 0..<60 {
            XCTAssertEqual(avio_read(context, big, 1 << 20), 1 << 20)
        }
        XCTAssertTrue(
            source.requests.contains { $0 >= 4 << 20 },
            "连续顺序读应把窗口增长到 4MB：\(source.requests.max() ?? 0)"
        )

        _ = avio_seek(context, 16 << 20, SEEK_SET)
        XCTAssertEqual(avio_read(context, buffer, 64 << 10), 64 << 10)
        XCTAssertLessThanOrEqual(
            source.requests.last ?? 0,
            256 << 10,
            "seek 后应回退到小窗口"
        )
    }

    func testFastProbeSkipsMKVFontAttachments() throws {
        let path = "/private/tmp/animi/re0 s3/[New Fyy Raws] Re-Zero kara Hajimeru Isekai Seikatsu 3rd Season - 02 [IEM 2160p WEB-DL AAC Multi-Subs].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Re:Zero 字体附件样本未挂载")
        }
        let base = try LocalFileByteSource(url: URL(fileURLWithPath: path))
        let reader = try MediaReader.open(source: base, label: path, fastProbe: true)
        defer { reader.close() }
        XCTAssertEqual(reader.attachmentFontBytes, 0)
        XCTAssertGreaterThan(reader.skippedFontCount, 0)
    }

    func testFastProbeKeepsCoverArtButSkipsFonts() throws {
        let path = "/private/tmp/font_cover.mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("字体+封面图样本未生成")
        }
        let base = try LocalFileByteSource(url: URL(fileURLWithPath: path))
        let reader = try MediaReader.open(source: base, label: path, fastProbe: true)
        defer { reader.close() }
        XCTAssertEqual(reader.attachmentFontBytes, 0)
        XCTAssertGreaterThan(reader.skippedFontCount, 0)
        XCTAssertGreaterThan(
            reader.attachedPictureBytes, 0,
            "跳过字体后封面图附件仍应保留"
        )
    }

    func testRingPinKeepsContainerHeader() {
        let ring = SMBChunkRing(chunkSize: 4, capacity: 8)
        ring.store(Data([0, 1, 2, 3]), at: 0)
        ring.store(Data([8, 9, 10, 11]), at: 8)

        ring.trim(keepFrom: 8, keepTo: 12, pinHeaderBytes: 4)

        XCTAssertNotNil(ring.chunk(at: 0), "容器头区间不应被 seek 淘汰")
        XCTAssertNotNil(ring.chunk(at: 8))
    }
}
