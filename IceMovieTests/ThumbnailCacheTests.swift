import IceCore
import ThumbnailKit
import XCTest
@testable import IceMovie

final class ThumbnailCacheTests: XCTestCase {
    func testDefaultDiskCacheLimitIs64MB() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory)
        XCTAssertEqual(store.capacityBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ThumbnailStore.maximumDiskBytes, 64 * 1024 * 1024)
    }

    func testStoreClampsCapacityAtInitializerBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(
            directory: directory,
            capacityBytes: 500 * 1024 * 1024
        )
        XCTAssertEqual(store.capacityBytes, ThumbnailStore.maximumDiskBytes)
    }

    func testRequestedCapacityIsClampedToHardLimit() {
        XCTAssertEqual(
            ThumbnailStore.clampedCapacityBytes(requestedMB: nil),
            64 * 1024 * 1024
        )
        XCTAssertEqual(
            ThumbnailStore.clampedCapacityBytes(requestedMB: 150),
            64 * 1024 * 1024
        )
        XCTAssertEqual(
            ThumbnailStore.clampedCapacityBytes(requestedMB: 40),
            40 * 1024 * 1024
        )
        XCTAssertEqual(
            ThumbnailStore.clampedCapacityBytes(requestedMB: 0),
            1 * 1024 * 1024
        )
    }

    func testCacheKeyChangesWithSizeAndModificationDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let base = ThumbnailCacheKey.make(path: "A/B.mkv", size: 100, modified: date)
        let same = ThumbnailCacheKey.make(path: "A/B.mkv", size: 100, modified: date)
        let resized = ThumbnailCacheKey.make(path: "A/B.mkv", size: 101, modified: date)
        let replaced = ThumbnailCacheKey.make(
            path: "A/B.mkv",
            size: 100,
            modified: date.addingTimeInterval(1)
        )

        XCTAssertEqual(base, same)
        XCTAssertNotEqual(base, resized)
        XCTAssertNotEqual(base, replaced)
        XCTAssertEqual(base.count, 64)
    }

    func testCacheKeyIncludesShareNamespace() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let animi = ThumbnailCacheKey.make(
            path: "01.mkv",
            size: 100,
            modified: date,
            namespace: "nas|Animi"
        )
        let movies = ThumbnailCacheKey.make(
            path: "01.mkv",
            size: 100,
            modified: date,
            namespace: "nas|Movies"
        )
        XCTAssertNotEqual(animi, movies, "不同共享的同名文件不能共用封面")
    }

    func testStoreEvictsOldestUntilUnderCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 10)
        try await store.save(Data(repeating: 1, count: 6), forKey: "a")
        try await store.save(Data(repeating: 2, count: 6), forKey: "b")

        let snapshot = await store.snapshot()
        XCTAssertLessThanOrEqual(snapshot.bytes, 10)
        XCTAssertEqual(snapshot.count, 1)

        let first = await store.cachedData(forKey: "a")
        let second = await store.cachedData(forKey: "b")
        XCTAssertNil(first)
        XCTAssertNotNil(second)
    }

    func testCacheHitRefreshesAccessTimeAndKeepsEntry() async throws {        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 12)
        try await store.save(Data(repeating: 1, count: 6), forKey: "a")
        try await store.save(Data(repeating: 2, count: 6), forKey: "b")

        // 访问 a，使其成为最近使用。
        _ = await store.cachedData(forKey: "a")
        try await Task.sleep(for: .milliseconds(30))
        try await store.save(Data(repeating: 3, count: 6), forKey: "c")

        let a = await store.cachedData(forKey: "a")
        let b = await store.cachedData(forKey: "b")
        let c = await store.cachedData(forKey: "c")
        XCTAssertNotNil(a, "最近访问过的封面应保留")
        XCTAssertNil(b, "最久未使用的封面应被淘汰")
        XCTAssertNotNil(c)
    }

    func testTwentyMegabyteCapEvictsToLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let limit: Int64 = 20 * 1024 * 1024
        let store = try ThumbnailStore(directory: directory, capacityBytes: limit)
        let sixMB = Data(repeating: 7, count: 6 * 1024 * 1024)
        for index in 0..<4 {
            try await store.save(sixMB, forKey: "k\(index)")
            try await Task.sleep(for: .milliseconds(10))
        }

        let snapshot = await store.snapshot()
        XCTAssertLessThanOrEqual(snapshot.bytes, limit)
        XCTAssertEqual(snapshot.count, 3, "4 × 6MB 超过 20MB，应淘汰最旧的一张")
    }

    func testFailedEntryIsNotRetriedInSameSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = FailingProvider()

        let first = await service.thumbnail(
            path: "broken.mkv", size: 1, modified: nil, provider: provider
        )
        let second = await service.thumbnail(
            path: "broken.mkv", size: 1, modified: nil, provider: provider
        )

        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await provider.openCount()
        XCTAssertEqual(calls, 1, "同一会话内失败条目不应重复打开")
        let known = await service.isKnownFailure(path: "broken.mkv", size: 1, modified: nil)
        XCTAssertTrue(known)
    }

    func testImageThumbnailUsesImageDecoderAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 4 * 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = FixtureProvider(name: "sample.jpg")

        let first = await service.thumbnail(
            path: "Photos/IMG_0001.JPG",
            size: 1,
            modified: nil,
            contentKind: .image,
            provider: provider
        )
        let second = await service.thumbnail(
            path: "Photos/IMG_0001.JPG",
            size: 1,
            modified: nil,
            contentKind: .image,
            provider: provider
        )

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first?.fromCache ?? true)
        XCTAssertTrue(second?.fromCache ?? false)
        let opens = await provider.openCount()
        XCTAssertEqual(opens, 1, "图片缩略图应命中缓存，不重复读取")
    }

    /// A 等 T1 时被 cancel，C 创建 T2；A 恢复后不得把 T2 从 in-flight 表里清掉。
    func testCancelDoesNotDropNewerInFlightRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 4 * 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = GatedProvider(url: try fixtureURL(name: "sample.jpg"))
        let path = "Photos/race-\(UUID().uuidString).jpg"

        let first = Task {
            await service.thumbnail(
                path: path,
                size: 1,
                modified: nil,
                contentKind: .image,
                provider: provider
            )
        }
        await provider.waitForOpenCount(1)
        await service.cancel(path: path, size: 1, modified: nil)

        let second = Task {
            await service.thumbnail(
                path: path,
                size: 1,
                modified: nil,
                contentKind: .image,
                provider: provider
            )
        }
        await provider.waitForOpenCount(2)

        // 放行被取消的 A；它返回后不能把 C 的 T2 从 in-flight 表里抹掉。
        await provider.releaseOpen(1)
        _ = await first.value

        let third = Task {
            await service.thumbnail(
                path: path,
                size: 1,
                modified: nil,
                contentKind: .image,
                provider: provider
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        let opensWhileWaiting = await provider.openCount()
        XCTAssertEqual(
            opensWhileWaiting,
            2,
            "第三个请求应加入 T2，而不是重新打开原图"
        )

        await provider.releaseOpen(2)
        _ = await second.value
        _ = await third.value
    }

    private func fixtureURL(name: String) throws -> URL {
        let bundle = Bundle(for: ThumbnailCacheTests.self)
        let pathExtension = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        if let url = bundle.url(
            forResource: base,
            withExtension: pathExtension,
            subdirectory: "ImageGallery"
        ) {
            return url
        }
        guard let url = bundle.url(forResource: base, withExtension: pathExtension) else {
            throw NSError(domain: "ThumbnailCacheTests", code: 1)
        }
        return url
    }

    func testSidecarHitAvoidsOriginalByteSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        let sidecarRoot = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailSidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: sidecarRoot)
        }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 4 * 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = FixtureProvider(name: "sample.jpg")
        let sidecar = SharedThumbnailCache(
            provider: LocalThumbnailSidecar(rootURL: sidecarRoot)
        )
        let data = try Data(contentsOf: try fixtureURL(name: "sample.jpg"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "Photos/sidecar-\(UUID().uuidString).jpg"

        await sidecar.store(
            thumbnailData: data,
            width: 10,
            height: 10,
            path: path,
            size: 1,
            modified: date
        )
        await sidecar.flush()

        let outcome = await service.thumbnail(
            path: path,
            size: 1,
            modified: date,
            namespace: "sidecar-test",
            contentKind: .image,
            sidecar: sidecar,
            provider: provider
        )

        XCTAssertEqual(outcome?.data, data)
        let opens = await provider.openCount()
        XCTAssertEqual(opens, 0, "侧车命中时不得打开原图字节源")
    }

    func testGeneratedThumbnailWritesBackToSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        let sidecarRoot = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailSidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: sidecarRoot)
        }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 4 * 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = FixtureProvider(name: "sample.jpg")
        let sidecar = SharedThumbnailCache(
            provider: LocalThumbnailSidecar(rootURL: sidecarRoot)
        )
        let path = "Photos/generated-\(UUID().uuidString).jpg"
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let outcome = await service.thumbnail(
            path: path,
            size: 1,
            modified: date,
            namespace: "sidecar-test",
            contentKind: .image,
            sidecar: sidecar,
            provider: provider
        )
        XCTAssertNotNil(outcome)

        let entry = await sidecar.entry(for: path)
        XCTAssertNotNil(entry?.thumb, "生成后应写入侧车索引")
        let hit = await sidecar.thumbnail(path: path, size: 1, modified: date)
        XCTAssertNotNil(hit)
    }

    func testCorruptSidecarFallsBackToOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        let sidecarRoot = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailSidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: sidecarRoot)
        }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 4 * 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = FixtureProvider(name: "sample.jpg")
        let sidecar = SharedThumbnailCache(
            provider: LocalThumbnailSidecar(rootURL: sidecarRoot)
        )
        let path = "Photos/corrupt-\(UUID().uuidString).jpg"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await sidecar.store(
            thumbnailData: Data([0, 1, 2, 3]),
            width: 10,
            height: 10,
            path: path,
            size: 1,
            modified: date
        )
        await sidecar.flush()

        let outcome = await service.thumbnail(
            path: path,
            size: 1,
            modified: date,
            namespace: "sidecar-test",
            contentKind: .image,
            sidecar: sidecar,
            provider: provider
        )

        XCTAssertNotNil(outcome, "损坏侧车应回退原图")
        let opens = await provider.openCount()
        XCTAssertEqual(opens, 1)
        let hit = await sidecar.thumbnail(path: path, size: 1, modified: date)
        XCTAssertNotEqual(hit, Data([0, 1, 2, 3]), "损坏侧车应被删除并替换为新缩略图")
    }

    func testImageThumbnailFallsBackToFullReadWhenRemoteDecodeFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 4 * 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = OversizedReadFailingProvider(name: "sample.jpg")

        let outcome = await service.thumbnail(
            path: "Photos/fallback.jpg",
            size: 1,
            modified: nil,
            contentKind: .image,
            provider: provider
        )

        XCTAssertNotNil(outcome, "按需分段解码失败后应能回退整图解码")
        let opens = await provider.openCount()
        XCTAssertEqual(opens, 2, "回退应换新句柄整图重试一次")
    }

    func testLivePhotoThumbnailUsesStillEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 4 * 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = FixtureProvider(name: "sample-stored.livp")

        let outcome = await service.thumbnail(
            path: "Photos/IMG_0001.LIVP",
            size: 1,
            modified: nil,
            contentKind: .livePhoto,
            provider: provider
        )
        XCTAssertNotNil(outcome)
        XCTAssertGreaterThan(outcome?.data.count ?? 0, 0)
    }
}

