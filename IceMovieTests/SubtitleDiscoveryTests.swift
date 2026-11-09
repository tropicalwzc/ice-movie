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
