import Foundation

/// 会话健康状态。供诊断页与上层提示使用。
public enum SMBSessionState: Sendable, Equatable {
    case idle
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// 指数退避策略。纯逻辑，便于单测；SMBClient 只负责执行。
public struct SMBReconnectPolicy: Sendable, Equatable {
    public let delays: [TimeInterval]

    public init(delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]) {
        self.delays = delays
    }

    public var maxAttempts: Int { delays.count }

    /// attempt 从 1 开始；超出次数返回 nil，表示停止重试。
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}
