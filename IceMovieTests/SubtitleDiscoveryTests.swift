import XCTest
@testable import SubtitleKit

/// 7.7 的字幕纯逻辑部分：语言后缀解析、外挂匹配、默认顺序。
final class SubtitleDiscoveryTests: XCTestCase {
    func testLanguageSuffixParsing() {
        XCTAssertEqual(SubtitleLanguage.detect(from: ".chs"), .simplifiedChinese)
        XCTAssertEqual(SubtitleLanguage.detect(from: ".cht"), .traditionalChinese)
        XCTAssertEqual(SubtitleLanguage.detect(from: ".jpn"), .japanese)
        XCTAssertEqual(SubtitleLanguage.detect(from: ".eng"), .english)
        XCTAssertEqual(SubtitleLanguage.detect(from: "zh-hans"), .simplifiedChinese)
        XCTAssertEqual(SubtitleLanguage.detect(from: "zh-hant"), .traditionalChinese)
        XCTAssertEqual(SubtitleLanguage.detect(from: ""), .unknown)
        XCTAssertEqual(SubtitleLanguage.detect(from: ".sc"), .simplifiedChinese)
        XCTAssertEqual(SubtitleLanguage.detect(from: ".tc"), .traditionalChinese)
    }

    func testExternalMatchingPicksSameBaseOnly() {
        let video = "[LoliHouse] Kono Kaisha - 06 [1080p].mkv"
        let siblings = [
            "[LoliHouse] Kono Kaisha - 06 [1080p].chs.ass",
            "[LoliHouse] Kono Kaisha - 06 [1080p].cht.ass",
            "[LoliHouse] Kono Kaisha - 06 [1080p].jpn.srt",
            "[LoliHouse] Kono Kaisha - 07 [1080p].chs.ass",
            "readme.txt",
        ]
        let tracks = SubtitleDiscovery.external(videoFileName: video, siblings: siblings)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.map(\.language), [.simplifiedChinese, .traditionalChinese, .japanese])
        XCTAssertEqual(tracks.first?.format, .ass)
        XCTAssertEqual(tracks.last?.format, .srt)
    }

    func testExternalMatchingIsCaseInsensitive() {
        let tracks = SubtitleDiscovery.external(
            videoFileName: "EP01.MKV",
            siblings: ["ep01.CHS.ASS"]
        )
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.language, .simplifiedChinese)
    }

    func testDefaultOrderPrefersSimplified() {
        XCTAssertLessThan(
            SubtitleDiscovery.order(.simplifiedChinese),
            SubtitleDiscovery.order(.traditionalChinese)
        )
        XCTAssertLessThan(
            SubtitleDiscovery.order(.traditionalChinese),
            SubtitleDiscovery.order(.japanese)
        )
    }

    func testEmbeddedBitmapCodecsAreMarkedBitmap() {
        let tracks = SubtitleDiscovery.embedded([
            .init(streamIndex: 1, codec: "hdmv_pgs_subtitle", title: "PGS"),
            .init(streamIndex: 2, codec: "dvd_subtitle", title: "VobSub"),
            .init(streamIndex: 3, codec: "subrip", title: "SRT"),
            .init(streamIndex: 4, codec: "ass", title: "ASS"),
            .init(streamIndex: 5, codec: "mov_text", title: "MOV"),
        ])
        XCTAssertEqual(tracks.first { $0.source == .embedded(streamIndex: 1) }?.format, .bitmap)
        XCTAssertEqual(tracks.first { $0.source == .embedded(streamIndex: 2) }?.format, .bitmap)
        XCTAssertEqual(tracks.first { $0.source == .embedded(streamIndex: 3) }?.format, .srt)
        XCTAssertEqual(tracks.first { $0.source == .embedded(streamIndex: 4) }?.format, .ass)
        XCTAssertEqual(tracks.first { $0.source == .embedded(streamIndex: 5) }?.format, .other)
    }

    func testExternalSupIsMarkedBitmap() {
        let tracks = SubtitleDiscovery.external(
            videoFileName: "movie.mkv",
            siblings: ["movie.chs.sup"]
        )
        XCTAssertEqual(tracks.first?.format, .bitmap)
    }

    /// 真实库回归：集数整个包在方括号里（[YYDM-11FNAS][Angel Beats][10][BDRIP]…）。
    /// 去括号先于抽集数会把 [10] 删掉，导致全方括号命名永远匹配不上外挂字幕。
    func testFullyBracketedNamesMatchByEpisode() {
        let video = "[YYDM-11FNAS][Angel Beats][10][BDRIP][720P][X264-10bit_AAC][AB43189A].mp4"
        let siblings = [
            "[YYDM-11FNAS][Angel Beats][10][BDRIP][720P][X264-10bit_AAC][AB43189A].ass",
            "[YYDM-11FNAS][Angel Beats][11][BDRIP][720P][X264-10bit_AAC][AB43189A].ass",
        ]
        XCTAssertEqual(SubtitleDiscovery.parse(video).episode, 10)
        let tracks = SubtitleDiscovery.external(videoFileName: video, siblings: siblings)
        XCTAssertEqual(tracks.count, 1, "只应匹配第 10 集")
        XCTAssertTrue(tracks.first?.title.contains("[10]") == true)
    }

    /// 方括号命名的视频 + 省略标签的字幕名（Angel Beats - 10.chs.ass）也要能对上。
    func testBracketedVideoMatchesPlainNamedSubtitle() {
        let video = "[YYDM-11FNAS][Angel Beats][10][BDRIP][720P][X264-10bit_AAC][AB43189A].mp4"
        let tracks = SubtitleDiscovery.external(
            videoFileName: video,
            siblings: ["Angel Beats - 10.chs.ass", "Angel Beats - 11.chs.ass"]
        )
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.language, .simplifiedChinese)
    }

    /// 词元模糊匹配：视频与字幕的分组标签不同（[YYDM] vs [Kamigami]），
    /// 但作品名一致时应能匹配上。
    func testFuzzyTokenMatchIgnoresGroupTags() {
        let video = "[YYDM-11FNAS][Angel Beats][10][BDRIP][720P][X264-10bit_AAC][AB43189A].mp4"
        let tracks = SubtitleDiscovery.external(
            videoFileName: video,
            siblings: ["[Kamigami] Angel Beats - 10 [BD 1080p].ass"]
        )
        XCTAssertEqual(tracks.count, 1)
    }

    /// 一一对应：同目录同集数视频唯一、同集数字幕唯一时，标题完全对不上也应匹配
    ///（字幕用中文标题、视频用英文标题的真实场景）。
    func testOneToOneDisambiguationMatchesForeignTitle() {
        let video = "[YYDM-11FNAS][Angel Beats][10][BDRIP][720P].mp4"
        let tracks = SubtitleDiscovery.external(
            videoFileName: video,
            siblings: ["[YYDM-11FNAS][Angel Beats][10][BDRIP][720P].mp4", "天使的脉动 - 10.chs.ass"]
        )
        XCTAssertEqual(tracks.count, 1)
    }

    /// 反例：同目录有多个同集数视频时，“一一对应”失效，不能盲目匹配无关字幕。
    func testOneToOneDisabledWhenAmbiguous() {
        let video = "ShowA - 10.mkv"
        let tracks = SubtitleDiscovery.external(
            videoFileName: video,
            siblings: ["ShowA - 10.mkv", "ShowB - 10.mkv", "ShowC - 10.chs.ass"]
        )
        XCTAssertTrue(tracks.isEmpty, "同集数视频不唯一，不应匹配无关字幕")
    }

    /// 季数不一致时直接否决，避免跨季错配。
    func testSeasonMismatchRejected() {
        let tracks = SubtitleDiscovery.external(
            videoFileName: "Some Show S02E05 [1080p].mkv",
            siblings: ["Some Show S01E05.chs.ass", "Some Show S02E05.chs.ass"]
        )
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(tracks.first?.title.contains("S02E05") == true)
    }

    /// SxxExx 命名同季不同集不能互相匹配（集数在 E 后面，词元会被剔除）。
    func testSameSeasonDifferentEpisodeRejected() {
        let tracks = SubtitleDiscovery.external(
            videoFileName: "Some Show S02E05 [1080p].mkv",
            siblings: ["Some Show S02E06.chs.ass"]
        )
        XCTAssertTrue(tracks.isEmpty)
    }
}

