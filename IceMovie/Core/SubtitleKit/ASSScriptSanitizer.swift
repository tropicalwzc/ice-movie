import Foundation
import IceCore

/// 针对「特效字幕」的降级处理。
///
/// 部分字幕组会把 OP/ED 做成数万条 `\p1` 矢量绘图与逐字动画事件。
/// libass 在这些时间点单帧渲染可能需要数百毫秒到数秒，放在主线程会拖住
/// 视频显示与手势。这里在脚本过大时只保留对白/Tips 事件，去掉特效绘图，
/// 保证字幕可读且不影响播放。
public enum ASSScriptSanitizer {
    public struct Result: Sendable {
        public let script: String
        public let originalEvents: Int
        public let keptEvents: Int
        public let applied: Bool

        public init(
            script: String,
            originalEvents: Int,
            keptEvents: Int,
            applied: Bool
        ) {
            self.script = script
            self.originalEvents = originalEvents
            self.keptEvents = keptEvents
            self.applied = applied
        }
    }

    private static let heavyByteThreshold = 4 * 1024 * 1024
    private static let heavyEventThreshold = 5_000

    /// 特效/绘图事件判定：供整脚本降级与分片加载共用。
    public static func isEffectEvent(style: String, body: String) -> Bool {
        if body.range(of: #"\\p[0-9]"#, options: .regularExpression) != nil {
            return true
        }
        if style.range(
            of: #"(?i)(^|[\s_/])(op|ed|staff|fx|title)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if style.contains("//") { return true }
        let plain = plainText(body) ?? ""
        if plain.range(of: #"^[mblc]\s+-?\d"#, options: .regularExpression) != nil {
            return true
        }
        return plain.isEmpty
    }

    /// 去掉 ASS override 标签并还原换行；没有可读文本时返回 nil。
    public static func plainText(_ body: String) -> String? {
        let text = body
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func sanitizeIfNeeded(_ text: String) -> Result {        let originalEvents = text.components(separatedBy: "\nDialogue:").count - 1
        let isHeavy = text.utf8.count >= heavyByteThreshold
            || originalEvents >= heavyEventThreshold
        guard isHeavy else {
            return Result(
                script: text,
                originalEvents: originalEvents,
                keptEvents: originalEvents,
                applied: false
            )
        }
        guard let eventsRange = text.range(of: "[Events]", options: .caseInsensitive) else {
            return Result(
                script: text,
                originalEvents: originalEvents,
                keptEvents: originalEvents,
                applied: false
            )
        }

        var kept: [String] = []
        for line in text.split(separator: "\n") where line.hasPrefix("Dialogue:") {
            let fields = line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count >= 10 else { continue }
            let style = String(fields[3])
            let body = String(fields[9])

            // 矢量绘图（\p1 等）不是可读对白。
            if body.range(of: #"\\p[0-9]"#, options: .regularExpression) != nil { continue }
            // OP/ED、staff、特效与注释样式。
            if style.range(
                of: #"(?i)(^|[\s_/])(op|ed|staff|fx|title)"#,
                options: .regularExpression
            ) != nil { continue }
            if style.contains("//") { continue }
            let plain = body.replacingOccurrences(
                of: #"\{[^}]*\}"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { continue }
            // 少数绘图行没有 \p 标记，直接是 m/b 曲线命令。
            if plain.range(of: #"^[mblc]\s+-?\d"#, options: .regularExpression) != nil { continue }
            kept.append(String(line))
        }

        // 过滤后太少说明判断有误，宁可保留原脚本也不要误删对白。
        guard kept.count >= 10 else {
            return Result(
                script: text,
                originalEvents: originalEvents,
                keptEvents: originalEvents,
                applied: false
            )
        }

        let header = String(text[..<eventsRange.lowerBound])
        let script = header
            + "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            + kept.joined(separator: "\n")
        Log.notice(
            .subtitle,
            "特效字幕过重，已降级为对白 原始事件=\(originalEvents) 保留=\(kept.count)"
        )
        return Result(
            script: script,
            originalEvents: originalEvents,
            keptEvents: kept.count,
            applied: true
        )
    }
}
