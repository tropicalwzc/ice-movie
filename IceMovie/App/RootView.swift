import AVFAudio
import IceCore
import PersistenceKit
import RenderKit
import SMBSession
import SubtitleKit
import SwiftData
import SwiftUI
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
            } else if let libraryStore {
                LibraryView(store: libraryStore) {
                    self.libraryStore = nil
                    self.connectionMessage = nil
                }
            } else if isRestoringConnection {
                restoringPage
            } else {
                connectionPage
            }
        }
        .task { await bootstrap() }
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
            try PlaybackAudioSession.activate()
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
        if arguments.contains("-resetAcceptanceReport") {
            let url = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("ice-acceptance.json")
            try? FileManager.default.removeItem(at: url)
            Log.info(.app, "验收报告已清空")
        }
        if arguments.contains("-debugLog") {
            Log.minimumLevel = .debug
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
        if let localPath = value(for: "-libraryLocal", in: arguments) {            installLibrary(
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
            installLibrary(
                source: SMBLibrarySource(
                    host: host,
                    share: share,
                    user: value(for: "-smbUser", in: arguments) ?? "",
                    password: value(for: "-smbPassword", in: arguments) ?? "",
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
            "-demuxTest", "-thumbnailProbe", "-audioTest", "-audioPauseTest",
            "-subtitleOverlay", "-subtitleScan", "-seekBurstTest", "-seekTest",
            "-videoSmb", "-videoTest",
        ]
        return !blockers.contains { arguments.contains($0) }
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
        let limitMB = value(for: "-thumbnailCacheLimitMB", in: arguments).flatMap(Int64.init) ?? 150
        do {
            let store = try LibraryStore(
                source: source,
                initialPath: initialPath,
                cacheCapacityBytes: max(1, limitMB) * 1024 * 1024
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
                    let first = store.currentEntries.first {
                        guard !$0.isDirectory else { return false }
                        guard let preferred, !preferred.isEmpty else { return true }
                        return $0.name.localizedCaseInsensitiveContains(preferred)
                    } ?? store.currentEntries.first(where: { !$0.isDirectory })
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
                    + "缩略图上限=\(max(1, limitMB))MB"
            )
        } catch {
            Log.error(.app, "媒体库初始化失败 \(error.localizedDescription)")
        }
    }

    private func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }
}
