import MediaLibraryKit
import XCTest

final class LibraryLayoutTests: XCTestCase {
    func testIPhonePortraitHasAtLeastTwoColumns() {
        let count = LibraryGridLayout.columnCount(availableWidth: 393)
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testIPadLandscapeSplitHasAtLeastFourColumns() {
        let count = LibraryGridLayout.columnCount(availableWidth: 860)
        XCTAssertGreaterThanOrEqual(count, 4)
    }

    func testWiderWindowAddsColumnsInsteadOfScalingCells() {
        let normal = LibraryGridLayout.columnCount(availableWidth: 860)
        let wide = LibraryGridLayout.columnCount(availableWidth: 1600)
        XCTAssertGreaterThan(wide, normal)

        let cellWidth = (860 - 32 - Double(normal - 1) * 14) / Double(normal)
        XCTAssertGreaterThanOrEqual(cellWidth, LibraryGridLayout.minimumCellWidth)
    }

    func testNarrowWindowFallsBackToOneColumn() {
        XCTAssertEqual(LibraryGridLayout.columnCount(availableWidth: 200), 1)
    }
}
