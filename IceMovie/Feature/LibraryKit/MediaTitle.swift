import Foundation

/// 从发布用文件名中解析出的可读信息。
public struct MediaTitle: Equatable, Sendable {
    /// 去掉发布组、分辨率、编码、音轨等标记后的标题。
    public let title: String
    /// 解析到的季号；未标注时为 nil。
    public let season: Int?
    /// 解析到的集号；未标注时为 nil。使用 Double 以容纳 `24.9` 这类特别篇。
    public let episode: Double?

    public init(title: String, season: Int?, episode: Double?) {
        self.title = title
        self.season = season
        self.episode = episode
    }
}

/// 文件名标题解析与自然排序。
///
/// 目标不是完整还原发布信息，而是让网格里的标题可读，并让同一目录的集数按真实顺序排列。
public enum MediaTitleParser {
    // 标记类关键词：只要方括号组里出现，就整组丢弃。
    private static let metadataHints = [
        "1080p", "2160p", "720p", "480p", "4k", "8k", "uhd",
        "hevc", "h.265", "h265", "x265", "avc", "h.264", "h264", "x264",
        "10bit", "10-bit", "8bit", "8-bit", "ma10p", "hi10p",
        "webrip", "web-dl", "webdl", "web", "bluray", "bdrip", "bd", "remux",
        "dvdrip", "hdtv", "hdrip", "aac", "flac", "opus", "ac3", "eac3",
        "dts", "ddp", "truehd", "lpcm", "pcm", "sr", "sr t", "srt",
        "chs", "cht", "jpn", "eng", "gb", "big5", "multi-subs", "multi-subs",
        "raws", "raw", "repack", "proper", "v2",
    ]

    private static let resolutionPattern = try! NSRegularExpression(
        pattern: #"\b(?:2160p|1080p|720p|480p|360p|4K|8K|UHD)\b"#,
        options: [.caseInsensitive]
    )

    private static let codecPattern = try! NSRegularExpression(
        pattern: #"\b(?:HEVC|H\.?265|x265|AVC|H\.?264|x264|VP9|AV1)(?:[-_ ]?(?:10|8)[- ]?bit)?\b"#,
        options: [.caseInsensitive]
    )

    private static let audioPattern = try! NSRegularExpression(
        pattern: #"\b(?:AAC|FLAC|Opus|AC3|EAC3|DTS(?:[- ]?HD)?(?:[. ]?MA)?|DDP|TrueHD|LPCM|PCM)(?:[. ]?\d(?:\.\d))?\b"#,
        options: [.caseInsensitive]
    )

    private static let sourcePattern = try! NSRegularExpression(
        pattern: #"\b(?:WebRip|WEB[- ]?DL|WEB|BluRay|BDRip|BD|DVDRip|HDTV|HDRip|Remux)\b"#,
        options: [.caseInsensitive]
    )

    private static let languagePattern = try! NSRegularExpression(
        pattern: #"\b(?:CHS|CHT|JPN|ENG|GB|BIG5|SRTx?\d?|Multi[- ]?Subs?)\b"#,
        options: [.caseInsensitive]
    )

    private static let bitDepthPattern = try! NSRegularExpression(
        pattern: #"\b(?:10|8)[- ]?bit\b"#,
        options: [.caseInsensitive]
    )

    private static let seasonEnglishPattern = try! NSRegularExpression(
        pattern: #"\b(?:S(\d{1,2})|Season\s*(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)\s*Season)\b"#,
        options: [.caseInsensitive]
    )

    private static let seasonChinesePattern = try! NSRegularExpression(
        pattern: #"第\s*([0-9一二三四五六七八九十]+)\s*季"#
    )