/// 每次 open 都阻塞，直到测试显式放行，用来稳定复现 in-flight 竞态。
private actor GatedProvider: ThumbnailByteSourceProvider {
    private let url: URL
    private var opens = 0
    private var released: Set<Int> = []
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(url: URL) {
        self.url = url
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        try LocalFileByteSource(url: url)
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        opens += 1
        let index = opens
        wakeWaiters()
        if !released.contains(index) {
            await withCheckedContinuation { gates[index] = $0 }
        }
        return try LocalFileByteSource(url: url)
    }

    func openCount() -> Int { opens }

    func waitForOpenCount(_ count: Int) async {
        guard opens < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func releaseOpen(_ index: Int) {
        released.insert(index)
        gates.removeValue(forKey: index)?.resume()
    }

    private func wakeWaiters() {
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if opens >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

private actor FixtureProvider: ThumbnailByteSourceProvider {
    private let url: URL
    private var opens = 0

    init(name: String) {
        let bundle = Bundle(for: FixtureProvider.self)
        let pathExtension = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        self.url = bundle.url(
            forResource: base,
            withExtension: pathExtension,
            subdirectory: "ImageGallery"
        ) ?? bundle.url(forResource: base, withExtension: pathExtension)!
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        try LocalFileByteSource(url: url)
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        opens += 1
        return try LocalFileByteSource(url: url)
    }

    func openCount() -> Int { opens }
}

/// 模拟 ImageIO 通过远程数据源做首读：大窗口读返回空，顺序整图读取正常。
private actor OversizedReadFailingProvider: ThumbnailByteSourceProvider {
    private let data: Data
    private var opens = 0

    init(name: String) {
        let bundle = Bundle(for: OversizedReadFailingProvider.self)
        let pathExtension = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let url = bundle.url(
            forResource: base,
            withExtension: pathExtension,
            subdirectory: "ImageGallery"
        ) ?? bundle.url(forResource: base, withExtension: pathExtension)!
        self.data = (try? Data(contentsOf: url)) ?? Data()
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        OversizedReadFailingByteSource(data: data)
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        opens += 1
        return OversizedReadFailingByteSource(data: data)
    }

    func openCount() -> Int { opens }
}

private struct OversizedReadFailingByteSource: ByteSource {
    let data: Data

    var length: Int64? { Int64(data.count) }

    func read(at offset: Int64, count: Int) async throws -> Data {
        guard count <= data.count else { return Data() }
        let start = Int(offset)
        guard start < data.count else { return Data() }
        let end = min(data.count, start + count)
        return data.subdata(in: start..<end)
    }

    func close() async {}
}

private actor FailingProvider: ThumbnailByteSourceProvider {
    private var opens = 0

    func openByteSource(path: String) async throws -> any ByteSource {
        opens += 1
        throw ByteSourceError.underlying("测试用失败")
    }

    func openCount() -> Int { opens }
}
