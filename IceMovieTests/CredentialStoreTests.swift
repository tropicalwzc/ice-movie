import IceCore
import XCTest

final class CredentialStoreTests: XCTestCase {
    private var service = ""

    override func setUp() {
        super.setUp()
        service = "com.wangzicheng.icemovie.tests.\(UUID().uuidString)"
    }

    func testSaveReadOverwriteDelete() throws {
        let store = KeychainCredentialStore(service: service)
        defer { try? store.deleteCredential(for: "nas.local") }

        try store.save(HostCredential(username: "wzc", password: "first"), for: "nas.local")
        let saved = try store.credential(for: "nas.local")
        XCTAssertEqual(saved?.username, "wzc")
        XCTAssertEqual(saved?.password, "first")

        try store.save(HostCredential(username: "wzc", password: "second"), for: "nas.local")
        let overwritten = try store.credential(for: "nas.local")
        XCTAssertEqual(overwritten?.password, "second")

        try store.deleteCredential(for: "nas.local")
        XCTAssertNil(try store.credential(for: "nas.local"))
    }

    func testMissingCredentialReturnsNil() throws {
        let store = KeychainCredentialStore(service: service)
        XCTAssertNil(try store.credential(for: "never-saved.local"))
    }

    func testInMemoryStoreMirrorsContract() throws {
        let store = InMemoryCredentialStore()
        try store.save(HostCredential(username: "u", password: "p"), for: "host")
        XCTAssertEqual(try store.credential(for: "host")?.password, "p")
        try store.save(HostCredential(username: "u", password: "p2"), for: "host")
        XCTAssertEqual(try store.credential(for: "host")?.password, "p2")
        try store.deleteCredential(for: "host")
        XCTAssertNil(try store.credential(for: "host"))
    }
}
