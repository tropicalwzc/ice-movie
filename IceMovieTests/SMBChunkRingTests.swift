import Foundation
import SMBSession
import XCTest

final class SMBChunkRingTests: XCTestCase {
    func testSlicesAcrossChunkBoundary() {
        let ring = SMBChunkRing(chunkSize: 4, capacity: 4)
        ring.store(Data([0, 1, 2, 3]), at: 0)
        ring.store(Data([4, 5, 6, 7]), at: 4)

        XCTAssertEqual(ring.readAvailable(at: 2, count: 4), Data([2, 3, 4, 5]))
        XCTAssertEqual(ring.readAvailable(at: 3, count: 2), Data([3, 4]))
        XCTAssertEqual(ring.readAvailable(at: 4, count: 2), Data([4, 5]))
    }

    func testShortEOFChunkAllowsShortRead() {
        let ring = SMBChunkRing(chunkSize: 4, capacity: 4)
        ring.store(Data([0, 1]), at: 0)

        XCTAssertEqual(ring.readAvailable(at: 0, count: 4), Data([0, 1]))
        XCTAssertEqual(ring.readAvailable(at: 1, count: 4), Data([1]))
    }

    func testMissingMiddleChunkIsMiss() {
        let ring = SMBChunkRing(chunkSize: 4, capacity: 4)
        ring.store(Data([0, 1, 2, 3]), at: 0)

        XCTAssertNil(ring.readAvailable(at: 2, count: 4))
    }

    func testEvictsOldestChunkWhenOverCapacity() {
        let ring = SMBChunkRing(chunkSize: 2, capacity: 2)
        ring.store(Data([0, 1]), at: 0)
        ring.store(Data([2, 3]), at: 2)
        ring.store(Data([4, 5]), at: 4)

        XCTAssertNil(ring.readAvailable(at: 0, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 2, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 4, count: 2))
        XCTAssertEqual(ring.stats().chunks, 2)
    }

    func testContiguousBytesDetectGapAndEOF() {
        let ring = SMBChunkRing(chunkSize: 2, capacity: 8)
        ring.store(Data([0, 1]), at: 0)
        ring.store(Data([2, 3]), at: 2)

        XCTAssertTrue(ring.hasContiguousBytes(from: 1, length: 2))
        XCTAssertTrue(ring.hasContiguousBytes(from: 0, length: 4))
        XCTAssertFalse(ring.hasContiguousBytes(from: 0, length: 5))

        let gapped = SMBChunkRing(chunkSize: 2, capacity: 8)
        gapped.store(Data([0, 1]), at: 0)
        gapped.store(Data([4, 5]), at: 4)
        XCTAssertFalse(gapped.hasContiguousBytes(from: 0, length: 4))
        XCTAssertEqual(gapped.contiguousEnd(from: 0), 2)

        let eof = SMBChunkRing(chunkSize: 2, capacity: 8)
        eof.store(Data([0]), at: 0)
        XCTAssertTrue(eof.hasContiguousBytes(from: 0, length: 1))
        XCTAssertFalse(eof.hasContiguousBytes(from: 0, length: 2))
    }

    func testTrimKeepsOnlyOverlappingRange() {
        let ring = SMBChunkRing(chunkSize: 2, capacity: 8)
        for start in stride(from: Int64(0), through: 8, by: 2) {
            ring.store(Data([UInt8(start), UInt8(start + 1)]), at: start)
        }
        ring.trim(keepFrom: 4, keepTo: 10)

        XCTAssertNil(ring.readAvailable(at: 0, count: 2))
        XCTAssertNil(ring.readAvailable(at: 2, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 4, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 6, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 8, count: 2))
    }

    func testEvictionPrefersOutsideBackThenBackWindow() {
        let ring = SMBChunkRing(chunkSize: 2, capacity: 4)
        ring.setRetentionWindow(start: 4, focus: 8, end: 100)
        ring.store(Data([0, 1]), at: 0)
        ring.store(Data([2, 3]), at: 2)
        ring.store(Data([4, 5]), at: 4)
        ring.store(Data([6, 7]), at: 6)

        ring.store(Data([8, 9]), at: 8)
        XCTAssertNil(ring.readAvailable(at: 0, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 2, count: 2))

        ring.store(Data([10, 11]), at: 10)
        XCTAssertNil(ring.readAvailable(at: 2, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 4, count: 2))

        ring.store(Data([12, 13]), at: 12)
        XCTAssertNil(ring.readAvailable(at: 4, count: 2))
        XCTAssertNotNil(ring.readAvailable(at: 6, count: 2))
    }

    func testSeekClassifierPrefersCacheHit() {
        let kind = SMBSeekClassifier.classify(
            target: 100,
            cachedEnd: 200,
            windowStart: 0,
            windowEnd: 300,
            chunkSize: 10
        )
        XCTAssertEqual(kind, .cacheHit)
    }

    func testSeekClassifierKeepsNearWindow() {
        let kind = SMBSeekClassifier.classify(
            target: 100,
            cachedEnd: 100,
            windowStart: 50,
            windowEnd: 300,
            chunkSize: 10
        )
        XCTAssertEqual(kind, .backWindow)
    }

    func testSeekClassifierMissOutsideWindow() {
        let kind = SMBSeekClassifier.classify(
            target: 1000,
            cachedEnd: 1000,
            windowStart: 50,
            windowEnd: 300,
            chunkSize: 10
        )
        XCTAssertEqual(kind, .miss)
    }

    func testResetClearsAllChunks() {
        let ring = SMBChunkRing(chunkSize: 4, capacity: 4)
        ring.store(Data([0, 1, 2, 3]), at: 0)
        ring.reset()

        XCTAssertNil(ring.readAvailable(at: 0, count: 4))
        XCTAssertEqual(ring.stats().chunks, 0)
    }
}
