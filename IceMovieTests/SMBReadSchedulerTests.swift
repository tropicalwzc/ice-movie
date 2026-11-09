import Foundation
import SMBSession
import XCTest

final class SMBReadSchedulerTests: XCTestCase {
    func testPriorityOrderPlaybackBeforeEnumerationBeforeThumbnail() async {
        let scheduler = SMBReadScheduler(label: "test-priority")
        let order = OrderBox()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "worker started")

        let blocker = Task {
            _ = try? await scheduler.submit(priority: .thumbnail) {
                started.fulfill()
                gate.wait()
                return Data([0])
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let thumbnail = Task {
            _ = try? await scheduler.submit(priority: .thumbnail) {
                order.append("thumbnail")
                return Data()
            }
        }
        let enumeration = Task {
            _ = try? await scheduler.submit(priority: .enumeration) {
                order.append("enumeration")
                return Data()
            }
        }
        let playback = Task {
            _ = try? await scheduler.submit(priority: .playback) {
                order.append("playback")
                return Data()
            }
        }

        while scheduler.pendingCount < 3 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        gate.signal()

        _ = await (blocker.value, thumbnail.value, enumeration.value, playback.value)
        XCTAssertEqual(order.values, ["playback", "enumeration", "thumbnail"])
    }

    func testTimeoutReturnsErrorWithoutWaitingForSlowOperation() async {
        let scheduler = SMBReadScheduler(label: "test-timeout")
        let began = Date()

        do {
            _ = try await scheduler.submit(priority: .playback, timeout: 0.1) {
                Thread.sleep(forTimeInterval: 0.4)
                return Data([1])
            }
            XCTFail("应当超时")
        } catch let error as SMBReadError {
            XCTAssertEqual(error, .timeout(0.1))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(began), 0.35)
    }

    func testCancelAllTerminatesPendingRequests() async {
        let scheduler = SMBReadScheduler(label: "test-cancel")
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "worker started")

        let blocker = Task {
            _ = try? await scheduler.submit(priority: .playback) {
                started.fulfill()
                gate.wait()
                return Data()
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let pending = Task {
            try await scheduler.submit(priority: .thumbnail) {
                Data()
            }
        }
        while scheduler.pendingCount < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        scheduler.cancelAll(error: .disconnected)

        do {
            _ = try await pending.value
            XCTFail("挂起请求应被终结")
        } catch let error as SMBReadError {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }

        gate.signal()
        _ = await blocker.value
    }
}

private final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
