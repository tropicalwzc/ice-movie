import MediaLibraryKit
import XCTest

final class LibraryNavigationTests: XCTestCase {
    func testEnterAndBackPreserveScrollAnchor() {
        var state = LibraryNavigationState(host: "nas", share: "Animi")
        state.enter("强风吹拂")
        state.enter("- Sub")
        XCTAssertEqual(state.currentPath, "强风吹拂/- Sub")
        XCTAssertEqual(state.stack, ["强风吹拂", "- Sub"])

        state.setScrollAnchor("强风吹拂/- Sub/01.ass", for: state.currentPath)
        XCTAssertTrue(state.goBack())
        XCTAssertEqual(state.currentPath, "强风吹拂")
        XCTAssertEqual(state.scrollAnchor(for: "强风吹拂/- Sub"), "强风吹拂/- Sub/01.ass")
    }

    func testChangeShareResetsStackAndAnchors() {
        var state = LibraryNavigationState(host: "nas", share: "Animi")
        state.enter("强风吹拂")
        state.setScrollAnchor("强风吹拂/01.mkv", for: state.currentPath)

        state.changeShare("Movies")

        XCTAssertEqual(state.share, "Movies")
        XCTAssertEqual(state.host, "nas")
        XCTAssertEqual(state.currentPath, "")
        XCTAssertTrue(state.stack.isEmpty)
        XCTAssertNil(state.scrollAnchor(for: "强风吹拂"))
    }

    func testMoveToPathBuildsBreadcrumb() {
        var state = LibraryNavigationState(host: "nas", share: "Animi")
        state.move(to: "A/B/C")
        XCTAssertEqual(state.currentPath, "A/B/C")
        XCTAssertEqual(state.breadcrumb.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(state.breadcrumb.map(\.path), ["A", "A/B", "A/B/C"])
        XCTAssertEqual(state.parentPath, "A/B")
    }

    func testShellSwitchDoesNotMutateNavigation() {
        var state = LibraryNavigationState(host: "nas", share: "Animi")
        state.enter("迷宫饭")
        state.setScrollAnchor("迷宫饭/01.mkv", for: state.currentPath)

        var presentation = LibraryPresentation(shell: .compact, navigation: state)
        presentation.switchShell(to: .split)

        XCTAssertEqual(presentation.shell, .split)
        XCTAssertEqual(presentation.navigation, state)
        XCTAssertEqual(presentation.navigation.currentPath, "迷宫饭")
        XCTAssertEqual(presentation.navigation.scrollAnchor(for: "迷宫饭"), "迷宫饭/01.mkv")

        presentation.switchShell(to: .compact)
        XCTAssertEqual(presentation.navigation, state)
    }
}
