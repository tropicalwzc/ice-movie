import MediaLibraryKit
import XCTest

final class PhotoFileNameTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testNormalCameraName() throws {
        let date = try makeDate(2026, 5, 5, 22, 26, 9)
        let name = PhotoFileName.fileName(
            originalFilename: "IMG_9399.HEIC",
            captureDate: date,
            uniformTypeIdentifier: "public.heic",
            timeZone: timeZone
        )
        XCTAssertEqual(name, "IMG_9399_20260505222609.heic")
    }

    func testPrefixedOriginalNameKeepsPrefixAndUsesUTIExtension() throws {
        let date = try makeDate(2018, 5, 26, 14, 39, 55)
        let name = PhotoFileName.fileName(
            originalFilename: "2025-02-16 210732IMG_1241.JPG",
            captureDate: date,
            uniformTypeIdentifier: "public.jpeg",
            timeZone: timeZone
        )
        XCTAssertEqual(name, "2025-02-16 210732IMG_1241_20180526143955.jpg")
    }

    func testChineseAndSpacesSurviveSanitizing() throws {
        let date = try makeDate(2024, 1, 2, 3, 4, 5)
        let name = PhotoFileName.fileName(
            originalFilename: "海边 日落/2024.PNG",
            captureDate: date,
            uniformTypeIdentifier: "public.png",
            timeZone: timeZone
        )
        XCTAssertEqual(name, "海边 日落_2024_20240102030405.png")
    }

    func testExistingSameTimestampIsNotDuplicated() throws {
        let date = try makeDate(2026, 5, 5, 22, 26, 9)
        let name = PhotoFileName.fileName(
            originalFilename: "IMG_9399_20260505222609.HEIC",
            captureDate: date,
            uniformTypeIdentifier: "public.heic",
            timeZone: timeZone
        )
        XCTAssertEqual(name, "IMG_9399_20260505222609.heic")
    }

    func testCollisionIndexGoesBeforeTimestamp() throws {
        let date = try makeDate(2026, 5, 5, 22, 26, 9)
        let name = PhotoFileName.fileName(
            originalFilename: "IMG_9399.HEIC",
            captureDate: date,
            uniformTypeIdentifier: "public.heic",
            collisionIndex: 1,
            timeZone: timeZone
        )
        XCTAssertEqual(name, "IMG_9399_2_20260505222609.heic")
        XCTAssertNotNil(PhotoTimestampParser.parse(filename: name!))
    }

    func testLongBaseIsTruncatedButTimestampSurvives() throws {
        let date = try makeDate(2026, 5, 5, 22, 26, 9)
        let long = String(repeating: "a", count: 400) + ".JPG"
        let name = PhotoFileName.fileName(
            originalFilename: long,
            captureDate: date,
            uniformTypeIdentifier: "public.jpeg",
            timeZone: timeZone
        )
        let unwrapped = try XCTUnwrap(name)
        XCTAssertTrue(unwrapped.hasSuffix("_20260505222609.jpg"))
        XCTAssertLessThan(unwrapped.count, 190)
        XCTAssertNotNil(PhotoTimestampParser.parse(filename: unwrapped))
    }

    func testUnsupportedFormatReturnsNil() throws {
        let date = try makeDate(2026, 5, 5, 22, 26, 9)
        XCTAssertNil(
            PhotoFileName.fileName(
                originalFilename: "IMG_0001.DNG",
                captureDate: date,
                uniformTypeIdentifier: "com.adobe.raw-image",
                timeZone: timeZone
            )
        )
        XCTAssertNil(
            PhotoFileName.fileName(
                originalFilename: "anim.GIF",
                captureDate: date,
                uniformTypeIdentifier: "com.compuserve.gif",
                timeZone: timeZone
            )
        )
    }

    func testUTIMissingFallsBackToOriginalExtension() throws {
        let date = try makeDate(2026, 5, 5, 22, 26, 9)
        XCTAssertEqual(
            PhotoFileName.fileName(
                originalFilename: "IMG_0001.JPEG",
                captureDate: date,
                uniformTypeIdentifier: nil,
                timeZone: timeZone
            ),
            "IMG_0001_20260505222609.jpg"
        )
    }

    func testTimezoneChangesFormattedTimestamp() throws {
        let date = try makeDate(2026, 5, 5, 22, 26, 9)
        let shanghai = PhotoFileName.timestampString(for: date, timeZone: timeZone)
        let utc = PhotoFileName.timestampString(
            for: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(shanghai, "20260505222609")
        XCTAssertEqual(utc, "20260505142609")
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        return try XCTUnwrap(calendar.date(from: components))
    }
}
