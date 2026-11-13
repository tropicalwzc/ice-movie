import CoreGraphics
import ImageIO
@testable import ImageKit
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

    func testPreviewRotationDownsamplesToScreenSize() throws {
        let image = try decode(fixtureData("sample-landscape.png"))
        let preview = try XCTUnwrap(
            ImageEncoder.rotatedPreview(image, quarterTurns: 1, maxPixelSize: 48)
        )
        XCTAssertEqual(preview.width, 24)
        XCTAssertEqual(preview.height, 48)
    }

    func testZeroTurnPreviewStillDownsamples() throws {
        let image = try decode(fixtureData("sample-landscape.png"))
        let preview = try XCTUnwrap(
            ImageEncoder.rotatedPreview(image, quarterTurns: 0, maxPixelSize: 48)
        )
        XCTAssertEqual(preview.width, 48)
        XCTAssertEqual(preview.height, 24, "0 度预览也必须遵守最长边限制")
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

    func testSaveTargetKeepsNormalPhotosAndBoundsHugeOnes() {
        XCTAssertEqual(
            ImageEncoder.saveTargetDimension(width: 4032, height: 3024, maxDimension: 4032),
            4032,
            "12MP 照片必须保持原像素"
        )
        XCTAssertEqual(
            ImageEncoder.saveTargetDimension(width: 6000, height: 4000, maxDimension: 6000),
            6000,
            "24MP 照片仍在工作集上限内"
        )
        let huge = ImageEncoder.saveTargetDimension(
            width: 8064,
            height: 6048,
            maxDimension: 8064
        )
        XCTAssertLessThanOrEqual(huge, 6144, "48MP 旋转必须限制单张位图内存")
        XCTAssertGreaterThan(huge, 5000, "下采样不应过度损失分辨率")
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
