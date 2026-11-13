import AVFAudio
import IceCore
import MediaLibraryKit
import PersistenceKit
import RenderKit
import SMBSession
import SubtitleKit
import SwiftData
import SwiftUI
import ThumbnailKit
import UIKit

/// 工程骨架阶段的占位界面。
/// 媒体库与播放器接入后由 Shell 层按可用宽度替换为单栈或分栏结构。
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    private let credentials = KeychainCredentialStore()

    // 便于自动化与排查：以 -diagnostics 启动参数直接打开诊断页。
    @State private var showDiagnostics = ProcessInfo.processInfo.arguments.contains("-diagnostics")
    @State private var videoSession = VideoTestSession.shared
    @State private var libraryStore: LibraryStore?
    @State private var photoSyncModel: PhotoSyncModel?
    @State private var isRestoringConnection = false
    @State private var connectionPrefill: ConnectionPrefill?
    @State private var connectionMessage: String?
    @State private var playerFullscreen = false

    var body: some View {
        Group {
            if let engine = videoSession.engine, let renderer = engine.videoRenderer {
                PlayerScreen(
                    engine: engine,
                    renderer: renderer,
                    label: videoSession.label,
                    subtitle: videoSession.subtitle,
                    isFullscreen: playerFullscreen,
                    onToggleFullscreen: { playerFullscreen.toggle() }
                )
            } else if let libraryStore, let photoSyncModel {
                LibraryView(store: libraryStore, photoSync: photoSyncModel) {
                    photoSyncModel.cancelForDisconnect()
                    self.photoSyncModel = nil
                    self.libraryStore = nil
                    self.connectionMessage = nil
                }
            } else if isRestoringConnection {
                restoringPage
            } else {
                connectionPage
            }
        }
        .task {
            SubtitlePreferences.migrateIfNeeded()
            await bootstrap()
        }
    }

    private var restoringPage: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在恢复上次连接…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var connectionPage: some View {
        NavigationStack {
            ConnectionView(
                records: HostRecordStore(context: modelContext),
                credentials: credentials,
                prefill: connectionPrefill,
                initialMessage: connectionMessage
            ) { connection in
                openLibrary(connection)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("诊断日志")
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
        }
    }

    private func bootstrap() async {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        Log.info(.app, "启动 idiom=\(idiom) supportsMultipleScenes=\(UIApplication.shared.supportsMultipleScenes)")

        do {
            try await PlaybackAudioSession.activate()
            let session = AVAudioSession.sharedInstance()
            Log.info(.app, "音频会话就绪 category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
        } catch {
            Log.error(.app, "音频会话初始化失败：\(error.localizedDescription)")
        }

        let arguments = ProcessInfo.processInfo.arguments
        writeLaunchSnapshot(arguments)
        if arguments.contains("-resetSubtitlePreferences") {
            SubtitlePreferences.reset()
            Log.info(.subtitle, "字幕偏好已重置（自检）")
        }
        if arguments.contains("-resetPlaybackProgress") {
            PlaybackProgressStore(context: modelContext).removeAll()
            Log.info(.app, "续播记录已重置（自检）")
        }
        if arguments.contains("-photoSyncResetTarget") {
            try? PhotoLibraryTargetStore(context: modelContext).removeAll()
            if let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) {
                try? FileManager.default.removeItem(
                    at: support.appendingPathComponent("PhotoSync", isDirectory: true)
                )
            }
            Log.info(.app, "照片同步目标与清单已重置（自检）")
        }
        if arguments.contains("-resetAcceptanceReport") {
            let url = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("ice-acceptance.json")
            try? FileManager.default.removeItem(at: url)
            Log.info(.app, "验收报告已清空")
        }
        if arguments.contains("-debugLog") || arguments.contains("-logDebug") {
            Log.minimumLevel = .debug
            Log.enableFileLogging()
        }
        if arguments.contains("-landscape") || arguments.contains("-portrait") {
            requestOrientation(landscape: arguments.contains("-landscape"))
        }
        if let seedHost = value(for: "-seedHost", in: arguments) {
            seedHostRecord(
                host: seedHost,
                share: value(for: "-seedShare", in: arguments) ?? "",
                path: value(for: "-seedPath", in: arguments) ?? "",
                user: value(for: "-seedUser", in: arguments) ?? "",
                password: value(for: "-seedPassword", in: arguments) ?? ""
            )
        }
        if let forgetHost = value(for: "-forgetHost", in: arguments) {
            forgetHostRecord(host: forgetHost)
        }
        if arguments.contains("-smbWriteProbe"),
           let host = value(for: "-smbHost", in: arguments),
           let share = value(for: "-smbShare", in: arguments) {
            let directory = value(for: "-libraryPath", in: arguments) ?? ""
            let credential = savedCredential(for: host)
            Task {
                await SMBWriteSelfTest.run(
                    host: host,
                    share: share,
                    directory: directory,
                    credential: credential
                )
            }
        }
        if arguments.contains("-photoSyncSMBProbe"),
           let host = value(for: "-smbHost", in: arguments),
           let share = value(for: "-smbShare", in: arguments) {
            let explicitUser = value(for: "-smbUser", in: arguments)
            let explicitPassword = value(for: "-smbPassword", in: arguments)
            let credential = (explicitUser == nil && explicitPassword == nil)
                ? savedCredential(for: host)
                : nil
            if let user = explicitUser ?? credential?.username,
               let password = explicitPassword ?? credential?.password {
                Task {
                    await PhotoSyncSMBWriteSelfTest.run(
                        host: host,
                        share: share,
                        user: user,
                        password: password
                    )
                }
            } else {
                Log.error(
                    .smb,
                    "PHOTOSYNC_SMB_PROBE 跳过：没有可用的 SMB 凭据 host=\(host)"
                )
            }
        }
        if arguments.contains("-photoSyncFixture"),
           value(for: "-libraryLocal", in: arguments) == nil {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let prefix = "PhotoSyncFixtureLibrary-"
            if let old = try? FileManager.default.contentsOfDirectory(
                at: documents,
                includingPropertiesForKeys: nil
            ) {
                for url in old where url.lastPathComponent.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let root = documents.appendingPathComponent(
                "\(prefix)\(UUID().uuidString)",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("Sub", isDirectory: true),
                withIntermediateDirectories: true
            )
            let localSource = LocalLibrarySource(rootURL: root)
            let source: any LibrarySource = arguments.contains("-photoSyncUnwritableTarget")
                ? UnwritablePhotoSyncSource(base: localSource)
                : localSource
            installLibrary(source: source, initialPath: "")
        } else if let localPath = value(for: "-libraryLocal", in: arguments) {
            installLibrary(
                source: LocalLibrarySource(rootURL: URL(fileURLWithPath: localPath)),
                initialPath: value(for: "-libraryPath", in: arguments) ?? ""
            )
        } else if let host = value(for: "-smbHost", in: arguments),
                  let share = value(for: "-smbShare", in: arguments),
                  arguments.contains("-library") {
            let heartbeatSeconds = value(for: "-smbHeartbeatSeconds", in: arguments)
                .flatMap(Double.init) ?? 20
            let readLimitKBps = value(for: "-smbReadLimitKBps", in: arguments)
                .flatMap(Int.init) ?? 0
            // 真机自动化不要传明文密码：只有 user/password 都没给时才复用
            // 设备上已保存的连接，避免把 A 账号的密码配给 B 账号。
            let explicitUser = value(for: "-smbUser", in: arguments)
            let explicitPassword = value(for: "-smbPassword", in: arguments)
            let hasExplicitUser = explicitUser != nil
            let hasExplicitPassword = explicitPassword != nil
            if hasExplicitUser != hasExplicitPassword {
                Log.notice(
                    .app,
                    "SMB 启动参数凭据不完整 host=\(host) "
                        + "user=\(hasExplicitUser ? "有" : "无") "
                        + "password=\(hasExplicitPassword ? "有" : "无")"
                )
            }
            let savedCredential = (!hasExplicitUser && !hasExplicitPassword)
                ? savedCredential(for: host)
                : nil
            installLibrary(
                source: SMBLibrarySource(
                    host: host,
                    share: share,
                    user: explicitUser ?? savedCredential?.username ?? "",
                    password: explicitPassword ?? savedCredential?.password ?? "",
                    heartbeatInterval: .seconds(max(1, heartbeatSeconds)),
                    readLimitKBps: readLimitKBps
                ),
                initialPath: value(for: "-libraryPath", in: arguments)
                    ?? value(for: "-smbPath", in: arguments)
                    ?? ""
            )
        } else if shouldAttemptAutoRestore(in: arguments) {
            await restoreLastSession()
        }
        if let index = arguments.firstIndex(of: "-demuxTest"), arguments.indices.contains(index + 1) {
            await DemuxSelfTest.run(path: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "-thumbnailProbe"), arguments.indices.contains(index + 1) {
            let raw = value(for: "-thumbnailPositions", in: arguments) ?? "0,10,60,120,142,300,600"
            let positions = raw.split(separator: ",").compactMap { Double($0) }
            Task.detached {
                await DemuxSelfTest.probeThumbnails(path: arguments[index + 1], positions: positions)
            }
        }
        if let index = arguments.firstIndex(of: "-audioTest"), arguments.indices.contains(index + 1) {
            let seconds = value(for: "-audioTestSeconds", in: arguments).flatMap(Double.init) ?? 60
            let path = arguments[index + 1]
            Task.detached { await AudioSelfTest.run(path: path, targetSeconds: seconds) }
        }
        if let index = arguments.firstIndex(of: "-audioPauseTest"), arguments.indices.contains(index + 1) {
            let path = arguments[index + 1]
            Task.detached { await AudioSelfTest.runPauseTest(path: path) }
        }
        if let videoPath = value(for: "-subtitleOverlay", in: arguments),
           let sub = value(for: "-subtitleFile", in: arguments) {
            let seconds = value(for: "-videoTestSeconds", in: arguments).flatMap(Double.init) ?? 12
            let format = value(for: "-subtitleFormat", in: arguments) ?? "ass"
            Task.detached {
                await SubtitleOverlayTest.run(video: videoPath, subtitle: sub, format: format, seconds: seconds)
            }
        }
        if let index = arguments.firstIndex(of: "-embeddedSubtitleTest"), arguments.indices.contains(index + 1) {
            let path = arguments[index + 1]
            Task.detached { await SubtitleSelfTest.runEmbedded(path: path) }
        }
        if let index = arguments.firstIndex(of: "-subtitleScan"), arguments.indices.contains(index + 1) {
            Task.detached {
                await SubtitleSelfTest.runOverSMB(
                    host: value(for: "-smbHost", in: arguments) ?? "",
                    share: value(for: "-smbShare", in: arguments) ?? "",
                    path: arguments[index + 1],
                    user: value(for: "-smbUser", in: arguments) ?? "",
                    password: value(for: "-smbPassword", in: arguments) ?? ""
                )
            }
        }
        if let index = arguments.firstIndex(of: "-seekBurstTest"), arguments.indices.contains(index + 1) {
            let path = arguments[index + 1]
            Task.detached { await SeekBurstTest.run(path: path) }
        }
        if let index = arguments.firstIndex(of: "-seekTest"), arguments.indices.contains(index + 1) {
            let raw = value(for: "-seekTargets", in: arguments) ?? "60,300,600"
            let targets = raw.split(separator: ",").compactMap { Double($0) }
            let path = arguments[index + 1]
            Task.detached { await SeekSelfTest.run(path: path, targets: targets) }
        }
        if let index = arguments.firstIndex(of: "-videoSmb"), arguments.indices.contains(index + 1) {
            let seconds = value(for: "-videoTestSeconds", in: arguments).flatMap(Double.init) ?? 30
            let path = arguments[index + 1]
            let host = value(for: "-smbHost", in: arguments) ?? ""
            let share = value(for: "-smbShare", in: arguments) ?? ""
            let user = value(for: "-smbUser", in: arguments) ?? ""
            let password = value(for: "-smbPassword", in: arguments) ?? ""
            Task.detached {
                await VideoSelfTest.runOverSMB(
                    host: host, share: share, path: path,
                    user: user, password: password, seconds: seconds
                )
            }
        }
        if let index = arguments.firstIndex(of: "-videoTest"), arguments.indices.contains(index + 1) {
            let seconds = value(for: "-videoTestSeconds", in: arguments).flatMap(Double.init) ?? 30
            let pauseAfter = value(for: "-videoPauseAfter", in: arguments).flatMap(Double.init) ?? 0
            let path = arguments[index + 1]
            Task.detached { await VideoSelfTest.run(path: path, seconds: seconds, pauseAfter: pauseAfter) }
        }
    }

    /// 自检用：写入一条主机记录与钥匙串凭据，便于验证冷启动恢复路径。
    private func seedHostRecord(
        host: String,
        share: String,
        path: String,
        user: String,
        password: String
    ) {
        do {
            try credentials.save(HostCredential(username: user, password: password), for: host)
            try HostRecordStore(context: modelContext).remember(
                address: host,
                username: user,
                share: share,
                path: path
            )
            Log.info(.app, "测试主机记录已写入 host=\(host) share=\(share)")
        } catch {
            Log.error(.app, "测试主机记录写入失败 \(error.localizedDescription)")
        }
    }

    /// 自动化排查：把本次启动参数写进 Documents，确认新包与参数是否生效。
    private func writeLaunchSnapshot(_ arguments: [String]) {
        // 启动参数可能包含 -seedPassword 等敏感值；快照只保留参数名，值做脱敏。
        var safeArguments = arguments
        for index in safeArguments.indices.dropLast()
        where safeArguments[index].lowercased().contains("password") {
            safeArguments[index + 1] = "<redacted>"
        }
        let info: [String: Any] = [
            "arguments": safeArguments,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ice-launch.json")
        try? data.write(to: url, options: .atomic)
    }

    /// 自检用：删除记录与凭据，等价于连接页的「忘记此主机」。
    private func forgetHostRecord(host: String) {
        do {
            try HostRecordStore(context: modelContext).forget(address: host)
            try credentials.deleteCredential(for: host)
            Log.info(.app, "测试主机记录已删除 host=\(host)")
        } catch {
            Log.error(.app, "测试主机记录删除失败 \(error.localizedDescription)")
        }
    }

    /// 自检/显式连接模式下不抢占启动流程。
    private func shouldAttemptAutoRestore(in arguments: [String]) -> Bool {
        let blockers = [
            "-diagnostics", "-skipRestore", "-library", "-libraryLocal",
            "-smbHost", "-smbAutoConnect", "-smbPath", "-seedHost",
            "-forgetHost",
            "-documentSelfTest",
            "-demuxTest", "-thumbnailProbe", "-audioTest", "-audioPauseTest",
            "-subtitleOverlay", "-subtitleScan", "-seekBurstTest", "-seekTest",
            "-videoSmb", "-videoTest",
        ]
        return !blockers.contains { arguments.contains($0) }
    }

    /// 按主机名复用设备钥匙串里的凭据；主机名大小写不一致时再从主机记录里找原名。
    @MainActor
    private func savedCredential(for host: String) -> HostCredential? {
        do {
            if let credential = try credentials.credential(for: host) {
                return credential
            }
        } catch {
            Log.error(
                .app,
                "读取钥匙串凭据失败 host=\(host) \(error.localizedDescription)"
            )
        }
        let records = HostRecordStore(context: modelContext)
        guard let record = records.all().first(where: {
            $0.address.caseInsensitiveCompare(host) == .orderedSame
        }) else { return nil }
        do {
            return try credentials.credential(for: record.address)
        } catch {
            Log.error(
                .app,
                "读取钥匙串凭据失败 host=\(record.address) \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func restoreLastSession() async {
        let records = HostRecordStore(context: modelContext)
        guard let record = records.mostRecent() else { return }
        isRestoringConnection = true
        defer { isRestoringConnection = false }

        let credential: HostCredential
        do {
            guard let saved = try credentials.credential(for: record.address) else {
                connectionPrefill = ConnectionPrefill(
                    host: record.address,
                    share: record.share,
                    path: record.recentPath,
                    user: record.username
                )
                connectionMessage = "找不到保存的密码，请重新输入"
                Log.notice(.app, "自动恢复跳过：钥匙串无凭据 host=\(record.address)")
                return
            }
            credential = saved
        } catch {
            connectionPrefill = ConnectionPrefill(
                host: record.address,
                share: record.share,
                path: record.recentPath,
                user: record.username
            )
            connectionMessage = "读取保存的密码失败：\(error.localizedDescription)"
            return
        }

        let source = SMBLibrarySource(
            host: record.address,
            share: record.share,
            user: credential.username,
            password: credential.password
        )
        let began = Date()
        do {
            try await source.connect()
            Log.info(
                .app,
                "自动恢复成功 host=\(record.address) share=\(record.share) "
                    + "路径=\(Log.shortPath(record.recentPath.isEmpty ? "/" : record.recentPath)) "
                    + "耗时=\(Int(Date().timeIntervalSince(began) * 1000))ms"
            )
            installLibrary(source: source, initialPath: record.recentPath)
        } catch {
            connectionPrefill = ConnectionPrefill(
                host: record.address,
                share: record.share,
                path: record.recentPath,
                user: record.username
            )
            if let smbError = error as? SMBConnectionError,
               case .authenticationFailed = smbError {
                connectionMessage = "保存的密码已失效，请重新输入密码"
            } else if let smbError = error as? SMBConnectionError,
                      case .unreachable = smbError {
                connectionMessage = "\(smbError.localizedDescription)\n若这是首次连接，请在「设置 > 隐私与安全性 > 本地网络」中允许 IceMovie。"
            } else if let smbError = error as? SMBConnectionError,
                      case .nameNotResolved = smbError {
                connectionMessage = "\(smbError.localizedDescription)\n若这是首次连接，请在「设置 > 隐私与安全性 > 本地网络」中允许 IceMovie。"
            } else {
                connectionMessage = "自动重连失败：\(error.localizedDescription)"
            }
            Log.error(
                .app,
                "自动恢复失败 host=\(record.address) 耗时=\(Int(Date().timeIntervalSince(began) * 1000))ms "
                    + error.localizedDescription
            )
        }
    }

    private func requestOrientation(landscape: Bool) {
        AppOrientation.request(
            landscape ? .landscape : .portrait,
            delay: .milliseconds(1200),
            phoneOnly: false
        )
    }

    private func openLibrary(_ connection: LibraryConnection) {
        installLibrary(
            source: SMBLibrarySource(
                client: connection.client,
                host: connection.host,
                share: connection.share
            ),
            initialPath: connection.path
        )
    }

    private func installLibrary(source: any LibrarySource, initialPath: String) {
        let arguments = ProcessInfo.processInfo.arguments
        let requestedMB = value(for: "-thumbnailCacheLimitMB", in: arguments).flatMap(Int64.init)
        let cacheBytes = ThumbnailStore.clampedCapacityBytes(requestedMB: requestedMB)
        do {
            let store = try LibraryStore(
                source: source,
                initialPath: initialPath,
                cacheCapacityBytes: cacheBytes,
                favoriteProvider: FavoritePhotoStore(context: modelContext)
            )
            // 目录切换成功后把最近路径写回 SwiftData；本地示例不会命中主机记录。
            let records = HostRecordStore(context: modelContext)
            store.onPathChanged = { path in
                records.updatePath(
                    address: source.hostName,
                    share: source.shareName,
                    path: path
                )
            }
            libraryStore = store
            let syncModel = PhotoSyncModel(
                store: store,
                targetStore: .swiftData(
                    PhotoLibraryTargetStore(context: modelContext)
                ),
                client: makePhotoLibraryClient(arguments),
                uploadLimit: value(for: "-photoSyncUploadLimit", in: arguments)
                    .flatMap(Int.init)
            )
            photoSyncModel = syncModel
            if arguments.contains("-libraryDiagnostics") {
                Task { [weak store] in
                    for _ in 0..<40 {
                        guard let store else { return }
                        if !store.isLoading, !store.currentEntries.isEmpty { break }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard let store else { return }
                    let entries = store.currentEntries
                    let images = entries.filter(\.isImage)
                    let timestamped = images.filter { $0.captureTimestamp != nil }
                    let latest = timestamped.compactMap(\.captureTimestamp).max()
                    let oldest = timestamped.compactMap(\.captureTimestamp).min()
                    Log.info(
                        .app,
                        "LIBDIAG 条目=\(entries.count) 图片=\(images.count) "
                            + "带时间戳=\(timestamped.count) 最新=\(latest?.displayTime ?? "-") "
                            + "最旧=\(oldest?.displayTime ?? "-")"
                    )
                    let directories = entries.filter(\.isDirectory)
                    Log.info(
                        .app,
                        "LIBDIAG 目录=\(directories.count) "
                            + directories.map(\.name).joined(separator: " | ")
                    )
                    let videos = entries.filter { $0.kind == .video }
                    let videoOrder = videos.prefix(12).map {
                        let episode = MediaTitleParser.parse($0.name).episode
                        return "\($0.name) [集=\(episode.map { String(format: "%g", $0) } ?? "-")]"
                    }
                    Log.info(
                        .app,
                        "LIBDIAG 视频顺序=\(videoOrder.joined(separator: " | "))"
                    )
                    let autumnNames = entries.filter {
                        $0.name.range(
                            of: "_2026(09|10|11)",
                            options: .regularExpression
                        ) != nil
                    }
                    Log.info(
                        .app,
                        "LIBDIAG 2026年9-11月文件名=\(autumnNames.count) "
                            + autumnNames.prefix(20).map(\.name).joined(separator: " | ")
                    )
                    let recentModified = entries
                        .filter { $0.modified != nil }
                        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                        .prefix(12)
                    for entry in recentModified {
                        Log.info(
                            .app,
                            "LIBDIAG 最近修改 \(entry.name) "
                                + "modified=\(entry.modified?.description ?? "-") "
                                + "isDir=\(entry.isDirectory)"
                        )
                    }
                    for entry in images.prefix(12) {
                        Log.info(
                            .app,
                            "LIBDIAG 首段 \(entry.name) ts=\(entry.captureTimestamp?.displayTime ?? "-") "
                                + "modified=\(entry.modified?.description ?? "-")"
                        )
                    }
                    for entry in images.suffix(12) {
                        Log.info(
                            .app,
                            "LIBDIAG 尾段 \(entry.name) ts=\(entry.captureTimestamp?.displayTime ?? "-") "
                                + "modified=\(entry.modified?.description ?? "-")"
                        )
                    }
                    let calendar = store.photoCalendar
                    Log.info(
                        .app,
                        "LIBDIAG 日历 years=\(calendar.years) "
                            + "months=\(calendar.years.map { "\($0):\(calendar.months(in: $0))" })"
                    )
                    if let raw = try? await store.source.listAllEntries(path: "") {
                        let unsupported = raw.filter {
                            !$0.isDirectory && !MediaKind.isVisible(entry: $0)
                        }
                        let grouped = Dictionary(grouping: unsupported, by: \.fileExtension)
                            .map { "\($0.key):\($0.value.count)" }
                            .sorted()
                        Log.info(
                            .app,
                            "LIBDIAG 原始条目=\(raw.count) 不可见文件=\(unsupported.count) "
                                + "扩展=\(grouped.joined(separator: ","))"
                        )
                        let rawAutumn = raw.filter {
                            $0.name.range(
                                of: "_2026(09|10|11)",
                                options: .regularExpression
                            ) != nil
                        }
                        Log.info(
                            .app,
                            "LIBDIAG 原始9-11月=\(rawAutumn.count) "
                                + rawAutumn.prefix(20).map(\.name).joined(separator: " | ")
                        )
                        let unsupportedAutumn = unsupported.filter {
                            $0.name.range(
                                of: "_2026(09|10|11)",
                                options: .regularExpression
                            ) != nil
                        }
                        Log.info(
                            .app,
                            "LIBDIAG 不可见9-11月=\(unsupportedAutumn.count) "
                                + unsupportedAutumn.prefix(20).map(\.name).joined(separator: " | ")
                        )
                    }
                }
            }
            if let seconds = value(for: "-smbDropAfter", in: arguments).flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    Log.notice(.app, "诊断：在 \(seconds)s 后模拟 SMB 掉线")
                    await source.simulateDropForTesting()
                }
            }
            if arguments.contains("-libraryAutoPlayFirst") {
                Task {
                    // 等目录与缩略图任务先起来，再开始播放，制造并发读竞争。
                    try? await Task.sleep(for: .seconds(2))
                    let preferred = value(for: "-libraryAutoPlayName", in: arguments)
                    let first = LibraryPlaybackSelection.firstVideo(
                        in: store.currentEntries,
                        preferredName: preferred
                    )
                    guard let first else {
                        Log.notice(.app, "自动播放跳过：当前目录没有视频")
                        return
                    }
                    Log.notice(.app, "诊断：自动播放 \(Log.shortPath(first.path))")
                    store.play(first)
                }
            }
            if let liftAfter = value(for: "-smbReadLimitLiftAfter", in: arguments).flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(liftAfter))
                    Log.notice(.app, "诊断：解除 SMB 读限速")
                    await source.setReadLimitForTesting(kbps: 0)
                }
            }
            Log.info(
                .app,
                "媒体库就绪 host=\(source.hostName) share=\(source.shareName) "
                    + "初始路径=\(Log.shortPath(initialPath.isEmpty ? "/" : initialPath)) "
                    + "缩略图上限=\(cacheBytes / (1024 * 1024))MB"
            )
        } catch {
            Log.error(.app, "媒体库初始化失败 \(error.localizedDescription)")
        }
    }

    private func makePhotoLibraryClient(_ arguments: [String]) -> any PhotoLibraryClient {
        if arguments.contains("-photoSyncFixture") {
            return FixturePhotoLibraryClient(
                slow: arguments.contains("-photoSyncSlow"),
                failFirst: arguments.contains("-photoSyncFixtureFail"),
                denied: arguments.contains("-photoSyncDenied")
            )
        }
        return PhotoKitLibraryClient()
    }

    private func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }
}