    private static let episodePatterns: [NSRegularExpression] = [
        // 第 1 话 / 第 1 集 / 第 1 話
        try! NSRegularExpression(pattern: #"第\s*(\d{1,4}(?:\.\d)?)\s*[话話集]"#),
        // S01E02 / E02 / EP02
        try! NSRegularExpression(pattern: #"(?:^|[\s\[\(])(?:S\d{1,2})?E(?:P)?\s*(\d{1,4}(?:\.\d)?)v?\d*(?=$|[\s\]\)])"#, options: [.caseInsensitive]),
        // " - 01" / "_01" / " 01 "（排除分辨率与年份）
        try! NSRegularExpression(pattern: #"(?:^|[\s_])[-–—]\s*(\d{1,3}(?:\.\d)?)v?\d*(?=$|[\s\[\(\.])"#),
        // [01] / (01)
        try! NSRegularExpression(pattern: #"[\[\(]\s*(\d{1,3}(?:\.\d)?)v?\d*\s*[\]\)]"#),
    ]

    private static let episodeMarkerPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"第\s*\d{1,4}(?:\.\d)?\s*[话話集]"#),
        try! NSRegularExpression(pattern: #"(?:^|[\s\[\(])(?:S\d{1,2})?E(?:P)?\s*\d{1,4}(?:\.\d)?v?\d*(?=$|[\s\]\)])"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"(?:^|[\s_])[-–—]\s*\d{1,3}(?:\.\d)?v?\d*(?=$|[\s\[\(\.])"#),
        try! NSRegularExpression(pattern: #"[\[\(]\s*\d{1,3}(?:\.\d)?v?\d*\s*[\]\)]"#),
    ]

    public static func parse(_ rawName: String) -> MediaTitle {
        let rawBase = (rawName as NSString).deletingPathExtension
        // `_yyyyMMddHHmmss` 紧跟在集号后会让 `Show - 01_2024...` 的集号解析失败；
        // 先去掉合法拍摄时间后缀，再提取标题与季集。
        let base = removingCaptureTimestamp(rawBase, rawName: rawName)
        guard !base.isEmpty else {
            return MediaTitle(title: rawName, season: nil, episode: nil)
        }

        let season = parseSeason(base)
        let episode = parseEpisode(base)
        var working = removeBracketGroups(from: base)

        for pattern in episodeMarkerPatterns {
            working = pattern.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: " "
            )
        }

        for pattern in [
            resolutionPattern, codecPattern, audioPattern,
            sourcePattern, languagePattern, bitDepthPattern,
        ] {
            working = pattern.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: " "
            )
        }

        working = working
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-–—_[]()【】"))

        let fallback = base
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let title = working.isEmpty ? fallback : working

        return MediaTitle(title: title, season: season, episode: episode)
    }

    /// 播放页标题：集数追加在末尾，长标题从头部截断时仍能保留「第几集」。
    public static func playbackTitle(for rawName: String) -> String {
        let parsed = parse(rawName)
        guard let episode = parsed.episode else { return parsed.title }
        let formatted = episode.rounded() == episode
            ? String(Int(episode))
            : String(format: "%.1f", episode)
        return "\(parsed.title) · 第 \(formatted) 集"
    }

    /// 目录路径的展示清理：逐级去掉发布组与元信息标签。
    public static func directoryPathDisplay(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { directoryDisplayName(String($0)) }
            .joined(separator: "/")
    }

    // MARK: - 季集

    private static func parseSeason(_ text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = seasonEnglishPattern.firstMatch(in: text, range: range) {
            for index in 1...3 {
                let captured = match.range(at: index)
                if captured.location != NSNotFound,
                   let value = Int((text as NSString).substring(with: captured)) {
                    return value
                }
            }
        }
        if let match = seasonChinesePattern.firstMatch(in: text, range: range) {
            let captured = match.range(at: 1)
            if captured.location != NSNotFound {
                let raw = (text as NSString).substring(with: captured)
                return chineseNumber(raw)
            }
        }
        return nil
    }

    private static func removingCaptureTimestamp(
        _ base: String,
        rawName: String
    ) -> String {
        guard PhotoTimestampParser.parse(filename: rawName) != nil,
              let underscore = base.lastIndex(of: "_") else {
            return base
        }
        return String(base[..<underscore])
    }

    private static func parseEpisode(_ text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in episodePatterns {
            guard let match = pattern.firstMatch(in: text, range: range) else { continue }
            let captured = match.range(at: 1)
            guard captured.location != NSNotFound else { continue }
            let raw = (text as NSString).substring(with: captured)
            if let value = Double(raw) {
                return value
            }
        }
        return nil
    }

    private static func chineseNumber(_ raw: String) -> Int? {
        if let value = Int(raw) { return value }
        let digits: [Character: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        if raw.count == 1, let value = digits[raw.first!] { return value }
        if raw == "十" { return 10 }
        if raw.hasPrefix("十"), let unit = raw.last.flatMap({ digits[$0] }) { return 10 + unit }
        if raw.hasSuffix("十"), let tens = raw.first.flatMap({ digits[$0] }) { return tens * 10 }
        if raw.count == 2,
           let tens = digits[raw.first!],
           let units = digits[raw.last!],
           raw.contains("十") == false,
           raw.first != "十" {
            return tens * 10 + units
        }
        if raw.count == 3, raw.dropFirst().first == "十",
           let tens = digits[raw.first!], let units = digits[raw.last!] {
            return tens * 10 + units
        }
        return nil
    }

    // MARK: - 方括号

    /// 丢弃发布组与元信息方括号组，保留可能属于作品名的组。
    private static func removeBracketGroups(from text: String) -> String {
        var result = text
        let patterns = [
            #"\[[^\[\]]*\]"#,
            #"【[^【】]*】"#,
            #"\([^()]*\)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            // 从后往前替换，避免位置失效。
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let content = String(result[range])
                let inner = String(content.dropFirst().dropLast())
                let isLeadingGroup = match.range.location == 0
                let isMetadata = isMetadataGroup(inner)
                // 番剧发布常见的 8 位 CRC，如 `(1A9723D4)`；它不是标题的一部分。
                let isCRC = inner.count == 8 && inner.allSatisfy(\.isHexDigit)
                if isLeadingGroup || isMetadata || isCRC {
                    result.replaceSubrange(range, with: " ")
                }
            }
        }
        // 保留的作品名组可能自带方括号，如 `[CLANNAD-AfterStory-]`；
        // 去掉括号后再交给标题清理，避免每集标题因括号位置不同而分组失败。
        return result
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "【", with: " ")
            .replacingOccurrences(of: "】", with: " ")
    }

    private static func isMetadataGroup(_ inner: String) -> Bool {
        let lowered = inner.lowercased()
        if metadataHints.contains(where: { lowered.contains($0) }) { return true }
        if ["中文字幕", "简繁", "双语", "国日", "多音轨", "国语", "日语", "内封", "外挂"].contains(where: { inner.contains($0) }) {
            return true
        }
        // 纯数字或集数范围：[01]、[01-12]、[12v2]
        let stripped = lowered.trimmingCharacters(in: CharacterSet(charactersIn: " 0123456789-_.v"))
        return stripped.isEmpty
    }

    /// 目录名的展示清理：去掉发布组与元信息标签，但保留目录本身的含义（如 `- Sub`）。
    public static func directoryDisplayName(_ rawName: String) -> String {
        var working = removeBracketGroups(from: rawName)
        for pattern in [
            resolutionPattern, codecPattern, audioPattern,
            sourcePattern, languagePattern, bitDepthPattern,
        ] {
            working = pattern.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: " "
            )
        }
        working = working
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "【", with: " ")
            .replacingOccurrences(of: "】", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return working.isEmpty ? rawName : working
    }
}

/// 网格内的稳定排序：目录在前，视频按集号自然排序，图片按原始文件名自然排序，文档最后。
public enum MediaOrdering {
    private struct EpisodeRank {
        let title: String
        let season: Int
        let episode: Double
    }

