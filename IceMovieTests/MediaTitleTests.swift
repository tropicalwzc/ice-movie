import MediaLibraryKit
import XCTest

final class MediaTitleTests: XCTestCase {
    func testLoliHouseSeasonWithoutEpisode() {
        let parsed = MediaTitleParser.parse(
            "[LoliHouse] Tensei Shitara Slime Datta Ken 2nd Season [WebRip 1080p HEVC-10bit AAC]"
        )
        XCTAssertEqual(parsed.title, "Tensei Shitara Slime Datta Ken 2nd Season")
        XCTAssertEqual(parsed.season, 2)
        XCTAssertNil(parsed.episode)
    }

    func testLoliHouseEpisodeAndMetadataRemoval() {
        let parsed = MediaTitleParser.parse(
            "[LoliHouse] Tensei Shitara Slime Datta Ken 2nd Season - 25 [WebRip 1080p HEVC-10bit AAC SRTx3]"
        )
        XCTAssertEqual(parsed.title, "Tensei Shitara Slime Datta Ken 2nd Season")
        XCTAssertEqual(parsed.episode, 25)
        XCTAssertFalse(parsed.title.contains("LoliHouse"))
        XCTAssertFalse(parsed.title.contains("1080p"))
        XCTAssertFalse(parsed.title.contains("HEVC"))
    }

    func testBracketEpisode() {
        let parsed = MediaTitleParser.parse(
            "[Sakurato] Dungeon Meshi [01][AVC-8bit 1080p AAC][CHS]"
        )
        XCTAssertEqual(parsed.title, "Dungeon Meshi")
        XCTAssertEqual(parsed.episode, 1)
    }

    func testChineseSeasonAndEpisode() {
        let parsed = MediaTitleParser.parse("冰海战记 第二季 第01话")
        XCTAssertEqual(parsed.title, "冰海战记 第二季")
        XCTAssertEqual(parsed.season, 2)
        XCTAssertEqual(parsed.episode, 1)
    }

    func testFallbackKeepsReadableFileName() {
        let parsed = MediaTitleParser.parse("some_random_file.mkv")
        XCTAssertEqual(parsed.title, "some random file")
        XCTAssertNil(parsed.episode)
    }

    func testPlaybackTitleKeepsEpisodeAtTail() {
        XCTAssertEqual(
            MediaTitleParser.playbackTitle(
                for: "[LoliHouse] Tensei Shitara Slime Datta Ken 2nd Season - 25 [WebRip 1080p HEVC-10bit AAC SRTx3].mkv"
            ),
            "Tensei Shitara Slime Datta Ken 2nd Season · 第 25 集"
        )
        XCTAssertEqual(
            MediaTitleParser.playbackTitle(for: "冰海战记 第二季 第01话"),
            "冰海战记 第二季 · 第 1 集"
        )
        XCTAssertEqual(
            MediaTitleParser.playbackTitle(for: "some_random_file.mkv"),
            "some random file"
        )
    }

    func testPlaybackTitleCandidatesKeepEpisodeWhenWordsAreDropped() {
        let label = "Tensei Shitara Slime Datta Ken 2nd Season · 第 25 集"
        let candidates = PlaybackTitleFitter.candidates(for: label)

        XCTAssertEqual(candidates.first, label)
        XCTAssertTrue(
            candidates.contains("Tensei Shitara… · 第 25 集"),
            "应按词逐步缩短，实际=\(candidates)"
        )
        XCTAssertEqual(candidates.last, "第 25 集")
        // 候选从长到短，不能出现更长的候选排在后面。
        for (shorter, longer) in zip(candidates.dropFirst(), candidates) {
            XCTAssertLessThanOrEqual(shorter.count, longer.count, "候选应逐级变短")
        }
    }

    func testPlaybackTitleCandidatesWithoutEpisode() {
        let label = "Kono Kaisha ni Suki na Hito ga Imasu"
        let candidates = PlaybackTitleFitter.candidates(for: label)

        XCTAssertEqual(candidates.first, label)
        XCTAssertTrue(candidates.contains("Kono…"), "实际=\(candidates)")
        XCTAssertEqual(candidates.last, "Kono…")
    }

    func testPlaybackTitleSplitEpisodeSuffix() {
        let split = PlaybackTitleFitter.splitEpisode("冰海战记 第二季 · 第 1 集")
        XCTAssertEqual(split.title, "冰海战记 第二季")
        XCTAssertEqual(split.episode, "第 1 集")

        let noEpisode = PlaybackTitleFitter.splitEpisode("大逃杀")
        XCTAssertEqual(noEpisode.title, "大逃杀")
        XCTAssertNil(noEpisode.episode)
    }

    func testDirectoryDisplayNameRemovesReleaseTags() {
        XCTAssertEqual(
            MediaTitleParser.directoryDisplayName(
                "[LoliHouse] Kono Kaisha ni Suki na Hito ga Imasu [01-12][WebRip 1080p HEVC-10bit AAC]"
            ),
            "Kono Kaisha ni Suki na Hito ga Imasu"
        )
        XCTAssertEqual(MediaTitleParser.directoryDisplayName("- Sub"), "- Sub")
        XCTAssertEqual(MediaTitleParser.directoryDisplayName("冰海战记第二季"), "冰海战记第二季")
    }
}
