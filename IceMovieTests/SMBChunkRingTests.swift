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

    func testResetClearsAllChunks() {
        let ring = SMBChunkRing(chunkSize: 4, capacity: 4)
        ring.store(Data([0, 1, 2, 3]), at: 0)
        ring.reset()

        XCTAssertNil(ring.readAvailable(at: 0, count: 4))
        XCTAssertEqual(ring.stats().chunks, 0)
    }
}
