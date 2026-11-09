import Foundation

public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 字幕文件解析。当前覆盖 SRT 与 ASS/SSA 的对白文本（样式交给渲染层处理）。
public enum SubtitleParser {
    public static func parse(_ text: String, format: SubtitleFormat) -> [SubtitleCue] {
        switch format {
        case .srt: parseSRT(text)
        case .ass: parseASS(text)
        case .other: parseSRT(text)
        }
    }

    // MARK: - SRT

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[index].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = parseSRTTime(times[0]),
                  let end = parseSRTTime(times[1]) else { continue }
            let body = lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseSRTTime(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let parts = value.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + s
    }

    // MARK: - ASS

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var startIndex = 0
        var endIndex = 1
        var textIndex = 9
        var inEvents = false

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents else { continue }

            if line.lowercased().hasPrefix("format:") {
                let fields = line.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let i = fields.firstIndex(of: "start") { startIndex = i }
                if let i = fields.firstIndex(of: "end") { endIndex = i }
                if let i = fields.firstIndex(of: "text") { textIndex = i }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }

            let payload = line.dropFirst("dialogue:".count)
            // Text 是最后一个字段，可能含逗号，因此只按前 n-1 个逗号切分。
            var fields: [String] = []
            var remainder = Substring(payload)
            let limit = max(startIndex, endIndex, textIndex)
            for _ in 0..<limit {
                guard let comma = remainder.firstIndex(of: ",") else { break }
                fields.append(String(remainder[..<comma]).trimmingCharacters(in: .whitespaces))
                remainder = remainder[remainder.index(after: comma)...]
            }
            fields.append(String(remainder))

            guard fields.count > max(startIndex, endIndex, textIndex),
                  let start = parseASSTime(fields[startIndex]),
                  let end = parseASSTime(fields[endIndex]) else { continue }

            let rawText = fields[textIndex]
            // 矢量绘图（\p1 等）不是可读文本，跳过，避免把 "m 0 0 l ..." 显示到画面。
            if rawText.range(of: #"\\p[0-9]"#, options: .regularExpression) != nil {
                continue
            }

            let body = stripOverrideTags(rawText)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `0:01:23.45`
    private static func parseASSTime(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + s
    }

    /// 去掉 `{\pos(..)\c&H..&}` 这类覆盖标签，保留可见文本。
    static func stripOverrideTags(_ text: String) -> String {
        text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }
}

/// 按时间查找当前应当显示的字幕。
public struct SubtitleTimeline: Sendable {
    public let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    public func active(at time: Double) -> [SubtitleCue] {
        // 二分找到最后一个 start <= time 的位置，再向前回溯少量重叠项。
        var low = 0
        var high = cues.count - 1
        var pivot = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                pivot = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard pivot >= 0 else { return [] }

        var result: [SubtitleCue] = []
        var index = pivot
        while index >= 0, cues[index].end > time {
            result.append(cues[index])
            index -= 1
        }
        return result.reversed()
    }
}
