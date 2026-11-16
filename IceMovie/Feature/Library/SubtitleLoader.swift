import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import SubtitleKit

/// 一次字幕加载的完整产物：时间轴用于兜底文字渲染，脚本与字体用于 libass。
struct LoadedSubtitles: Sendable {
    let timeline: SubtitleTimeline
    let script: String?
    let fonts: [SubtitleFont]
}

/// 把一条字幕轨加载成时间轴。外挂读文件，内封用独立字节源提取，避免干扰播放读流。
struct SubtitleLoader {
    let source: any LibrarySource
    let entry: MediaEntry

    /// 缓存键必须带数据源身份：共享/本地根目录切换后，相同相对路径与时间戳
    /// 不能命中另一媒体源的字幕。
    private var cacheNamespace: String { source.cacheNamespace }

    func load(_ track: SubtitleTrack) async throws -> LoadedSubtitles {
        switch track.source {
        case .external(let fileName):
            guard track.format != .bitmap else {
                throw SubtitleLoadError.unsupportedBitmap(track.title)
            }
            let path = entry.directoryPath.isEmpty
                ? fileName
                : entry.directoryPath + "/" + fileName
            let byteSource = try await source.openSubtitleByteSource(path: path)
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let data = try await readAll(byteSource)
                await byteSource.close()
                let text = SubtitleTextDecoder.decode(
                    data,
                    language: track.language,
                    format: track.format
                )
                let sanitized = track.format == .ass
                    ? ASSScriptSanitizer.sanitizeIfNeeded(text)
                    : ASSScriptSanitizer.Result(
                        script: text,
                        originalEvents: 0,
                        keptEvents: 0,
                        applied: false
                    )
                let cues = SubtitleParser.parse(sanitized.script, format: track.format)
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                Log.info(
                    .subtitle,
                    "外挂字幕加载 \(Log.shortPath(path)) 条目=\(cues.count) 耗时=\(elapsed)ms "
                        + "降级=\(sanitized.applied ? "是" : "否")"
                )
                guard !cues.isEmpty else {
                    throw SubtitleLoadError.empty(track.title)
                }
                let script = track.format == .ass ? sanitized.script : nil
                // 容器字体附件不再读取：统一使用内置 CJK / CoreText 系统字体。
                return LoadedSubtitles(
                    timeline: SubtitleTimeline(cues: cues),
                    script: script,
                    fonts: []
                )
            } catch {
                await byteSource.close()
                throw error
            }

        case .embedded(let index):
            // 位图字幕（PGS/DVD/DVB）不会产生文本事件，分片与整文件提取都无法显示。
            // 在打开字节源前直接失败，让默认选轨继续尝试后续文本轨道。
            guard track.format != .bitmap else {
                throw SubtitleLoadError.unsupportedBitmap(track.title)
            }
            if let cached = SubtitleScriptCache.load(
                entry: entry,
                streamIndex: index,
                namespace: cacheNamespace
            ) {
                let sanitized = ASSScriptSanitizer.sanitizeIfNeeded(cached)
                let cues = SubtitleParser.parse(sanitized.script, format: .ass)
                if !cues.isEmpty {
                    // 缓存只存脚本；字体统一使用内置 CJK / 系统字体，不再读附件。
                    let script = track.format == .ass ? sanitized.script : nil
                    Log.info(
                        .subtitle,
                        "内封字幕缓存命中 stream=\(index) 条目=\(cues.count) 字体附件=0"
                    )
                    return LoadedSubtitles(
                        timeline: SubtitleTimeline(cues: cues),
                        script: script,
                        fonts: []
                    )
                }
            }

            let byteSource = try await source.openSubtitleByteSource(path: entry.path)
            // 只读字幕轨，不跑完整流探测；字体附件也不读。
            let reader = try MediaReader.open(source: byteSource, label: entry.path, fastProbe: true)
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let text = try reader.readSubtitleScript(streamIndex: index)
                reader.close()
                await byteSource.close()
                let sanitized = track.format == .ass
                    ? ASSScriptSanitizer.sanitizeIfNeeded(text)
                    : ASSScriptSanitizer.Result(
                        script: text,
                        originalEvents: 0,
                        keptEvents: 0,
                        applied: false
                    )
                let cues = SubtitleParser.parse(sanitized.script, format: .ass)
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                Log.info(
                    .subtitle,
                    "内封字幕加载 stream=\(index) 条目=\(cues.count) 字体附件=0 "
                        + "耗时=\(elapsed)ms 降级=\(sanitized.applied ? "是" : "否")"
                )
                guard !cues.isEmpty else {
                    throw SubtitleLoadError.empty(track.title)
                }
                SubtitleScriptCache.save(
                    sanitized.script,
                    entry: entry,
                    streamIndex: index,
                    namespace: cacheNamespace
                )
                return LoadedSubtitles(
                    timeline: SubtitleTimeline(cues: cues),
                    script: track.format == .ass ? sanitized.script : nil,
                    fonts: []
                )
            } catch {
                reader.close()
                await byteSource.close()
                throw error
            }
        }
    }

    private func readAll(_ source: any ByteSource) async throws -> Data {
        var data = Data()
        var offset: Int64 = 0
        let chunkSize = 1 << 20
        while true {
            let chunk = try await source.read(at: offset, count: chunkSize)
            if chunk.isEmpty { break }
            data.append(chunk)
            offset += Int64(chunk.count)
            if let length = source.length, offset >= length { break }
        }
        return data
    }

}

