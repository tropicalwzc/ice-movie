import PersistenceKit
import SwiftData
import XCTest

@MainActor
final class HostRecordStoreTests: XCTestCase {
    private func makeStore(now: @escaping () -> Date = Date.init) throws -> (HostRecordStore, ModelContext) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedHost.self, configurations: configuration)
        let context = ModelContext(container)
        return (HostRecordStore(context: context, now: now), context)
    }

    func testRememberReadAndOverwrite() throws {
        let (store, _) = try makeStore()

        try store.remember(address: "nas.local", username: "wzc", share: "Animi", path: "")
        XCTAssertEqual(store.all().count, 1)

        try store.remember(address: "nas.local", username: "wzc2", share: "Animi", path: "迷宫饭")
        let all = store.all()
        XCTAssertEqual(all.count, 1, "同一地址必须覆盖而不是新增")
        XCTAssertEqual(all[0].username, "wzc2")
        XCTAssertEqual(all[0].recentPath, "迷宫饭")
        XCTAssertEqual(store.mostRecent()?.address, "nas.local")
    }

    func testUpdatePathKeepsAddressForm() throws {
        let (store, _) = try makeStore()
        try store.remember(address: "TROPICAL-ADVPC.local", username: "wzc", share: "Animi", path: "")

        store.updatePath(address: "TROPICAL-ADVPC.local", share: "Animi", path: "强风吹拂/- Sub")

        XCTAssertEqual(store.mostRecent()?.address, "TROPICAL-ADVPC.local")
        XCTAssertEqual(store.mostRecent()?.recentPath, "强风吹拂/- Sub")
    }

    func testMostRecentOrdersByConnectionTime() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let (store, _) = try makeStore(now: { current })

        try store.remember(address: "old.local", username: "u", share: "A", path: "")
        current = Date(timeIntervalSince1970: 2_000)
        try store.remember(address: "new.local", username: "u", share: "A", path: "")

        XCTAssertEqual(store.mostRecent()?.address, "new.local")
        XCTAssertEqual(store.all().map(\.address), ["new.local", "old.local"])
    }

    func testForgetDeletesRecord() throws {
        let (store, _) = try makeStore()
        try store.remember(address: "nas.local", username: "wzc", share: "Animi", path: "")

        try store.forget(address: "nas.local")

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(store.mostRecent())
    }
}
