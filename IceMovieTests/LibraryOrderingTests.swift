import MediaLibraryKit
import XCTest

final class LibraryOrderingTests: XCTestCase {
    func testEpisodesSortNaturally() {
        let entries = [
            entry("Show - 10.mkv"),
            entry("Show - 2.mkv"),
            entry("Show - 1.mkv"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(
            sorted.map { MediaTitleParser.parse($0.name).episode },
            [1, 2, 10]
        )
    }

    func testDirectoriesComeBeforeVideos() {
        let entries = [
            entry("Show - 01.mkv"),
            entry("Sub", isDirectory: true),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertTrue(sorted[0].isDirectory)
        XCTAssertFalse(sorted[1].isDirectory)
    }

    func testVideosComeBeforeDocuments() {
        let entries = [
            entry("notes.md"),
            entry("Show - 01.mkv"),
            entry("guide.pdf"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(sorted.map(\.name), ["Show - 01.mkv", "guide.pdf", "notes.md"])
    }

    func testDocumentsSortNaturallyAndDoNotUseEpisodeOrdering() {
        let entries = [
            entry("Doc - 10.md"),
            entry("Doc - 2.md"),
            entry("Doc - 1.md"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(sorted.map(\.name), ["Doc - 1.md", "Doc - 2.md", "Doc - 10.md"])
    }

    func testImagesSortNaturally() {
        let entries = [
            entry("IMG_0010.HEIC"),
            entry("IMG_0002.HEIC"),
            entry("IMG_0001.HEIC"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(
            sorted.map(\.name),
            ["IMG_0001.HEIC", "IMG_0002.HEIC", "IMG_0010.HEIC"]
        )
    }

    func testImagesAndVideosMixByNaturalOrder() {
        let entries = [
            entry("IMG_0010.HEIC"),
            entry("IMG_0002.MOV"),
            entry("IMG_0001.HEIC"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(
            sorted.map(\.name),
            ["IMG_0001.HEIC", "IMG_0002.MOV", "IMG_0010.HEIC"]
        )
    }

    func testMixedImageVideoOrderingIsStrictWeakOrdering() {
        let expected = ["Alpha - 02.mkv", "Alpha 1.jpg", "Beta - 01.mkv"]
        let permutations: [[String]] = [
            ["Beta - 01.mkv", "Alpha - 02.mkv", "Alpha 1.jpg"],
            ["Beta - 01.mkv", "Alpha 1.jpg", "Alpha - 02.mkv"],
            ["Alpha - 02.mkv", "Beta - 01.mkv", "Alpha 1.jpg"],
            ["Alpha - 02.mkv", "Alpha 1.jpg", "Beta - 01.mkv"],
            ["Alpha 1.jpg", "Beta - 01.mkv", "Alpha - 02.mkv"],
            ["Alpha 1.jpg", "Alpha - 02.mkv", "Beta - 01.mkv"],
        ]
        for permutation in permutations {
            let sorted = MediaOrdering.sorted(permutation.map { entry($0) })
            XCTAssertEqual(
                sorted.map(\.name),
                expected,
                "混排结果不应依赖输入顺序：\(permutation)"
            )
        }
    }

    func testSameTitleMixedImageVideoOrderingIsStable() {
        let expected = ["Show[01].mkv", "Show - 02.mkv", "Show.jpg"]
        let permutations: [[String]] = [
            ["Show[01].mkv", "Show - 02.mkv", "Show.jpg"],
            ["Show[01].mkv", "Show.jpg", "Show - 02.mkv"],
            ["Show - 02.mkv", "Show[01].mkv", "Show.jpg"],
            ["Show - 02.mkv", "Show.jpg", "Show[01].mkv"],
            ["Show.jpg", "Show[01].mkv", "Show - 02.mkv"],
            ["Show.jpg", "Show - 02.mkv", "Show[01].mkv"],
        ]
        for permutation in permutations {
            let sorted = MediaOrdering.sorted(permutation.map { entry($0) })
            XCTAssertEqual(
                sorted.map(\.name),
                expected,
                "同标题图片/视频混排不应依赖输入顺序：\(permutation)"
            )
        }
    }

    func testDocumentsStayAfterImagesAndVideos() {
        let entries = [
            entry("notes.md"),
            entry("IMG_0001.HEIC"),
            entry("Episode 01.mkv"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(sorted.last?.name, "notes.md")
        XCTAssertEqual(Set(sorted.dropLast().map(\.kind)), [.video, .image])
    }

    func testNonDocumentItemsAreFilteredButDocumentsAndDirectoriesRemain() {
        let items: [(name: String, isDirectory: Bool, size: Int64, modified: Date?)] = [
            ("Episode 01.mkv", false, 100, nil),
            ("Show", true, 0, nil),
            ("notes.txt", false, 10, nil),
            ("show.ass", false, 20, nil),
            ("download.torrent", false, 30, nil),
            ("guide.pdf", false, 40, nil),
            ("notes.md", false, 50, nil),
        ]
        let built = LibraryEntryBuilder.build(directoryPath: "Anime", items: items)
        XCTAssertEqual(built.map(\.name), ["Show", "Episode 01.mkv", "guide.pdf", "notes.md"])
        XCTAssertEqual(built[1].path, "Anime/Episode 01.mkv")
        XCTAssertEqual(built[2].kind, .pdf)
        XCTAssertEqual(built[3].kind, .markdown)
    }

    func testHiddenSidecarDirectoryIsNotListed() {
        let items: [(name: String, isDirectory: Bool, size: Int64, modified: Date?)] = [
            (".icemovie", true, 0, nil),
            ("Photos", true, 0, nil),
            ("IMG_0001.jpg", false, 1, nil),
        ]
        let built = LibraryEntryBuilder.build(directoryPath: "", items: items)
        XCTAssertEqual(built.map(\.name), ["Photos", "IMG_0001.jpg"])
    }

    func testImagesAreVisibleAndOtherFilesStayHidden() {
        let items: [(name: String, isDirectory: Bool, size: Int64, modified: Date?)] = [
            ("Photos", true, 0, nil),
            ("IMG_0001.HEIC", false, 100, nil),
            ("IMG_0002.jpg", false, 100, nil),
            ("IMG_0003.LIVP", false, 100, nil),
            ("notes.txt", false, 10, nil),
            ("show.ass", false, 20, nil),
            ("download.torrent", false, 30, nil),
            ("script.py", false, 40, nil),
        ]
        let built = LibraryEntryBuilder.build(directoryPath: "Photos", items: items)
        XCTAssertEqual(
            Set(built.map(\.name)),
            ["Photos", "IMG_0001.HEIC", "IMG_0002.jpg", "IMG_0003.LIVP"]
        )
        XCTAssertEqual(built.first?.kind, .directory)
    }

    func testEpisodesWithCaptureTimestampsSortByEpisodeNotTime() {
        let entries = [
            entry("Show - 03_20240103000000.mkv"),
            entry("Show - 01_20240101000000.mkv"),
            entry("Show - 02_20240102000000.mkv"),
        ]
        let sorted = MediaOrdering.sorted(entries)

        XCTAssertEqual(
            sorted.compactMap { MediaTitleParser.parse($0.name).episode },
            [1, 2, 3]
        )
        XCTAssertEqual(
            sorted.map(\.name),
            [
                "Show - 01_20240101000000.mkv",
                "Show - 02_20240102000000.mkv",
                "Show - 03_20240103000000.mkv",
            ]
        )
    }

    func testEpisodeOrderIsStableAcrossInputPermutations() {
        let names = [
            "Show - 01_20240101000000.mkv",
            "Show - 02_20240102000000.mkv",
            "Show - 10_20240110000000.mkv",
        ]
        let permutations = [
            [names[2], names[0], names[1]],
            [names[1], names[2], names[0]],
            [names[2], names[1], names[0]],
        ]
        for permutation in permutations {
            let sorted = MediaOrdering.sorted(permutation.map { entry($0) })
            XCTAssertEqual(sorted.map(\.name), names, "排序不应依赖输入顺序：\(permutation)")
        }
    }

    func testReleaseGroupCRCStillSortsEpisodes() {
        let entries = [
            entry("[SumiSora][CLANNAD-AfterStory-][BDRip][17][x264_1080p][flac_6ch](1A9723D4).mkv"),
            entry("[SumiSora][CLANNAD-AfterStory-][BDRip][09][x264_1080p][flac_6ch](2EF27B8E).mkv"),
            entry("[SumiSora][CLANNAD-AfterStory-][BDRip][22][x264_1080p][flac_6ch](3B2E34C8).mkv"),
            entry("[SumiSora][CLANNAD-AfterStory-][BDRip][01][x264_1080p][flac_6ch](60C240C1).mkv"),
        ]
        let sorted = MediaOrdering.sorted(entries)

        XCTAssertEqual(
            sorted.compactMap { MediaTitleParser.parse($0.name).episode },
            [1, 9, 17, 22]
        )
        XCTAssertEqual(
            Set(sorted.map { MediaTitleParser.parse($0.name).title }).count,
            1,
            "CRC 不应把同一部剧拆成不同标题"
        )
    }

    func testSingleVideoAndImagesKeepTimestampOrder() {
        let entries = [
            entry("Clip.mov"),
            entry("IMG_20240102000000.jpg"),
            entry("IMG_20240103000000.jpg"),
        ]
        let sorted = MediaOrdering.sorted(entries)

        XCTAssertEqual(
            sorted.map(\.name),
            [
                "IMG_20240103000000.jpg",
                "IMG_20240102000000.jpg",
                "Clip.mov",
            ],
            "没有多集序列时，单集视频与照片仍按时间倒序"
        )
    }

    func testEpisodeOrderDrivesPlaybackQueue() {
        let sorted = MediaOrdering.sorted([
            entry("Show - 03_20240103000000.mkv"),
            entry("Show - 01_20240101000000.mkv"),
            entry("Show - 02_20240102000000.mkv"),
        ])

        XCTAssertEqual(
            PlaybackQueue.next(after: sorted[0], in: sorted)?.path,
            sorted[1].path
        )
        XCTAssertEqual(
            PlaybackQueue.next(after: sorted[1], in: sorted)?.path,
            sorted[2].path
        )
        XCTAssertNil(PlaybackQueue.next(after: sorted[2], in: sorted))
    }

    func testMultipleSeriesGroupByTitleThenEpisode() {
        let entries = [
            entry("Beta - 02.mkv"),
            entry("Alpha - 02.mkv"),
            entry("Beta - 01.mkv"),
            entry("Alpha - 01.mkv"),
        ]
        let sorted = MediaOrdering.sorted(entries)

        XCTAssertEqual(
            sorted.map(\.name),
            [
                "Alpha - 01.mkv",
                "Alpha - 02.mkv",
                "Beta - 01.mkv",
                "Beta - 02.mkv",
            ]
        )
    }

    private func entry(_ name: String, isDirectory: Bool = false) -> MediaEntry {
        MediaEntry(
            path: name,
            name: name,
            isDirectory: isDirectory,
            size: 1,
            modified: nil
        )
    }
}
