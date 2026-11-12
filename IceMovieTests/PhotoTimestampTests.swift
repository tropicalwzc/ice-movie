import MediaLibraryKit
import XCTest

final class PhotoTimestampTests: XCTestCase {
    func testParsesTrailingTimestamp() {
        let timestamp = PhotoTimestampParser.parse(
            filename: "4AA2042C-EF61-4F90-92F2-E798B21838EC_20170501140307.jpg"
        )
        XCTAssertEqual(timestamp?.year, 2017)
        XCTAssertEqual(timestamp?.month, 5)
        XCTAssertEqual(timestamp?.day, 1)
        XCTAssertEqual(timestamp?.hour, 14)
        XCTAssertEqual(timestamp?.minute, 3)
        XCTAssertEqual(timestamp?.second, 7)
    }

    func testParsesTimestampBeforeLIVPExtension() {
        let timestamp = PhotoTimestampParser.parse(
            filename: "2025-02-16 210732IMG_1241_20180526143955.livp"
        )
        XCTAssertEqual(timestamp?.dayKey, PhotoDay(year: 2018, month: 5, day: 26))
    }

    func testRejectsInvalidDatesAndMissingSuffix() {
        XCTAssertNil(PhotoTimestampParser.parse(filename: "photo_20241301120000.jpg"))
        XCTAssertNil(PhotoTimestampParser.parse(filename: "photo_20230230120000.jpg"))
        XCTAssertNil(PhotoTimestampParser.parse(filename: "photo_20240101120000"))
        XCTAssertNil(PhotoTimestampParser.parse(filename: "photo_2024010112000a.jpg"))
    }

    func testSortKeyDistinguishesHourMinuteAndSecond() {
        let oneAM = PhotoTimestampParser.parse(filename: "a_20240101010000.jpg")
        let tenPastMidnight = PhotoTimestampParser.parse(filename: "a_20240101001000.jpg")
        XCTAssertNotNil(oneAM)
        XCTAssertNotNil(tenPastMidnight)
        XCTAssertNotEqual(oneAM?.sortKey, tenPastMidnight?.sortKey)
        XCTAssertLessThan(tenPastMidnight!, oneAM!)

        let twoAM = PhotoTimestampParser.parse(filename: "a_20240101020000.jpg")
        let twentyPastMidnight = PhotoTimestampParser.parse(filename: "a_20240101002000.jpg")
        XCTAssertNotEqual(twoAM?.sortKey, twentyPastMidnight?.sortKey)
        XCTAssertLessThan(twentyPastMidnight!, twoAM!)

        let entries = [
            entry("a_20240101010000.jpg"),
            entry("a_20240101001000.jpg"),
        ]
        XCTAssertEqual(
            MediaOrdering.sorted(entries).map(\.name),
            ["a_20240101010000.jpg", "a_20240101001000.jpg"]
        )
    }

    func testTimestampedMediaSortsNewestFirst() {
        let entries = [
            entry("old_20240101000000.jpg"),
            entry("new_20250101000000.jpg"),
            entry("middle_20240601000000.jpg"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(
            sorted.map(\.name),
            ["new_20250101000000.jpg", "middle_20240601000000.jpg", "old_20240101000000.jpg"]
        )
    }

    func testTimestampedEntriesComeBeforeUntimestampedEntries() {
        let entries = [
            entry("plain.jpg"),
            entry("dated_20240101000000.jpg"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(sorted.first?.name, "dated_20240101000000.jpg")
    }

    func testTimestampedVideosAlsoSortNewestFirst() {
        let entries = [
            entry("clip_20200101000000.mov"),
            entry("photo_20240101000000.jpg"),
            entry("clip_20220101000000.mov"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(
            sorted.map(\.name),
            ["photo_20240101000000.jpg", "clip_20220101000000.mov", "clip_20200101000000.mov"]
        )
    }

    func testDocumentsStayLast() {
        let entries = [
            entry("notes.md"),
            entry("dated_20240101000000.jpg"),
        ]
        XCTAssertEqual(MediaOrdering.sorted(entries).last?.name, "notes.md")
    }

    func testCalendarIndexGroupsYearsMonthsDaysAndFirstEntry() {
        let entries = [
            entry("a_20240203090000.jpg"),
            entry("b_20240102090000.jpg"),
            entry("c_20240102080000.jpg"),
            entry("d_20230101090000.jpg"),
        ]
        let calendar = PhotoCalendarIndex(entries: entries)
        XCTAssertEqual(calendar.years, [2024, 2023])
        XCTAssertEqual(calendar.months(in: 2024), [2, 1])
        XCTAssertEqual(calendar.days(in: 2024, month: 1)[2], 2)
        XCTAssertEqual(
            calendar.firstEntry(for: PhotoDay(year: 2024, month: 1, day: 2))?.name,
            "b_20240102090000.jpg"
        )
        XCTAssertEqual(calendar.counts.values.reduce(0, +), 4)
    }

    func testCalendarIndexFindsNewestPhotoOfMonth() {
        let entries = [
            entry("a_20240203090000.jpg"),
            entry("b_20240102090000.jpg"),
            entry("c_20240102080000.jpg"),
            entry("d_20230101090000.jpg"),
        ]
        let calendar = PhotoCalendarIndex(entries: entries)
        XCTAssertEqual(
            calendar.firstEntry(in: 2024, month: 1)?.name,
            "b_20240102090000.jpg"
        )
        XCTAssertEqual(calendar.count(in: 2024, month: 1), 2)
        XCTAssertNil(calendar.firstEntry(in: 2024, month: 5))
        XCTAssertEqual(calendar.count(in: 2024, month: 5), 0)
    }

    private func entry(_ name: String) -> MediaEntry {
        MediaEntry(path: name, name: name, isDirectory: false, size: 1, modified: nil)
    }
}
