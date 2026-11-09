import Foundation
import IceCore
import Network

public struct SMBShare: Sendable, Identifiable, Hashable {
    public let name: String
    public let comment: String

    public var id: String { name }

    public init(name: String, comment: String) {
        self.name = name
        self.comment = comment
    }
}

/// 目录条目。媒体库只关心这几项，因此收敛为强类型，避免上层接触 URLResourceKey 字典。
public struct SMBEntry: Sendable, Identifiable, Hashable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public var id: String { name }

    public init(name: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// 连接类错误。刻意区分「名称解析失败」与「主机不可达」，
/// 因为局域网里这两者的处置方式完全不同（换名称 vs 查网络）。
public enum SMBConnectionError: LocalizedError, Sendable {
    case invalidAddress(String)
    case nameNotResolved(String)
    case unreachable(String)
    case authenticationFailed(String)
    case staleHandle(String)
    case notConnected
    case failed(String)

    /// 认证与地址类错误重试没有意义；网络与句柄类错误可以尝试重连后重试一次。
    public var isRecoverable: Bool {
        switch self {
        case .authenticationFailed, .invalidAddress, .nameNotResolved:
            false
        case .unreachable, .staleHandle, .notConnected, .failed:
            true
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let value):
            "地址格式无效：\(value)"
        case .nameNotResolved(let value):
            "无法解析主机名「\(value)」，可尝试改用 IP 地址或补全 .local 后缀"
        case .unreachable(let detail):
            "主机不可达，请检查网络与主机电源：\(detail)"
        case .authenticationFailed(let detail):
            "认证失败，请检查用户名与密码：\(detail)"
        case .staleHandle(let detail):
            "文件句柄已失效，会话可能已断开：\(detail)"
        case .notConnected:
            "尚未连接共享"
        case .failed(let detail):
            "连接失败：\(detail)"
        }
    }
}

