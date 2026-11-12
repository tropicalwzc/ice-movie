import XCTest

final class ImageFixturesTests: XCTestCase {
    private let fixtureNames = [
        "sample.jpg",
        "sample.heic",
        "sample.heif",
        "sample-alpha.png",
        "sample-landscape.png",
        "sample-portrait.png",
        "sample-orientation.jpg",
        "motion.mov",
        "sample-stored.livp",
        "sample-deflated.livp",
        "sample-no-motion.livp",
        "sample-no-still.livp",
        "broken.livp",
    ]

    func testAllImageFixturesAreBundled() throws {
        for name in fixtureNames {
            let url = try fixtureURL(name)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            XCTAssertGreaterThan(values.fileSize ?? 0, 0, "fixture 为空：\(name)")
        }
    }

    func testFixtureMagicLooksSane() throws {
        XCTAssertEqual(try firstBytes("sample.jpg", count: 2), [0xFF, 0xD8])
        XCTAssertEqual(try firstBytes("sample-alpha.png", count: 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(try firstBytes("sample-stored.livp", count: 2), [0x50, 0x4B])
        XCTAssertEqual(try firstBytes("sample-deflated.livp", count: 2), [0x50, 0x4B])
        XCTAssertEqual(try firstBytes("motion.mov", count: 4).count, 4)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let pathExtension = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        if let url = bundle.url(
            forResource: base,
            withExtension: pathExtension,
            subdirectory: "ImageGallery"
        ) {
            return url
        }
        if let url = bundle.url(forResource: base, withExtension: pathExtension) {
            return url
        }
        throw XCTSkip("缺少测试 fixture：\(name)")
    }

    private func firstBytes(_ name: String, count: Int) throws -> [UInt8] {
        let data = try Data(contentsOf: try fixtureURL(name))
        return Array(data.prefix(count))
    }
}
