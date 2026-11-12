import Foundation

/// 当前目录中带拍摄时间的图片日历索引。
///
/// 以图片日期分组，记录每天数量以及当天最新的一张图片（用于跳转）。
public struct PhotoCalendarIndex: Equatable, Sendable {
    public let counts: [PhotoDay: Int]
    public let firstEntries: [PhotoDay: MediaEntry]

    public init(entries: [MediaEntry] = []) {
        var counts: [PhotoDay: Int] = [:]
        var firstEntries: [PhotoDay: MediaEntry] = [:]
        for entry in entries where entry.kind == .image {
            guard let timestamp = entry.captureTimestamp else { continue }
            let day = timestamp.dayKey
            counts[day, default: 0] += 1
            if firstEntries[day] == nil {
                firstEntries[day] = entry
            }
        }
        self.counts = counts
        self.firstEntries = firstEntries
    }

    public var hasDates: Bool { !counts.isEmpty }

    public var years: [Int] {
        Set(counts.keys.map(\.year)).sorted(by: >)
    }

    public func months(in year: Int) -> [Int] {
        Set(
            counts.keys
                .filter { $0.year == year }
                .map(\.month)
        ).sorted(by: >)
    }

    public func monthsWithCounts(in year: Int) -> [(month: Int, count: Int)] {
        Dictionary(grouping: counts.filter { $0.key.year == year }, by: { $0.key.month })
            .map { month, values in
                (month, values.reduce(0) { $0 + $1.value })
            }
            .sorted { $0.month > $1.month }
    }

    public func days(in year: Int, month: Int) -> [Int: Int] {
        Dictionary(
            uniqueKeysWithValues: counts.compactMap { day, count in
                guard day.year == year, day.month == month else { return nil }
                return (day.day, count)
            }
        )
    }

    public func firstEntry(for day: PhotoDay) -> MediaEntry? {
        firstEntries[day]
    }

    /// 某个月里最新的一天所对应的图片；用于“查看整月”。
    public func firstEntry(in year: Int, month: Int) -> MediaEntry? {
        let days = firstEntries.keys.filter { $0.year == year && $0.month == month }
        guard let latestDay = days.max() else { return nil }
        return firstEntries[latestDay]
    }

    public func count(in year: Int, month: Int) -> Int {
        counts.reduce(0) { total, item in
            item.key.year == year && item.key.month == month
                ? total + item.value
                : total
        }
    }
}