enum SubtitleTextDecoder {
    private struct Candidate {
        let encoding: String
        let text: String
        let score: Int
    }

    static func decode(
        _ data: Data,
        language: SubtitleLanguage = .unknown,
        format: SubtitleFormat = .other
    ) -> String {
        // BOM 是最可靠的判据。UTF-32 必须放在 UTF-16 前，因为两者都从 FF FE 开始。
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
                ?? String(decoding: data, as: UTF8.self)
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data.dropFirst(4), encoding: .utf32BigEndian)
                ?? String(decoding: data, as: UTF8.self)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(
                data: data.dropFirst(2),
                encoding: .utf16LittleEndian
            ) ?? String(decoding: data, as: UTF8.self)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(
                data: data.dropFirst(2),
                encoding: .utf16BigEndian
            ) ?? String(decoding: data, as: UTF8.self)
        }
        if let text = String(data: data, encoding: .utf8) { return text }

        // 部分旧字幕组的 ASS 无 BOM，但字符仍按 UTF-16 存储。
        let sampleCount = min(1024, data.count)
        if sampleCount >= 16 {
            var evenZeros = 0
            var oddZeros = 0
            for index in 0..<sampleCount {
                if data[data.startIndex + index] == 0 {
                    if index.isMultiple(of: 2) {
                        evenZeros += 1
                    } else {
                        oddZeros += 1
                    }
                }
            }
            if oddZeros > sampleCount / 4, evenZeros < sampleCount / 20,
               let text = String(data: data, encoding: .utf16LittleEndian) {
                return text
            }
            if evenZeros > sampleCount / 4, oddZeros < sampleCount / 20,
               let text = String(data: data, encoding: .utf16BigEndian) {
                return text
            }
        }

        // GB18030 兼容 GBK/GB2312；Big5 兼容台港繁体与部分 HKSCS 字符。
        var candidates: [Candidate] = []
        addCandidate(
            label: "GB18030",
            encoding: .GB_18030_2000,
            preferred: language == .simplifiedChinese,
            data: data,
            language: language,
            format: format,
            to: &candidates
        )
        addCandidate(
            label: "Big5",
            encoding: .big5,
            preferred: language == .traditionalChinese,
            data: data,
            language: language,
            format: format,
            to: &candidates
        )
        addCandidate(
            label: "Big5-HKSCS",
            encoding: .big5_HKSCS_1999,
            preferred: language == .traditionalChinese,
            data: data,
            language: language,
            format: format,
            to: &candidates
        )
        if let best = candidates.max(by: { $0.score < $1.score }) {
            return best.text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func addCandidate(
        label: String,
        encoding: CFStringEncodings,
        preferred: Bool,
        data: Data,
        language: SubtitleLanguage,
        format: SubtitleFormat,
        to candidates: inout [Candidate]
    ) {
        let raw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(encoding.rawValue)
        )
        guard let text = String(
            data: data,
            encoding: String.Encoding(rawValue: raw)
        ) else { return }
        candidates.append(
            Candidate(
                encoding: label,
                text: text,
                score: score(
                    text,
                    language: language,
                    format: format,
                    preferred: preferred
                )
            )
        )
    }

    private static func score(
        _ text: String,
        language: SubtitleLanguage,
        format: SubtitleFormat,
        preferred: Bool
    ) -> Int {
        let lower = text.lowercased()
        var value = preferred ? 200 : 0
        if lower.contains("[script info]") { value += 500 }
        if lower.contains("[events]") { value += 800 }
        if lower.contains("dialogue:") { value += 300 }
        if lower.contains("format:") { value += 100 }
        if lower.contains("-->") { value += 500 }
        let scalars = text.unicodeScalars
        let replacementCount = scalars.filter { $0.value == 0xFFFD }.count
        value -= replacementCount * 80

        var controlCount = 0
        var scalarCount = 0
        for scalar in scalars.prefix(20_000) {
            scalarCount += 1
            if scalar.value < 0x20,
               scalar != "\n",
               scalar != "\r",
               scalar != "\t" {
                controlCount += 1
            }
        }
        value -= controlCount * 20
        if scalarCount > 0 {
            value += (scalarCount - controlCount) * 20 / scalarCount
        }
        if format == .ass || format == .srt {
            value += language == .unknown ? 0 : 20
        }
        return value
    }
}

enum SubtitleLoadError: LocalizedError {
    case empty(String)
    case unsupportedBitmap(String)

    var errorDescription: String? {
        switch self {
        case .empty(let title): "字幕没有可显示的内容：\(title)"
        case .unsupportedBitmap(let title): "位图字幕暂不支持：\(title)"
        }
    }
}
