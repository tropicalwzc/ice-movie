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
        let base = (rawName as NSString).deletingPathExtension
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
                let inner = content.dropFirst().dropLast()
                let isLeadingGroup = match.range.location == 0
                let isMetadata = isMetadataGroup(String(inner))
                if isLeadingGroup || isMetadata {
                    result.replaceSubrange(range, with: " ")
                }
            }
        }
        return result
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

/// 网格内的稳定排序：目录在前，视频按集号自然排序，其余按标题。
public enum MediaOrdering {
    public static func sorted(_ entries: [MediaEntry]) -> [MediaEntry] {
        entries.sorted(by: areInIncreasingOrder)
    }

    public static func areInIncreasingOrder(_ lhs: MediaEntry, _ rhs: MediaEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        if !lhs.isDirectory {
            let left = MediaTitleParser.parse(lhs.name)
            let right = MediaTitleParser.parse(rhs.name)
            if let le = left.episode, let re = right.episode, le != re {
                if left.season == right.season || left.season == nil || right.season == nil {
                    return le < re
                }
            }
        }
        let leftTitle = lhs.isDirectory ? lhs.name : MediaTitleParser.parse(lhs.name).title
        let rightTitle = rhs.isDirectory ? rhs.name : MediaTitleParser.parse(rhs.name).title
        let compared = leftTitle.localizedStandardCompare(rightTitle)
        if compared != .orderedSame {
            return compared == .orderedAscending
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