    public static func sorted(_ entries: [MediaEntry]) -> [MediaEntry] {
        // 多集剧集目录按集数升序，集号覆盖拍摄时间；单集/照片目录保持时间倒序。
        guard usesEpisodeOrder(entries) else {
            return entries.sorted(by: areInIncreasingOrder)
        }
        return entries.sorted(by: episodeFirstOrder)
    }

    /// 至少两条视频解析出集号，且至少两条共享同一解析标题，才判定为多集目录。
    /// 避免把普通视频或单条带数字的文件误判成剧集。
    private static func usesEpisodeOrder(_ entries: [MediaEntry]) -> Bool {
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let rank = episodeRank(entry) else { continue }
            let key = rank.title.lowercased()
            let count = (counts[key] ?? 0) + 1
            if count >= 2 { return true }
            counts[key] = count
        }
        return false
    }

    private static func episodeRank(_ entry: MediaEntry) -> EpisodeRank? {
        guard entry.kind == .video else { return nil }
        let parsed = MediaTitleParser.parse(entry.name)
        guard let episode = parsed.episode else { return nil }
        return EpisodeRank(
            title: comparisonKey(entry),
            season: parsed.season ?? 0,
            episode: episode
        )
    }

    /// 剧集优先总序：目录 → 剧集（标题、季、集升序）→ 非剧集媒体（原时间排序）→ 文档。
    /// 分块比较避免逐对忽略时间造成的排序环。
    private static func episodeFirstOrder(_ lhs: MediaEntry, _ rhs: MediaEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        if lhs.isDocument != rhs.isDocument {
            return !lhs.isDocument
        }
        if lhs.isDocument, rhs.isDocument {
            return compareNames(lhs, rhs)
        }

        switch (episodeRank(lhs), episodeRank(rhs)) {
        case let (left?, right?):
            if left.title != right.title {
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
            if left.season != right.season {
                return left.season < right.season
            }
            if left.episode != right.episode {
                return left.episode < right.episode
            }
            return compareNames(lhs, rhs)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return areInIncreasingOrder(lhs, rhs)
        }
    }

    public static func areInIncreasingOrder(_ lhs: MediaEntry, _ rhs: MediaEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        // 文档排在媒体之后，避免资料文件插进剧集/照片列表；文档内部按文件名自然排序。
        if lhs.isDocument != rhs.isDocument {
            return !lhs.isDocument
        }
        if lhs.isDocument, rhs.isDocument {
            return compareNames(lhs, rhs)
        }
        // 文件名带拍摄时间时，最新的媒体排在前面；无时间戳的排在后面。
        let leftTimestamp = lhs.captureTimestamp
        let rightTimestamp = rhs.captureTimestamp
        if leftTimestamp != nil || rightTimestamp != nil {
            switch (leftTimestamp, rightTimestamp) {
            case let (left?, right?):
                if left != right { return left > right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
        }
        // 先按展示标题比较，图片与视频混排时才能保持严格弱序；
        // 下划线视作空格，避免 `IMG_0001` 与 `IMG 0002` 因标点顺序颠倒。
        let compared = comparisonKey(lhs).localizedStandardCompare(comparisonKey(rhs))
        if compared != .orderedSame {
            return compared == .orderedAscending
        }
        // 标题相同后使用与“比较双方类型”无关的稳定键：季 → 集 → 文件名 → 路径。
        // 非视频使用固定哨兵值，保证同标题的图片与视频之间也只有一种比较结果。
        let leftKey = tieBreakKey(lhs)
        let rightKey = tieBreakKey(rhs)
        if leftKey.season != rightKey.season {
            return leftKey.season < rightKey.season
        }
        if leftKey.episode != rightKey.episode {
            return leftKey.episode < rightKey.episode
        }
        return compareNames(lhs, rhs)
    }

    /// 所有条目共用的平局键。视频使用解析出的季/集，其他条目使用哨兵值。
    private static func tieBreakKey(_ entry: MediaEntry) -> (season: Int, episode: Double) {
        guard !entry.isImage, !entry.isDirectory else {
            return (Int.max, .greatestFiniteMagnitude)
        }
        let parsed = MediaTitleParser.parse(entry.name)
        return (parsed.season ?? 0, parsed.episode ?? .greatestFiniteMagnitude)
    }

    private static func displayKey(_ entry: MediaEntry) -> String {
        if entry.isDirectory { return entry.name }
        if let image = ImageMetadata(entry: entry) { return image.title }
        return MediaTitleParser.parse(entry.name).title
    }

    private static func comparisonKey(_ entry: MediaEntry) -> String {
        displayKey(entry).replacingOccurrences(of: "_", with: " ")
    }

    private static func compareNames(_ lhs: MediaEntry, _ rhs: MediaEntry) -> Bool {
        let compared = lhs.name.localizedStandardCompare(rhs.name)
        if compared != .orderedSame {
            return compared == .orderedAscending
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}
