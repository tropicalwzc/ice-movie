import Foundation

public enum SubtitleLanguage: String, Sendable, CaseIterable {
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case english
    case unknown

    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .japanese: "日语"
        case .english: "英语"
        case .unknown: "未知语言"
        }
    }

    /// 按后缀或元数据里的语言标记推断。
    public static func detect(from text: String) -> SubtitleLanguage {
        let value = text.lowercased()
        if value.contains("cht") || value.contains("tc") || value.hasSuffix("繁")
            || value.contains("traditional") || value.contains("zh-hant") {
            return .traditionalChinese
        }
        if value.contains("chs") || value.contains("sc") || value.hasSuffix("简")
            || value.contains("simplified") || value.contains("zh-hans") || value == "zh" {
            return .simplifiedChinese
        }
        if value.contains("jpn") || value.contains("jap") || value == "jp" || value == "ja"
            || value.contains("japanese") || value.contains("日") {
            return .japanese
        }
        if value.contains("eng") || value == "en" || value.contains("english") || value.contains("英") {
            return .english
        }
        return .unknown
    }
}

public enum SubtitleFormat: String, Sendable {
    case ass
    case srt
    /// PGS/DVD/DVB 等位图字幕：当前只支持文本字幕渲染。
    case bitmap
    case other
}

public struct SubtitleTrack: Sendable, Identifiable, Equatable {
    public enum Source: Sendable, Equatable {
        case embedded(streamIndex: Int)
        case external(fileName: String)
    }

    public let id: String
    public let source: Source
    public let title: String
    public let language: SubtitleLanguage
    public let format: SubtitleFormat
    public let isForced: Bool

    public init(
        source: Source,
        title: String,
        language: SubtitleLanguage,
        format: SubtitleFormat,
        isForced: Bool = false
    ) {
        switch source {
        case .embedded(let index): id = "embedded-\(index)"
        case .external(let name): id = "external-\(name)"
        }
        self.source = source
        self.title = title
        self.language = language
        self.format = format
        self.isForced = isForced
    }
}

/// 字幕轨发现：内封轨来自容器元数据，外挂轨按「同目录 + 同名前缀」匹配。
public enum SubtitleDiscovery {
    private static let subtitleExtensions: Set<String> = ["ass", "ssa", "srt", "vtt", "sup", "sub"]

    /// 内封轨的输入：由调用方从 `MediaInfo` 映射而来，避免 SubtitleKit 依赖解封装模块。
    public struct EmbeddedSource: Sendable, Equatable {
        public let streamIndex: Int
        public let codec: String
        public let languageTag: String?
        public let title: String?

        public init(streamIndex: Int, codec: String, languageTag: String? = nil, title: String? = nil) {
            self.streamIndex = streamIndex
            self.codec = codec
            self.languageTag = languageTag
            self.title = title
        }
    }

    public static func embedded(_ sources: [EmbeddedSource]) -> [SubtitleTrack] {
        sources
            .map { source in
                let language = SubtitleLanguage.detect(from: source.languageTag ?? source.title ?? "")
                let format: SubtitleFormat = switch source.codec {
                case "ass", "ssa": .ass
                case "subrip", "srt": .srt
                case "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub": .bitmap
                default: .other
                }
                return SubtitleTrack(
                    source: .embedded(streamIndex: source.streamIndex),
                    title: source.title ?? source.languageTag ?? source.codec,
                    language: language,
                    format: format
                )
            }
            .sorted { order($0.language) < order($1.language) }
    }

    /// 字幕常见的子目录名。
    public static func isSubtitleDirectory(_ name: String) -> Bool {
        let value = name.lowercased()
        let keys = ["sub", "subs", "subtitle", "subtitles", "ass", "srt", "字幕", "字幕文件"]
        return keys.contains { value.contains($0) }
    }

