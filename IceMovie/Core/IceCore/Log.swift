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

    private static let fileQueue = DispatchQueue(label: "icemovie.log.file")
    /// 单个日志文件上限；保留当前文件与一个 `.1` 轮转文件。
    private static let maximumFileBytes: Int64 = 4 * 1024 * 1024
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var fileURL: URL?
    nonisolated(unsafe) private static var fileBytes: Int64 = 0

    /// `-debugLog` 时把日志同步落盘，便于真机复现后取回。
    public static func enableFileLogging(fileName: String = "ice-playback.log") {
        fileQueue.sync {
            // 多窗口/多场景会重复调用；只初始化一次，且追加而不是清空，
            // 避免后开的窗口把前一个窗口的日志抹掉。
            guard fileHandle == nil else { return }
            let url = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent(fileName)
            if fileSize(url) > maximumFileBytes {
                rotateFile(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            do {
                try handle.seekToEnd()
            } catch {
                try? handle.close()
                return
            }
            fileHandle = handle
            fileURL = url
            fileBytes = fileSize(url)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// 当前文件改名到 `.1`，旧 `.1` 删除；总占用最多两份。
    private static func rotateFile(at url: URL) {
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private static func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        guard level >= LogStore.shared.minimumLevel else { return }
        LogStore.shared.append(level: level, category: category, message: message)
        fileQueue.async {
            guard let fileHandle, let fileURL else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) [\(level.label)] [\(category.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? fileHandle.write(contentsOf: data)
            fileBytes += Int64(data.count)
            guard fileBytes > maximumFileBytes else { return }
            try? fileHandle.close()
            rotateFile(at: fileURL)
            guard let rotated = try? FileHandle(forWritingTo: fileURL) else { return }
            Self.fileHandle = rotated
            fileBytes = 0
        }
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
