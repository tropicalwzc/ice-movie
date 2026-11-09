import SMBSession
import XCTest

final class SMBReconnectPolicyTests: XCTestCase {
    func testDefaultBackoffSequence() {
        let policy = SMBReconnectPolicy()
        XCTAssertEqual(policy.maxAttempts, 6)
        XCTAssertEqual(
            (1...6).map { policy.delay(forAttempt: $0) },
            [1, 2, 4, 8, 16, 30]
        )
        XCTAssertNil(policy.delay(forAttempt: 0))
        XCTAssertNil(policy.delay(forAttempt: 7))
    }

    func testCustomBackoffSequence() {
        let policy = SMBReconnectPolicy(delays: [0.1, 0.2])
        XCTAssertEqual(policy.maxAttempts, 2)
        XCTAssertEqual(policy.delay(forAttempt: 1), 0.1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 0.2)
        XCTAssertNil(policy.delay(forAttempt: 3))
    }

    func testRecoverableErrorClassification() {
        XCTAssertFalse(SMBConnectionError.authenticationFailed("bad").isRecoverable)
        XCTAssertFalse(SMBConnectionError.invalidAddress("bad").isRecoverable)
        XCTAssertFalse(SMBConnectionError.nameNotResolved("bad").isRecoverable)
        XCTAssertTrue(SMBConnectionError.unreachable("down").isRecoverable)
        XCTAssertTrue(SMBConnectionError.staleHandle("closed").isRecoverable)
        XCTAssertTrue(SMBConnectionError.notConnected.isRecoverable)
        XCTAssertTrue(SMBConnectionError.failed("x").isRecoverable)
    }
}
