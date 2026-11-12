import Foundation

/// 文件名末尾的拍摄时间：`_yyyyMMddHHmmss`。
public struct PhotoTimestamp: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    public var dayKey: PhotoDay {
        PhotoDay(year: year, month: month, day: day)
    }

    /// 定长十进制编码：`yyyyMMddHHmmss`，每一位都有独立位宽，避免不同时间产生相同键。
    public var sortKey: Int64 {
        Int64(year) * 10_000_000_000
            + Int64(month) * 100_000_000
            + Int64(day) * 1_000_000
            + Int64(hour) * 10_000
            + Int64(minute) * 100
            + Int64(second)
    }

    public var displayTime: String {
        String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            year, month, day, hour, minute, second
        )
    }

    /// 文件名使用的紧凑时间戳：`yyyyMMddHHmmss`。
    public var compactString: String {
        String(
            format: "%04d%02d%02d%02d%02d%02d",
            year, month, day, hour, minute, second
        )
    }

    /// 网格副标题使用的拍摄日期，例如 `2022年1月2日`。
    public var displayDay: String {
        "\(year)年\(month)月\(day)日"
    }

    public static func < (lhs: PhotoTimestamp, rhs: PhotoTimestamp) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

/// 一天（仅年月日），用于日历分组。
public struct PhotoDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var id: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var title: String {
        "\(year)年\(month)月\(day)日"
    }

    public static func < (lhs: PhotoDay, rhs: PhotoDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public enum PhotoTimestampParser {
    /// 只匹配扩展名前最后一个下划线后的 14 位 ASCII 数字。
    public static func parse(filename: String) -> PhotoTimestamp? {
        let pathExtension = (filename as NSString).pathExtension
        guard !pathExtension.isEmpty else { return nil }
        let base = (filename as NSString).deletingPathExtension
        guard let underscore = base.lastIndex(of: "_") else { return nil }
        let suffix = base[base.index(after: underscore)...]
        guard suffix.count == 14,
              suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        let digits = Array(suffix)
        func value(_ range: Range<Int>) -> Int {
            Int(String(digits[range])) ?? -1
        }
        let year = value(0..<4)
        let month = value(4..<6)
        let day = value(6..<8)
        let hour = value(8..<10)
        let minute = value(10..<12)
        let second = value(12..<14)

        guard (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let firstOfMonth = calendar.date(
            from: DateComponents(year: year, month: month, day: 1)
        ), let days = calendar.range(of: .day, in: .month, for: firstOfMonth),
           days.contains(day) else {
            return nil
        }

        return PhotoTimestamp(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }
}
