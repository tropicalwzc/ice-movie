import CoreGraphics
import IceCore
import ImageIO
import ImageKit
import XCTest

final class ImageKitTests: XCTestCase {
    func testJPEGThumbnailIsDownsampled() throws {
        let data = try fixtureData("sample.jpg")
        let output = try ImageDecoder.thumbnail(data: data, maxPixelSize: 32)
        XCTAssertLessThanOrEqual(max(output.width, output.height), 32)
        XCTAssertEqual(Array(output.data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testHEICThumbnail() throws {
        let data = try fixtureData("sample.heic")
        let output = try ImageDecoder.thumbnail(data: data, maxPixelSize: 32)
        XCTAssertGreaterThan(output.width, 0)
        XCTAssertGreaterThan(output.height, 0)
    }

    func testSmallSourceTriggersFullImageFallback() throws {
        let data = try fixtureData("sample.jpg")
        let output = try ImageDecoder.thumbnail(data: data, maxPixelSize: 480)
        XCTAssertEqual(output.width, 64)
        XCTAssertEqual(output.height, 64)
    }

    func testThumbnailCanProduceSidecarJPEGDirectly() throws {
        let data = try fixtureData("sample.jpg")
        let output = try ImageDecoder.thumbnail(
            data: data,
            maxPixelSize: 64,
            includeJPEG: true
        )
        let jpeg = try XCTUnwrap(output.jpegData)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertNil(
            try ImageDecoder.thumbnail(data: data, maxPixelSize: 64).jpegData,
            "未请求侧车 JPEG 时不应多做一次编码"
        )
    }

    func testRemoteProviderSurvivesWrapperDeallocation() throws {
        let data = try fixtureData("sample.jpg")
        let source = PaddedByteSource(data: data, padding: 512 * 1024)
        let provider: CGDataProvider
        do {
            let remote = try RemoteImageDataProvider(
                source: source,
                label: "lifetime",
                windowSize: 64 * 1024
            )
            provider = remote.provider
        }
        // remote 已释放：数据提供者必须自己保住回调所需的 Reader。
        guard let imageSource = CGImageSourceCreateWithDataProvider(
            provider,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return XCTFail("无法创建图片源")
        }
        let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
            ] as CFDictionary
        )
        XCTAssertNotNil(image)
    }

    func testPNGAlphaThumbnailKeepsAlpha() throws {
        let data = try fixtureData("sample-alpha.png")
        let output = try ImageDecoder.thumbnail(data: data, maxPixelSize: 32)
        guard let source = CGImageSourceCreateWithData(output.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("无法解码缩略图")
        }
        XCTAssertNotEqual(image.alphaInfo, .none)
    }

    func testEXIFOrientationIsApplied() throws {
        let data = try fixtureData("sample-orientation.jpg")
        let output = try ImageDecoder.thumbnail(data: data, maxPixelSize: 64)
        XCTAssertLessThan(output.width, output.height, "Orientation=6 应把 80x40 旋转为竖图")
    }

    func testRemoteProviderRecordsImageIOReadBehavior() async throws {
        let data = try fixtureData("sample.jpg")
        let source = PaddedByteSource(data: data, padding: 2 * 1024 * 1024)
        let remote = try RemoteImageDataProvider(source: source, label: "padded", windowSize: 64 * 1024)
        guard let imageSource = CGImageSourceCreateWithDataProvider(
            remote.provider,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return XCTFail("无法创建图片源")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(remote.bytesRead, 0)
        XCTAssertLessThanOrEqual(remote.bytesRead, source.length ?? 0)
        // 实测：ImageIO 会请求整个 provider，range 读取没有字节级收益。
        // v1 因此采用“整张压缩图读取 + 下采样”的兜底，靠并发与缓存控制成本。
        print("ImageKit range spike: bytesRead=\(remote.bytesRead) requests=\(remote.requestCount)")
    }

    func testStoredLIVPStillAndMotion() async throws {
        let source = try LocalFileByteSource(url: try fixtureURL("sample-stored.livp"))
        let package = try await LivePhotoPackage.parse(source: source, label: "stored")
        XCTAssertEqual(package.stillEntry?.fileExtension, "heic")
        XCTAssertEqual(package.motionEntry?.fileExtension, "mov")
        let still = try await package.stillImageData(source: source)
        XCTAssertGreaterThan(still.count, 0)
        XCTAssertTrue(String(decoding: still.prefix(8), as: UTF8.self).contains("ftyp"))
        let motion = try await package.motionByteSource(source: source)
        XCTAssertEqual(motion.length, package.motionEntry?.compressedSize)
        let first = try await motion.read(at: 0, count: 16)
        XCTAssertFalse(first.isEmpty)
        await source.close()
    }

    func testDeflatedLIVPStillAndMotion() async throws {
        let source = try LocalFileByteSource(url: try fixtureURL("sample-deflated.livp"))
        let package = try await LivePhotoPackage.parse(source: source, label: "deflated")
        XCTAssertNotNil(package.stillEntry)
        XCTAssertEqual(package.stillEntry?.compressionMethod, 8)
        let still = try await package.stillImageData(source: source)
        XCTAssertGreaterThan(still.count, 0)
        let motion = try await package.motionByteSource(source: source)
        let first = try await motion.read(at: 0, count: 16)
        XCTAssertFalse(first.isEmpty)
        await source.close()
    }

    func testLIVPWithoutStillReportsMissingStill() async throws {
        let source = try LocalFileByteSource(url: try fixtureURL("sample-no-still.livp"))
        let package = try await LivePhotoPackage.parse(source: source, label: "no-still")
        XCTAssertNil(package.stillEntry)
        XCTAssertNotNil(package.motionEntry)
        await source.close()
    }

    func testLIVPWithoutMotionReportsMissingMotion() async throws {
        let source = try LocalFileByteSource(url: try fixtureURL("sample-no-motion.livp"))
        let package = try await LivePhotoPackage.parse(source: source, label: "no-motion")
        XCTAssertNotNil(package.stillEntry)
        XCTAssertNil(package.motionEntry)
        await source.close()
    }

    func testBrokenLIVPThrows() async throws {
        let source = try LocalFileByteSource(url: try fixtureURL("broken.livp"))
        do {
            _ = try await LivePhotoPackage.parse(source: source, label: "broken")
            XCTFail("损坏的 LIVP 应失败")
        } catch {
            XCTAssertTrue(error is LivePhotoPackageError)
        }
        await source.close()
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

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: try fixtureURL(name))
    }
}

private actor PaddedByteSource: ByteSource {
    private let data: Data
    private let padding: Int

    nonisolated let length: Int64?

    init(data: Data, padding: Int) {
        self.data = data
        self.padding = padding
        self.length = Int64(data.count + padding)
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, offset < (length ?? 0), count > 0 else { return Data() }
        let start = Int(offset)
        let end = min(data.count + padding, start + count)
        if start >= data.count {
            return Data(repeating: 0, count: end - start)
        }
        let dataEnd = min(data.count, end)
        var result = data.subdata(in: start..<dataEnd)
        if end > data.count {
            result.append(Data(repeating: 0, count: end - dataEnd))
        }
        return result
    }

    func close() async {}
}
