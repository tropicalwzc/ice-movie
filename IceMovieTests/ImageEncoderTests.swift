import CoreGraphics
import ImageIO
import ImageKit
import XCTest

final class ImageEncoderTests: XCTestCase {
    func testPNGRotationSwapsDimensions() throws {
        let data = try fixtureData("sample-landscape.png")
        let rotated = try ImageEncoder.rotatedImageData(
            originalData: data,
            type: .png,
            quarterTurns: 1
        )
        let image = try decode(rotated)
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 96)
        XCTAssertEqual(Array(rotated.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testJPEGOrientationAndRotation() throws {
        let data = try fixtureData("sample-orientation.jpg")
        let rotated = try ImageEncoder.rotatedImageData(
            originalData: data,
            type: .jpeg,
            quarterTurns: 1
        )
        let image = try decode(rotated)
        // 原图 80x40、Orientation=6 显示为 40x80；再顺时针一次得到 80x40。
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 40)
    }

    func testHEICRotation() throws {
        let data = try fixtureData("sample.heic")
        let rotated = try ImageEncoder.rotatedImageData(
            originalData: data,
            type: .heic,
            quarterTurns: 1
        )
        let image = try decode(rotated)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        XCTAssertEqual(String(decoding: rotated.prefix(12), as: UTF8.self).contains("ftyp"), true)
    }

    func testCorruptImageFails() {
        let data = Data(repeating: 0x42, count: 1024)
        XCTAssertThrowsError(
            try ImageEncoder.rotatedImageData(
                originalData: data,
                type: .jpeg,
                quarterTurns: 1
            )
        )
    }

    private func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageEncoderError.decodeFailed
        }
        return image
    }

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let pathExtension = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        if let url = bundle.url(
            forResource: base,
            withExtension: pathExtension,
            subdirectory: "ImageGallery"
        ) {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: base, withExtension: pathExtension) {
            return try Data(contentsOf: url)
        }
        throw XCTSkip("缺少测试 fixture：\(name)")
    }
}
