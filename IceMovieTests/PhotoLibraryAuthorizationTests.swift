import MediaLibraryKit
import Photos
import XCTest
@testable import IceMovie

final class PhotoLibraryAuthorizationTests: XCTestCase {
    func testStatusCapabilities() {
        XCTAssertFalse(PhotoLibraryAuthorizationStatus.notDetermined.canRead)
        XCTAssertFalse(PhotoLibraryAuthorizationStatus.denied.canRead)
        XCTAssertTrue(PhotoLibraryAuthorizationStatus.denied.needsSettings)
        XCTAssertFalse(PhotoLibraryAuthorizationStatus.restricted.canRead)
        XCTAssertTrue(PhotoLibraryAuthorizationStatus.restricted.needsSettings)
        XCTAssertTrue(PhotoLibraryAuthorizationStatus.limited.canRead)
        XCTAssertTrue(PhotoLibraryAuthorizationStatus.limited.isLimited)
        XCTAssertTrue(PhotoLibraryAuthorizationStatus.authorized.canRead)
        XCTAssertFalse(PhotoLibraryAuthorizationStatus.authorized.needsSettings)
    }

    func testDisplayTextIsNotEmpty() {
        for status in PhotoLibraryAuthorizationStatus.allCases {
            XCTAssertFalse(status.displayText.isEmpty)
        }
    }

    func testMapPhotoKitStatuses() {
        XCTAssertEqual(
            PhotoLibraryAuthorization.map(.notDetermined),
            .notDetermined
        )
        XCTAssertEqual(PhotoLibraryAuthorization.map(.restricted), .restricted)
        XCTAssertEqual(PhotoLibraryAuthorization.map(.denied), .denied)
        XCTAssertEqual(PhotoLibraryAuthorization.map(.authorized), .authorized)
        XCTAssertEqual(PhotoLibraryAuthorization.map(.limited), .limited)
    }
}
