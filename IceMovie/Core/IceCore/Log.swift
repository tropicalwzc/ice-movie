import Foundation
import os

/// 日志级别。`debug` 默认关闭，可在诊断页临时打开。
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case notice = 2
    case error = 3

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTE"
        case .error: "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 日志分类。按排查对象划分，而不是按代码模块划分。
public enum LogCategory: String, Sendable, CaseIterable {
    case app
    case smb
    case demux
    case render
    case subtitle
    case thumbnail
}

public struct LogEntry: Identifiable, Sendable {
    public let id: UInt64
    public let date: Date
    public let category: LogCategory
    public let level: LogLevel
    public let message: String

    public init(id: UInt64, date: Date, category: LogCategory, level: LogLevel, message: String) {
        self.id = id
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }
}

/// 内存环形缓冲。保留最近若干条日志，供 App 内诊断页查看与导出。
public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore()

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private var nextID: UInt64 = 0
    private var _minimumLevel: LogLevel = .info
    private let capacity: Int

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    public var minimumLevel: LogLevel {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _minimumLevel
        }
        set {
            lock.lock()
            _minimumLevel = newValue
            lock.unlock()
        }
    }

    public func append(level: LogLevel, category: LogCategory, message: String) {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        buffer.append(LogEntry(id: nextID, date: Date(), category: category, level: level, message: message))
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    public func snapshot(minimumLevel level: LogLevel = .debug, category: LogCategory? = nil) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.filter { $0.level >= level && (category == nil || $0.category == category) }
    }

    public func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// 统一日志门面。
///
/// 约定：
/// - 不记录密码与凭据原文；用户名可记录。
/// - 共享内路径只记录末两级，避免日志过长且泄露目录结构。
/// - 一律不用 `print`，方便同时进入 OSLog 与内存环。
public enum Log {
    public static let subsystem = "com.wangzicheng.icemovie"

    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        }
    )

    public static var minimumLevel: LogLevel {
        get { LogStore.shared.minimumLevel }
        set { LogStore.shared.minimumLevel = newValue }
    }

    public static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        write(.debug, category, message())
    }

    public static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        write(.info, category, message())
    }

    public static func notice(_ category: LogCategory, _ message: @autoclosure () -> String) {
        write(.notice, category, message())
    }

    public static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        write(.error, category, message())
    }

    /// 只保留路径末两级，用于日志中的文件标识。
    public static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.suffix(2).joined(separator: "/")
    }

    private static func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        guard level >= LogStore.shared.minimumLevel else { return }
        LogStore.shared.append(level: level, category: category, message: message)
        guard let logger = loggers[category] else { return }
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}
