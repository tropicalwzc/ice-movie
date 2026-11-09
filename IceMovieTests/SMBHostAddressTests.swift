import SMBSession
import XCTest

final class SMBHostAddressTests: XCTestCase {
    func testIPv4Literal() throws {
        let address = try SMBHostAddress("192.168.5.2")
        XCTAssertEqual(address.raw, "192.168.5.2")
        XCTAssertEqual(address.host, "192.168.5.2")
        XCTAssertNil(address.port)
        XCTAssertEqual(address.url?.absoluteString, "smb://192.168.5.2")
    }

    func testLocalNamePreservesInputForm() throws {
        let address = try SMBHostAddress("  TROPICAL-ADVPC.local  ")
        XCTAssertEqual(address.raw, "TROPICAL-ADVPC.local", "连接记录必须保留用户输入形式")
        XCTAssertEqual(address.host, "tropical-advpc.local")
        XCTAssertNil(address.share)
    }

    func testBareHostname() throws {
        let address = try SMBHostAddress("nas")
        XCTAssertEqual(address.host, "nas")
        XCTAssertEqual(address.url?.absoluteString, "smb://nas")
    }

    func testSchemePortShareAndPath() throws {
        let address = try SMBHostAddress("smb://nas.local:1445/Animi/迷宫饭/第01集")
        XCTAssertEqual(address.host, "nas.local")
        XCTAssertEqual(address.port, 1445)
        XCTAssertEqual(address.share, "Animi")
        XCTAssertEqual(address.path, "迷宫饭/第01集")
        XCTAssertEqual(address.url?.absoluteString, "smb://nas.local:1445")
    }

    func testBareIPv6IsBracketedForURL() throws {
        let address = try SMBHostAddress("fe80::1")
        XCTAssertEqual(address.host, "fe80::1")
        XCTAssertNil(address.port)
        XCTAssertEqual(address.url?.absoluteString, "smb://[fe80::1]")
    }

    func testBracketedIPv6WithPort() throws {
        let address = try SMBHostAddress("[fe80::1]:445")
        XCTAssertEqual(address.host, "fe80::1")
        XCTAssertEqual(address.port, 445)
        XCTAssertEqual(address.url?.absoluteString, "smb://[fe80::1]:445")
    }

    func testCredentialPrefixIsNotPartOfHost() throws {
        let address = try SMBHostAddress("wzc@nas.local")
        XCTAssertEqual(address.host, "nas.local")
    }

    func testEmptyOrWhitespaceThrows() {
        XCTAssertThrowsError(try SMBHostAddress("")) { error in
            XCTAssertEqual(error as? SMBAddressError, .empty)
        }
        XCTAssertThrowsError(try SMBHostAddress("   "))
    }

    func testInvalidPortThrows() {
        XCTAssertThrowsError(try SMBHostAddress("nas.local:70000")) { error in
            XCTAssertEqual(error as? SMBAddressError, .invalidPort("70000"))
        }
    }
}
