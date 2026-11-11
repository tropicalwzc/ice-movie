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
    /// 判定“同目录还有哪些视频”用的扩展名集合，供一一对应消歧。
    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "ts", "m2ts", "mov", "webm", "flv", "wmv", "rmvb", "mpg", "mpeg",
    ]

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
    /// 真实库里字幕名往往和视频名不同：视频带 `[Kamigami]`、`[BD 1080p x265]`、
    /// `[YYDM-11FNAS]` 这类标签，字幕常省掉标签甚至换成另一种语言的标题。
    /// 因此匹配分三层，按可信度从高到低：
    /// 1) 归一化标题完全一致（两侧都为空时不算命中——全方括号命名的标题干
    ///    恒为空，据此放行等于按集数盲配；只有纯集数命名才退化为集数对齐）；
    /// 2) 标题词元模糊重合 ≥60%（括号内的作品名也参与，标签词被剔除）；
    /// 3) 一一对应：同目录同集数的视频只有本片、同集数字幕只有一套时，
    ///    允许标题完全对不上——字幕与剧集一一对应时这就是最强的信号。
    /// 季数/集数任何一侧能比且不一致则直接否决，避免错配别的集。
    public static func external(
        videoFileName: String,
        filesByDirectory: [String: [String]]
    ) -> [SubtitleTrack] {
        let video = signature(videoFileName)
        var tracks: [SubtitleTrack] = []

        for (directory, names) in filesByDirectory {
            // “一一对应”消歧需要同目录的视频清单；字幕子目录里没有视频时该规则自动失效。
            let videosInDirectory = names.filter {
                videoExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }
            let episodesInDirectory = videosInDirectory.map { signature($0).episode }
            let videosWithSameEpisode = video.episode.map { target in
                episodesInDirectory.filter { $0 == target }.count
            } ?? 0
            // “同集字幕有几套”必须按能区分作品的特征去重。全方括号命名
            // （[A][Show][10]、[B][Other][10]）归一化后标题干是空串，直接拿
            // base 去重会把不同作品合并成一套，让下面的一一对应规则误判为
            // 唯一，从而把别的作品的同集字幕也放进来。用 identityKey 回退。
            var subtitleSetsWithSameEpisode: Set<String> = []
            for name in names {
                let ext = (name as NSString).pathExtension.lowercased()
                guard subtitleExtensions.contains(ext) else { continue }
                let parsed = signature(name)
                if let episode = parsed.episode, episode == video.episode {
                    subtitleSetsWithSameEpisode.insert(identityKey(name, signature: parsed))
                }
            }
            let subtitleSetCount = subtitleSetsWithSameEpisode.count

            for name in names {
                let ext = (name as NSString).pathExtension.lowercased()
                guard subtitleExtensions.contains(ext) else { continue }

                let parsed = signature(name)
                guard matches(
                    video: video,
                    candidate: parsed,
                    videosWithSameEpisode: videosWithSameEpisode,
                    subtitleSetsWithSameEpisode: subtitleSetCount
                ) else { continue }

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

    /// 匹配用的归一化特征：标题干、集数、季数、标题词元。
    struct Signature {
        var base: String
        /// 集数允许小数：动画常见 17.5、13.5 这类总集篇/特别篇编号。
        /// 与 `MediaTitleParser` 的 `episode: Double?` 保持一致。
        var episode: Double?
        var season: Int?
        var tokens: Set<String>
    }

    static func signature(_ name: String) -> Signature {
        let parsed = parse(name)
        return Signature(
            base: parsed.base,
            episode: parsed.episode,
            season: season(of: name),
            tokens: titleTokens(of: name)
        )
    }

    /// 候选字幕是否属于这个视频。判定顺序见 `external` 的说明。
    static func matches(
        video: Signature,
        candidate: Signature,
        videosWithSameEpisode: Int,
        subtitleSetsWithSameEpisode: Int
    ) -> Bool {
        if let a = video.season, let b = candidate.season, a != b { return false }
        if let a = video.episode, let b = candidate.episode, a != b { return false }

        if !candidate.base.isEmpty, candidate.base == video.base { return true }
        // 两侧都没有标题干时不能一律按集数放行：全方括号命名（[YYDM][Artist][10]）
        // 归一化后 base 恒为空，但文件名里其实带着作品名词元，无条件放行会让
        // 同目录另一部作品的同集字幕混进来。只有双方都拿不到任何标题信息
        // （EP01.mkv 对 ep01.chs.ass 这种纯集数命名）时，集数才是唯一信号。
        if candidate.base.isEmpty, video.base.isEmpty,
           candidate.tokens.isEmpty, candidate.tokens.isEmpty,
           video.episode != nil, candidate.episode != nil {
            return true
        }

        if tokenOverlap(video.tokens, candidate.tokens) >= 0.6 {
            // 视频集数解析不出来时（SP1、OVA、未识别的编号），词元一致会把
            // 同作品所有集数的字幕都吞进来——真实库出现过第 17.5 集把 59 条
            // 跨集字幕全部匹配上的情况。这种没有集数约束的匹配必须要求候选
            // 同样不带集数标记，才允许放行。
            if video.episode == nil, candidate.episode != nil { return false }
            return true
        }

        if let episode = video.episode, candidate.episode == episode,
           videosWithSameEpisode == 1, subtitleSetsWithSameEpisode == 1 {
            return true
        }
        return false
    }

    /// 字幕“套数”的去重键：用来判断同目录同集字幕是否只有一套。
    ///
    /// `base` 只在文件里有括号外标题时才非空；全方括号命名（真实库的动画、
    /// 压制组资源）归一化后恒为空串，拿它去重会把不同作品合成一套。此时
    /// 回退到标题词元集合，再退到去掉语言标记的文件名主干：
    /// - `[A][Show][10].ass` 与 `[B][OtherShow][10].ass` → 词元不同 → 两套（消歧失效）
    /// - `[A][Show][10].chs.ass` 与 `[B][Show][10].cht.ass` → 词元相同 → 一套（同作品不同语言）
    static func identityKey(_ name: String, signature parsed: Signature) -> String {
        if !parsed.base.isEmpty { return "base:\(parsed.base)" }
        if !parsed.tokens.isEmpty {
            return "tokens:" + parsed.tokens.sorted().joined(separator: "|")
        }
        // 既无标题干也无词元（纯集数、纯标签命名）：退回去掉语言标记的文件名主干，
        // 让 10.chs.ass 与 10.cht.ass 仍归为同一套。
        let stem = (name as NSString).deletingPathExtension
        let cleaned = stem.replacingOccurrences(
            of: languageTokenPattern,
            with: " ",
            options: .regularExpression
        )
        return "stem:" + cleaned.lowercased().trimmingCharacters(in: .whitespaces)
    }

    static func identityKey(_ name: String) -> String {
        identityKey(name, signature: signature(name))
    }

    /// 词元重合度：交集 / 较少一侧的词数；任一侧没有词元时按 0 处理。
    static func tokenOverlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let denominator = min(a.count, b.count)
        guard denominator > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(denominator)
    }

    /// 季数：`S02E05` / `第2季` / `Season 2`；识别不到时为 nil，不参与否决。
    static func season(of name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        let patterns = [
            "(?i)\\bs(\\d{1,2})e\\d{1,3}\\b",
            "第\\s*(\\d{1,2})\\s*季",
            "(?i)season\\s*(\\d{1,2})",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
                  let range = Range(match.range(at: 1), in: stem),
                  let value = Int(stem[range]) else { continue }
            return value
        }
        return nil
    }

    /// 语言/来源标记的完整词匹配，parse 与 identityKey 共用，避免两处规则漂移。
    /// 只匹配完整词，避免把 School 里的 "sc"、Match 里的 "tc" 之类误删。
    private static let languageTokenPattern =
        "(?i)(?<![a-z0-9])(chs|cht|jpn|jap|eng|english|japanese|sc|tc|zh-hans|zh-hant|forced)(?![a-z0-9])"

    /// 不参与标题匹配的常见标签/语言/来源词。含数字的标签
    /// （720P、X264、AB43189A、11FNAS 等）在词元阶段已按“含数字”剔除。
    private static let tagStopWords: Set<String> = [
        "bd", "bdrip", "bdmv", "web", "webdl", "webrip", "hdtv", "dvdrip", "remux",
        "avc", "hevc", "aac", "flac", "ac3", "eac3", "dts", "dtshd", "ddp", "dd", "opus", "mp3", "ma",
        "hi", "bit", "chs", "cht", "jpn", "jap", "eng", "english", "japanese", "chinese",
        "gb", "big5", "sc", "tc", "zh", "hans", "hant",
        "end", "sp", "ova", "oad", "movie", "nc", "op", "ed", "pv", "cm", "repack", "proper",
        "sub", "subs", "subtitle", "subtitles", "ass", "srt", "font", "fonts",
    ]

    /// 标题词元：括号外文本与括号内文本都参与（全方括号命名时作品名只在括号里），
    /// 剔除含数字的标签、语言标记与常见封装词，只留能代表作品名的词。
    static func titleTokens(of name: String) -> Set<String> {
        let stem = (name as NSString).deletingPathExtension
        var chunks: [String] = []
        var outside = stem
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]") {
            let whole = NSRange(stem.startIndex..., in: stem)
            for match in regex.matches(in: stem, range: whole) {
                if let range = Range(match.range(at: 1), in: stem) {
                    chunks.append(String(stem[range]))
                }
            }
            outside = regex.stringByReplacingMatches(in: stem, range: whole, withTemplate: " ")
        }
        chunks.append(outside)

        var tokens: Set<String> = []
        for chunk in chunks {
            for word in chunk.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let token = String(word)
                guard !token.contains(where: \.isNumber) else { continue }
                guard !tagStopWords.contains(token) else { continue }
                // 单字符只在是汉字时保留（K-ON 这类英文单字母两侧都会被同样丢弃，不影响重合度）。
                guard token.count > 1 || token.unicodeScalars.contains(where: {
                    (0x4E00...0x9FFF).contains($0.value)
                }) else { continue }
                tokens.insert(token)
            }
        }
        return tokens
    }

    /// 归一化：去标签、去语言标记、抽集数，只留字母数字与汉字。
    ///
    /// 集数用 `Double`：动画里 17.5、13.5 这类总集篇/特别篇编号很常见，
    /// 用整数会把它们解析成 nil，进而让集数否决失效（同作品任意集数的字幕
    /// 都会被词元规则匹配上）。取值规则与 `MediaTitleParser` 对齐。
    static func parse(_ name: String) -> (base: String, episode: Double?) {
        var stem = (name as NSString).deletingPathExtension
        var episode: Double?
        // 集数可能整个包在方括号里（[YYDM-11FNAS][Angel Beats][10][BDRIP]…）。
        // 必须在去括号之前抽取：否则 [10] 会被整段删掉，集数丢失、标题也只剩
        // 空串，这类全方括号命名的视频永远匹配不上外挂字幕（真实库很常见）。
        if let regex = try? NSRegularExpression(
            pattern: "\\[0*(\\d{1,3}(?:\\.\\d{1,2})?)(?:v\\d+)?\\]"
        ),
           let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let range = Range(match.range(at: 1), in: stem) {
            episode = Double(stem[range])
        }
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)", "（[^）]*）"] {
            stem = stem.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // 语言标记先摘掉，避免 .chs 干扰集数识别与标题比较。
        // 真实库常见组合后缀：.Chs&Jap / .Cht&Jap / .Jap / .Eng。
        stem = stem.replacingOccurrences(
            of: languageTokenPattern,
            with: " ",
            options: .regularExpression
        )

        // 方括号里已经抽到集数就不再兜底，避免 "- 10" 之外再误命中别的数字。
        if episode == nil {
            // S02E05 这类美剧命名：集数在 E 后面，且整段含数字会被词元阶段剔除，
            // 必须先抽出来，否则 S02E05 与 S02E06 会因词元完全一致而错配。
            if let regex = try? NSRegularExpression(
                pattern: "(?i)\\bs\\d{1,2}e0*(\\d{1,3}(?:\\.\\d{1,2})?)\\b"
            ),
               let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
               let range = Range(match.range(at: 1), in: stem),
               let value = Double(stem[range]) {
                episode = value
                if let whole = Range(match.range, in: stem) {
                    stem.replaceSubrange(whole, with: " ")
                }
            }
        }
        if episode == nil {
            let patterns = [
                "(?i)\\bep?\\s*0*(\\d{1,3}(?:\\.\\d{1,2})?)\\b",
                "第\\s*0*(\\d{1,3}(?:\\.\\d{1,2})?)\\s*[集话話]",
                "[\\s\\-_]0*(\\d{1,3}(?:\\.\\d{1,2})?)(?=[\\s.]|$)",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
                      let range = Range(match.range(at: 1), in: stem),
                      let value = Double(stem[range]) else { continue }
                episode = value
                if let whole = Range(match.range, in: stem) {
                    stem.replaceSubrange(whole, with: " ")
                }
                break
            }
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