    /// 在同目录（及字幕子目录）里找与视频同集的外挂字幕。
    ///
    /// 真实库里字幕名往往和视频名不同：视频带 `[Kamigami]`、`[BD 1080p x265]` 这类标签，
    /// 字幕则省掉这些并放在 `- Sub` 子目录。因此匹配前先把两边都归一化：
    /// 去掉方括号/圆括号内容与语言标记，抽出集数，只比较「标题 + 集数」。
    public static func external(
        videoFileName: String,
        filesByDirectory: [String: [String]]
    ) -> [SubtitleTrack] {
        let video = parse(videoFileName)
        var tracks: [SubtitleTrack] = []

        for (directory, names) in filesByDirectory {
            for name in names {
                let ext = (name as NSString).pathExtension.lowercased()
                guard subtitleExtensions.contains(ext) else { continue }

                let parsed = parse(name)
                // 文件名里只有集数（如 EP01）时标题会归一化成空串，此时靠集数对齐。
                guard parsed.base == video.base else { continue }
                guard !parsed.base.isEmpty || (parsed.episode != nil && video.episode != nil) else { continue }
                if let a = parsed.episode, let b = video.episode, a != b { continue }

                let language = SubtitleLanguage.detect(from: languageToken(of: name))
                let format: SubtitleFormat = switch ext {
                case "ass", "ssa": .ass
                case "srt": .srt
                case "sup": .bitmap
                default: .other
                }
                let shown = directory.isEmpty ? name : "\(directory)/\(name)"
                tracks.append(
                    SubtitleTrack(
                        source: .external(fileName: shown),
                        title: shown,
                        language: language,
                        format: format,
                        isForced: name.lowercased().contains("forced")
                    )
                )
            }
        }
        return tracks.sorted { order($0.language) < order($1.language) }
    }

    /// 兼容同目录的简单用法。
    public static func external(videoFileName: String, siblings: [String]) -> [SubtitleTrack] {
        external(videoFileName: videoFileName, filesByDirectory: ["": siblings])
    }

    /// 归一化：去标签、去语言标记、抽集数，只留字母数字与汉字。
    static func parse(_ name: String) -> (base: String, episode: Int?) {
        var stem = (name as NSString).deletingPathExtension
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)", "（[^）]*）"] {
            stem = stem.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // 语言标记先摘掉，避免 .chs 干扰集数识别与标题比较。
        // 真实库常见组合后缀：.Chs&Jap / .Cht&Jap / .Jap / .Eng；只匹配完整词，
        // 避免把 School 里的 "sc"、Match 里的 "tc" 之类误删。
        stem = stem.replacingOccurrences(
            of: "(?i)(?<![a-z0-9])(chs|cht|jpn|jap|eng|english|japanese|sc|tc|zh-hans|zh-hant|forced)(?![a-z0-9])",
            with: " ",
            options: .regularExpression
        )

        var episode: Int?
        let patterns = [
            "(?i)\\bep?\\s*0*(\\d{1,3})\\b",
            "第\\s*0*(\\d{1,3})\\s*[集话話]",
            "[\\s\\-_]0*(\\d{1,3})(?=[\\s.]|$)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
                  let range = Range(match.range(at: 1), in: stem),
                  let value = Int(stem[range]) else { continue }
            episode = value
            if let whole = Range(match.range, in: stem) {
                stem.replaceSubrange(whole, with: " ")
            }
            break
        }

        let scalars = stem.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        return (String(String.UnicodeScalarView(scalars)), episode)
    }

    private static func languageToken(of name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let suffix = stem.split(separator: ".").dropFirst().joined(separator: ".")
        return suffix.isEmpty ? stem : suffix
    }

    /// 默认选轨：在全部候选里按语言优先级取，强制轨不参与。
    public static func preferred(from tracks: [SubtitleTrack]) -> SubtitleTrack? {
        ordered(tracks, preferredLanguage: nil).first
    }

    /// 按「上次选择的语言优先，其余按简 > 繁 > 日 > 英」排序。
    public static func ordered(
        _ tracks: [SubtitleTrack],
        preferredLanguage: SubtitleLanguage?
    ) -> [SubtitleTrack] {
        tracks
            .filter { !$0.isForced }
            .enumerated()
            .sorted { lhs, rhs in
                let leftScore = score(lhs.element.language, preferred: preferredLanguage)
                let rightScore = score(rhs.element.language, preferred: preferredLanguage)
                if leftScore != rightScore { return leftScore < rightScore }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func score(
        _ language: SubtitleLanguage,
        preferred: SubtitleLanguage?
    ) -> Int {
        if let preferred, language == preferred { return -1 }
        return order(language)
    }

    /// 默认选择顺序：简体 > 繁体 > 日语 > 英语 > 未知。
    public static func order(_ language: SubtitleLanguage) -> Int {
        switch language {
        case .simplifiedChinese: 0
        case .traditionalChinese: 1
        case .japanese: 2
        case .english: 3
        case .unknown: 4
        }
    }
}
