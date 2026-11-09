import DemuxKit
import IceCore
@testable import SubtitleKit
import XCTest

/// 真实库命名回归：`Chs&Jap` / `Cht&Jap` / `Jap` 这类组合语言后缀。
final class ExternalSubtitleMatchingTests: XCTestCase {
    private let directory =
        "/private/tmp/animi/我的青春恋爱物语果然有问题/[Kamigami] Yahari Ore no Seishun Love Come wa Machigatteiru [1920x1080 AVC FLAC]"
    private let video =
        "[Kamigami] Yahari Ore no Seishun Love Come wa Machigatteiru 01 [1920x1080 AVC FLAC].mkv"
    private let subtitles = [
        "[Kamigami] Yahari Ore no Seishun Love Come wa Machigatteiru 01 [1920x1080 AVC FLAC].Chs&Jap.ass",
        "[Kamigami] Yahari Ore no Seishun Love Come wa Machigatteiru 01 [1920x1080 AVC FLAC].Cht&Jap.ass",
        "[Kamigami] Yahari Ore no Seishun Love Come wa Machigatteiru 01 [1920x1080 AVC FLAC].Jap.ass",
    ]

    func testCombinedLanguageSuffixesMatchVideo() {
        let tracks = SubtitleDiscovery.external(
            videoFileName: video,
            filesByDirectory: ["": subtitles]
        )
        XCTAssertEqual(tracks.count, 3, "三条外挂字幕都应匹配")
        XCTAssertEqual(Set(tracks.map(\.language)), [
            .simplifiedChinese, .traditionalChinese, .japanese,
        ])
        XCTAssertTrue(tracks.allSatisfy { $0.format == .ass })
    }

    func testCombinedSuffixNormalizesToSameBase() {
        let videoBase = SubtitleDiscovery.parse(video).base
        for name in subtitles {
            let parsed = SubtitleDiscovery.parse(name)
            XCTAssertEqual(parsed.base, videoBase, "\(name)：标题归一化后应一致")
            XCTAssertEqual(parsed.episode, 1, "\(name)：应识别第 1 集")
        }
    }

    func testEmbeddedStreamsIfPresent() throws {
        let path = directory + "/" + video
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("样本缺失")
        }
        let reader = try MediaReader.open(path: path)
        let subtitles = reader.info.streams.filter { $0.kind == .subtitle }
        reader.close()
        Log.info(.subtitle, "Oregairu 内封字幕轨=\(subtitles.count) \(subtitles.map(\.codec))")
    }
}