/// SMB 会话。持有单条连接，负责心跳、退避重连与读写重试。
public actor SMBClient {
    private struct SessionCredentials: Sendable {
        let address: SMBHostAddress
        let user: String
        let password: String
        let share: String
    }

    private var manager: SMB2Manager?
    private var connectedShare: String?
    private var connectedHost: String?
    private var session: SessionCredentials?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var state: SMBSessionState = .idle
    private let readScheduler = SMBReadScheduler(label: "smb-read")

    private let heartbeatInterval: Duration
    private let reconnectPolicy: SMBReconnectPolicy

    public init(
        heartbeatInterval: Duration = .seconds(20),
        reconnectPolicy: SMBReconnectPolicy = SMBReconnectPolicy(),
        readLimitKBps: Int = 0
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.reconnectPolicy = reconnectPolicy
        readScheduler.setLimit(bytesPerSecond: max(0, readLimitKBps) * 1024)
    }

    public func currentState() -> SMBSessionState { state }

    /// 仅用于带宽验收：动态调整总读取速率。
    public func setReadLimit(kbps: Int) {
        readScheduler.setLimit(bytesPerSecond: max(0, kbps) * 1024)
    }

    // MARK: - 会话

    /// 建立到指定共享的会话。地址可以是 IP、DNS 名、`.local` 名称或带 `smb://` 前缀的完整 URL。
    public func connect(host: String, user: String, password: String, share: String) async throws {
        let (address, url) = try await prepareEndpoint(input: host)
        let targetShare = share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .isEmpty ? (address.share ?? share) : share
        Log.info(.smb, "开始连接 host=\(address.raw) share=\(targetShare) user=\(user)")
        let began = Date()

        await disconnect()
        let credential = URLCredential(user: user, password: password, persistence: .forSession)
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            Log.error(.smb, "无法构造会话 host=\(address.raw)")
            throw SMBConnectionError.invalidAddress(address.raw)
        }

        do {
            try await manager.connectShare(name: targetShare)
            self.manager = manager
            self.connectedShare = targetShare
            self.connectedHost = address.raw
            self.session = SessionCredentials(
                address: address,
                user: user,
                password: password,
                share: targetShare
            )
            state = .connected
            startHeartbeat()
            Log.info(.smb, "共享已连接 share=\(targetShare) 耗时=\(Self.milliseconds(since: began))")
        } catch {
            Self.logRaw(error)
            var mapped = Self.map(error, host: address.raw)
            // libsmb2 在端口未监听时常把底层失败折叠成 EPERM，单看错误码无法与协议问题区分。
            // 只有在归类为「连接失败」时补一次 TCP 探测，避免把主机不可达误报成认证/权限问题。
            if case .failed(let detail) = mapped {
                let reachable = await Self.isTCPReachable(
                    host: address.host,
                    port: UInt16(address.port ?? 445)
                )
                if !reachable {
                    mapped = .unreachable("TCP \(address.endpointDescription):445 无响应（\(detail)）")
                }
            }
            state = .failed(mapped.localizedDescription)
            Log.error(.smb, "连接失败 \(mapped.localizedDescription) 耗时=\(Self.milliseconds(since: began))")
            throw mapped
        }
    }

    /// 用当前会话的凭据枚举主机上的共享。已连接共享会包含在结果中。
    public func listShares() async throws -> [SMBShare] {
        guard let session else { throw SMBConnectionError.notConnected }
        return try await listShares(
            host: session.address.raw,
            user: session.user,
            password: session.password
        )
    }

    /// 在同一主机上切换到另一个共享，复用已保存的凭据。
    /// 失败时尝试回到原共享，避免把媒体库留在“已断开”状态。
    public func changeShare(_ share: String) async throws {
        guard let session else { throw SMBConnectionError.notConnected }
        let target = share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !target.isEmpty, target != session.share else { return }
        do {
            try await connect(
                host: session.address.raw,
                user: session.user,
                password: session.password,
                share: target
            )
        } catch {
            Log.error(.smb, "切换共享失败 target=\(target)，尝试回到 \(session.share)")
            try? await connect(
                host: session.address.raw,
                user: session.user,
                password: session.password,
                share: session.share
            )
            throw error
        }
    }

    public func disconnect() async {
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        heartbeatTask = nil
        reconnectTask = nil
        session = nil
        state = .idle
        readScheduler.cancelAll(error: .disconnected)
        guard let manager else { return }
        self.manager = nil
        connectedShare = nil
        connectedHost = nil
        try? await manager.disconnectShare(gracefully: false)
        Log.info(.smb, "会话已断开")
    }

    /// 仅用于诊断：关闭底层连接但保留会话凭据，让心跳走真实的失败→退避→重连路径。
    public func simulateDropForTesting() async {
        guard let manager else { return }
        Log.notice(.smb, "模拟掉线：主动关闭底层连接，等待心跳检测")
        try? await manager.disconnectShare(gracefully: false)
    }

    // MARK: - 心跳与重连

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.heartbeatInterval)
                guard !Task.isCancelled else { return }
                await self.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() async {
        guard let manager, state.isConnected else { return }
        do {
            try await manager.echo()
            Log.debug(.smb, "心跳成功 host=\(connectedHost ?? "-")")
        } catch {
            Log.notice(.smb, "心跳失败，进入自动重连 \(error.localizedDescription)")
            state = .reconnecting(attempt: 0)
            await reconnectWithBackoff()
            if !state.isConnected {
                // 重连失败：停掉心跳，保留界面状态，等待用户手动重连。
                heartbeatTask?.cancel()
            }
        }
    }

    private func reconnectWithBackoff() async {
        guard let session else { return }
        if let existing = reconnectTask {
            await existing.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runReconnectLoop(session: session)
        }
        reconnectTask = task
        await task.value
        reconnectTask = nil
    }

    private func runReconnectLoop(session: SessionCredentials) async {
        for attempt in 1...max(1, reconnectPolicy.maxAttempts) {
            guard let delay = reconnectPolicy.delay(forAttempt: attempt) else { break }
            state = .reconnecting(attempt: attempt)
            Log.notice(
                .smb,
                "重连退避 attempt=\(attempt)/\(reconnectPolicy.maxAttempts) 间隔=\(delay)s"
            )
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }

            do {
                let manager = try await makeManager(session: session)
                self.manager = manager
                connectedHost = session.address.raw
                connectedShare = session.share
                state = .connected
                Log.info(.smb, "重连成功 attempt=\(attempt) host=\(session.address.raw)")
                return
            } catch {
                let mapped = Self.map(error, host: session.address.raw)
                if !mapped.isRecoverable {
                    state = .failed(mapped.localizedDescription)
                    Log.error(.smb, "重连停止：\(mapped.localizedDescription)")
                    return
                }
                Log.error(
                    .smb,
                    "重连失败 attempt=\(attempt) \(mapped.localizedDescription)"
                )
            }
        }
        state = .failed("连续 \(reconnectPolicy.maxAttempts) 次重连失败")
        Log.error(.smb, "重连停止：达到最大尝试次数")
    }

    /// 请求级修复：只尝试一次，成功后就地恢复，避免目录请求等待完整退避。
    private func reconnectNow() async throws {
        guard let session else { throw SMBConnectionError.notConnected }
        do {
            let manager = try await makeManager(session: session)
            self.manager = manager
            connectedHost = session.address.raw
            connectedShare = session.share
            state = .connected
            startHeartbeat()
            Log.info(.smb, "按请求重连成功 host=\(session.address.raw)")
        } catch {
            let mapped = Self.map(error, host: session.address.raw)
            state = .failed(mapped.localizedDescription)
            throw mapped
        }
    }

    private func makeManager(session: SessionCredentials) async throws -> SMB2Manager {
        guard let url = session.address.url else {
            throw SMBConnectionError.invalidAddress(session.address.raw)
        }
        let credential = URLCredential(
            user: session.user,
            password: session.password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            throw SMBConnectionError.invalidAddress(session.address.raw)
        }
        try await manager.connectShare(name: session.share)
        return manager
    }

    private func ensureManager() async throws {
        if manager != nil { return }
        guard session != nil else { throw SMBConnectionError.notConnected }
        try await reconnectNow()
    }

    /// 读取层发现句柄失效时调用：先尝试用当前会话重开，失败则重连一次再开。
    private func reopenHandle(path: String) async throws -> SMBHandleBox {
        if let manager, let client = manager.client {
            if let handle = try? SMB2FileHandle(forReadingAtPath: path, on: client) {
                Log.info(.smb, "重开文件句柄 \(Log.shortPath(path))")
                return SMBHandleBox(handle: handle)
            }
        }

        Log.notice(.smb, "句柄失效且当前会话不可用，重连后重开 \(Log.shortPath(path))")
        try await reconnectNow()
        guard let manager, let client = manager.client else {
            throw SMBConnectionError.notConnected
        }
        do {
            let handle = try SMB2FileHandle(forReadingAtPath: path, on: client)
            Log.info(.smb, "重连后重开文件句柄 \(Log.shortPath(path))")
            return SMBHandleBox(handle: handle)
        } catch {
            let mapped = Self.map(error, host: connectedHost ?? "")
            throw mapped
        }
    }

    // MARK: - 枚举

    /// 列出共享内指定目录的条目。共享根目录传空字符串。
    public func listDirectory(path: String = "") async throws -> [SMBEntry] {
        try await ensureManager()
        do {
            return try await fetchDirectory(path: path)
        } catch {
            let mapped = (error as? SMBConnectionError) ?? Self.map(error, host: connectedHost ?? "")
            guard mapped.isRecoverable else { throw mapped }
            Log.notice(.smb, "目录枚举失败，重连后重试一次 path=\(Log.shortPath(path.isEmpty ? "/" : path))")
            try await reconnectNow()
            return try await fetchDirectory(path: path)
        }
    }

    private func fetchDirectory(path: String) async throws -> [SMBEntry] {
        guard let manager else { throw SMBConnectionError.notConnected }
        let began = Date()
        let shown = path.isEmpty ? "/" : path

        do {
            let items = try await manager.contentsOfDirectory(atPath: path)
            let entries = items.compactMap(Self.makeEntry)
            Log.info(.smb, "目录枚举成功 path=\(shown) 数量=\(entries.count) 耗时=\(Self.milliseconds(since: began))")
            return entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            Self.logRaw(error)
            let mapped = Self.map(error, host: connectedHost ?? "")
            Log.error(.smb, "目录枚举失败 path=\(shown) \(mapped.localizedDescription)")
            throw mapped
        }
    }

    /// 打开共享内的文件作为随机可读字节源。默认按播放优先级读取。
    public func openByteSource(path: String) async throws -> any ByteSource {
        try await openByteSource(path: path, priority: .playback)
    }

    public func openByteSource(path: String, priority: SMBReadPriority) async throws -> any ByteSource {
        try await ensureManager()
        do {
            return try openSource(path: path, priority: priority)
        } catch {
            let mapped = (error as? SMBConnectionError) ?? Self.map(error, host: connectedHost ?? "")
            guard mapped.isRecoverable else { throw mapped }
            Log.notice(.smb, "打开文件失败，重连后重试一次 \(Log.shortPath(path))")
            try await reconnectNow()
            return try openSource(path: path, priority: priority)
        }
    }

    private func openSource(path: String, priority: SMBReadPriority) throws -> any ByteSource {
        guard let manager, let client = manager.client else {
            throw SMBConnectionError.notConnected
        }
        do {
            let handle = try SMB2FileHandle(forReadingAtPath: path, on: client)
            let size = (try? handle.fstat().smb2_size).map(Int64.init)
            let reopen = SMBHandleProvider { [weak self] in
                guard let self else { throw SMBConnectionError.notConnected }
                return try await self.reopenHandle(path: path)
            }
            Log.info(
                .smb,
                "已打开文件 \(Log.shortPath(path)) 大小=\(size ?? -1) 优先级=\(priority.label)"
            )
            // 播放用 4MB 块 + 512MB 预读环：8GB 设备内存充足，提前把更多内容读进内存；
            // 只占内存、不扩硬盘缓存。字幕/抽帧仍用小块，避免长时间占用读线程。
            let chunkSize: Int
            let ringCapacity: Int
            switch priority {
            case .thumbnail:
                chunkSize = 256 * 1024
                ringCapacity = 8
            case .playback:
                chunkSize = 4 * 1024 * 1024
                ringCapacity = 128
            default:
                chunkSize = 1 << 20
                ringCapacity = 24
            }
            return SMBFileByteSource(
                handle: handle,
                length: size,
                reopen: reopen,
                scheduler: readScheduler,
                priority: priority,
                chunkSize: chunkSize,
                ringCapacity: ringCapacity
            )
        } catch {
            Self.logRaw(error)
            let mapped = Self.map(error, host: connectedHost ?? "")
            Log.error(.smb, "打开文件失败 \(Log.shortPath(path)) \(mapped.localizedDescription)")
            throw mapped
        }
    }

    /// 枚举服务器上的共享。部分 Windows 配置不允许普通账号通过 IPC$ 枚举，因此仅作辅助入口。
    public func listShares(host: String, user: String, password: String) async throws -> [SMBShare] {
        let (address, url) = try await prepareEndpoint(input: host)
        Log.info(.smb, "开始枚举共享 host=\(address.raw) user=\(user)")
        let began = Date()

        let credential = URLCredential(user: user, password: password, persistence: .forSession)
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            throw SMBConnectionError.invalidAddress(address.raw)
        }

        do {
            let shares = try await manager.listShares()
            Log.info(.smb, "共享枚举成功 数量=\(shares.count) 耗时=\(Self.milliseconds(since: began))")
            return shares.map { SMBShare(name: $0.name, comment: $0.comment) }
        } catch {
            Self.logRaw(error)
            let mapped = Self.map(error, host: address.raw)
            Log.error(.smb, "共享枚举失败 \(mapped.localizedDescription)")
            throw mapped
        }
    }

    // MARK: - 诊断

    /// 诊断用：直接探测 TCP 端口，区分「网络被拦」与「协议层失败」。
    public func probeTCP(host: String, port: UInt16 = 445) async -> String {
        let box = ProbeBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: "端口无效")
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.wangzicheng.icemovie.probe")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish("TCP \(host):\(port) 可达", continuation, connection)
                case .failed(let error):
                    box.finish("TCP 失败 \(error)", continuation, connection)
                case .waiting(let error):
                    box.finish("TCP 等待 \(error)", continuation, connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) {
                box.finish("TCP 超时", continuation, connection)
            }
        }
    }

    /// 连接失败后的补充判定：主机端口是否可达。
    static func isTCPReachable(host: String, port: UInt16, timeout: TimeInterval = 3) async -> Bool {
        let box = ReachabilityBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.wangzicheng.icemovie.reachability")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(true, continuation, connection)
                case .failed, .waiting:
                    box.finish(false, continuation, connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                box.finish(false, continuation, connection)
            }
        }
    }

    // MARK: - 内部

    /// 归一化地址并重新解析名称。每次连接都走同一条路径，不缓存 IP（design.md D11）。
    private func prepareEndpoint(input: String) async throws -> (SMBHostAddress, URL) {
        let address: SMBHostAddress
        do {
            address = try SMBHostAddress(input)
        } catch {
            Log.error(.smb, "地址格式无效 input=\(input) \(error.localizedDescription)")
            throw SMBConnectionError.invalidAddress(input)
        }

        Log.info(
            .smb,
            "地址归一化 raw=\(address.raw) host=\(address.host) port=\(address.port.map(String.init) ?? "默认") "
                + "share=\(address.share ?? "-")"
        )

        let began = Date()
        do {
            let addresses = try await SMBHostResolver.resolveAsync(address)
            Log.info(
                .smb,
                "名称解析成功 host=\(address.host) -> \(addresses.joined(separator: ",")) "
                    + "耗时=\(Self.milliseconds(since: began))"
            )
        } catch {
            Log.error(
                .smb,
                "名称解析失败 host=\(address.host) 耗时=\(Self.milliseconds(since: began)) "
                    + "\(error.localizedDescription)"
            )
            throw error
        }

        guard let url = address.url else {
            throw SMBConnectionError.invalidAddress(address.raw)
        }
        return (address, url)
    }

    static func makeEntry(_ item: [URLResourceKey: Any]) -> SMBEntry? {
        guard let name = item[.nameKey] as? String, !name.isEmpty else { return nil }
        let type = item[.fileResourceTypeKey] as? URLFileResourceType
        let size = (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
        let modified = item[.contentModificationDateKey] as? Date
        return SMBEntry(name: name, isDirectory: type == .directory, size: size, modified: modified)
    }

    static func logRaw(_ error: any Error) {
        let raw = error as NSError
        Log.notice(.smb, "原始错误 domain=\(raw.domain) code=\(raw.code) desc=\(raw.localizedDescription)")
    }

    static func map(_ error: any Error, host: String) -> SMBConnectionError {
        let nsError = error as NSError
        let text = nsError.localizedDescription
        let lowered = text.lowercased()

        // libsmb2 把 STATUS_LOGON_FAILURE 映射成 ECONNREFUSED，仅凭 errno 无法与
        // 「端口没开」区分，所以先看原始描述里的 NT 状态，再做 errno 分类。
        if text.contains("LOGON_FAILURE") || text.contains("0xc000006d") {
            return .authenticationFailed(text)
        }

        if text.contains("INVALID_HANDLE") || text.contains("FILE_CLOSED")
            || text.contains("0xc0000008") || text.contains("0xc0000128") {
            return .staleHandle(text)
        }

        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ECONNREFUSED), Int(ETIMEDOUT), Int(EHOSTUNREACH), Int(ENETUNREACH), Int(ENETDOWN):
                return .unreachable(text)
            case Int(EACCES):
                return .authenticationFailed(text)
            case Int(EPERM):
                // EPERM 在 libsmb2 里通常是「连接阶段同步失败」的兜底值，
                // 并不代表密码错误，单独归类避免误导排查方向。
                return .failed("底层返回 EPERM，多为协议协商或权限问题，而非密码错误")
            default:
                break
            }
        }

        if lowered.contains("logon") || lowered.contains("password") || lowered.contains("credential")
            || lowered.contains("access denied") {
            return .authenticationFailed(text)
        }
        if lowered.contains("resolve") || lowered.contains("name or service") || lowered.contains("nodename") {
            return .nameNotResolved(host)
        }
        return .failed(text)
    }

    static func milliseconds(since date: Date) -> String {
        String(format: "%.0fms", Date().timeIntervalSince(date) * 1000)
    }
}

final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func finish(
        _ message: String,
        _ continuation: CheckedContinuation<String, Never>,
        _ connection: NWConnection
    ) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: message)
    }
}

final class ReachabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func finish(
        _ reachable: Bool,
        _ continuation: CheckedContinuation<Bool, Never>,
        _ connection: NWConnection
    ) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: reachable)
    }
}