/// 7.1b：真实库结构（字幕在 `- Sub` 子目录、文件名与视频不同）。
extension SubtitleDiscoveryTests {
    func testRealWorldSubFolderNaming() {
        let video = "[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        let files = [
            "": ["[Kamigami] Kaze ga Tsuyoku Fuiteiru - 02 [BD 1080p x265 Ma10p AAC].mkv"],
            "[Kamigami] Kaze ga Tsuyoku Fuiteiru - Sub": [
                "Kaze ga Tsuyoku Fuiteiru 01.chs.ass",
                "Kaze ga Tsuyoku Fuiteiru 01.cht.ass",
                "Kaze ga Tsuyoku Fuiteiru 01.jpn.ass",
                "Kaze ga Tsuyoku Fuiteiru 02.chs.ass",
            ],
        ]
        let tracks = SubtitleDiscovery.external(videoFileName: video, filesByDirectory: files)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.map(\.language), [.simplifiedChinese, .traditionalChinese, .japanese])
        XCTAssertTrue(tracks.allSatisfy { $0.format == .ass })
    }

    func testParseExtractsEpisodeAndStripsTags() {
        let a = SubtitleDiscovery.parse("[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p].mkv")
        let b = SubtitleDiscovery.parse("Kaze ga Tsuyoku Fuiteiru 01.chs.ass")
        XCTAssertEqual(a.base, b.base)
        XCTAssertEqual(a.episode, 1)
        XCTAssertEqual(b.episode, 1)
    }

    func testSubtitleDirectoryDetection() {
        XCTAssertTrue(SubtitleDiscovery.isSubtitleDirectory("- Sub"))
        XCTAssertTrue(SubtitleDiscovery.isSubtitleDirectory("字幕"))
        XCTAssertFalse(SubtitleDiscovery.isSubtitleDirectory("Bonus"))
    }

    func testJapSuffixAndWordBoundaries() {
        XCTAssertEqual(SubtitleLanguage.detect(from: "01.Jap"), .japanese)
        XCTAssertEqual(
            SubtitleDiscovery.parse("School Days 01.mkv").base,
            SubtitleDiscovery.parse("School Days 01.sc.ass").base
        )
    }

    func testOrderedSelectionPrefersLastLanguageAndSkipsForced() {
        let tracks = [
            SubtitleTrack(source: .embedded(streamIndex: 1), title: "chs", language: .simplifiedChinese, format: .ass),
            SubtitleTrack(source: .embedded(streamIndex: 2), title: "cht", language: .traditionalChinese, format: .ass),
            SubtitleTrack(source: .embedded(streamIndex: 3), title: "jpn", language: .japanese, format: .ass),
            SubtitleTrack(source: .embedded(streamIndex: 4), title: "eng", language: .english, format: .ass),
            SubtitleTrack(
                source: .embedded(streamIndex: 5),
                title: "forced",
                language: .english,
                format: .ass,
                isForced: true
            ),
        ]
        let ordered = SubtitleDiscovery.ordered(tracks, preferredLanguage: .traditionalChinese)
        XCTAssertEqual(ordered.map(\.language), [
            .traditionalChinese, .simplifiedChinese, .japanese, .english,
        ])
        XCTAssertFalse(ordered.contains { $0.isForced })
    }
}
