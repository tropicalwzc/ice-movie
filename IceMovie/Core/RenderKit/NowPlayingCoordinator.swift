import Foundation
import IceCore
import MediaPlayer

/// 锁屏与控制中心的「正在播放」信息与远程控制。
///
/// 同一播放引擎可能同时存在内联与全屏两个 `PlayerScreen`，由 `NowPlayingCenter`
/// 做引用计数，避免后出现的视图把先前的锁屏信息清掉。
@MainActor
public final class NowPlayingCenter {
    public static let shared = NowPlayingCenter()

    private var coordinator: NowPlayingCoordinator?
    private var engineID: ObjectIdentifier?
    private var references = 0

    private init() {}

    public func attach(engine: PlaybackEngine, title: String) {
        let id = ObjectIdentifier(engine)
        if engineID == id {
            references += 1
            return
        }
        coordinator?.deactivate()
        coordinator = NowPlayingCoordinator(engine: engine, title: title)
        engineID = id
        references = 1
        coordinator?.activate()
    }

    public func detach(engine: PlaybackEngine) {
        guard engineID == ObjectIdentifier(engine) else { return }
        references -= 1
        guard references <= 0 else { return }
        coordinator?.deactivate()
        coordinator = nil
        engineID = nil
    }
}

@MainActor
final class NowPlayingCoordinator {
    /// 弱持有：协调器可能被系统（锁屏中心/任务）缓存住，强持有会把整条
    /// 播放管线（引擎、预读缓冲）一起钉在内存里，切文件时逐会话泄漏。
    private weak var engine: PlaybackEngine?
    private let title: String
    private var updateTask: Task<Void, Never>?
    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []

    public init(engine: PlaybackEngine, title: String) {
        self.engine = engine
        self.title = title
    }

    public func activate() {
        guard updateTask == nil else { return }
        configureCommands()
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateNowPlaying()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        updateNowPlaying()
        Log.info(.app, "锁屏控制已就绪 标题=\(title) 时长=\(String(format: "%.1f", engine?.duration ?? 0))s")
    }

    deinit {
        // 协调器强持有 engine，泄漏会推迟整条播放管线的释放。
        Log.info(.app, "锁屏协调器释放 标题=\(title)")
    }

    public func deactivate() {
        updateTask?.cancel()
        updateTask = nil
        for target in commandTargets {
            target.command.removeTarget(target.token)
        }
        commandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Log.info(.app, "锁屏控制已释放")
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { [weak self] _ in
            self?.engine?.play()
            return .success
        }
        add(center.pauseCommand) { [weak self] _ in
            self?.engine?.pause()
            return .success
        }
        add(center.togglePlayPauseCommand) { [weak self] _ in
            guard let engine = self?.engine else { return .commandFailed }
            if engine.isPlaying {
                engine.pause()
            } else {
                engine.play()
            }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.engine?.seek(to: (self?.engine?.clock.currentTime ?? 0) + interval)
            return .success
        }
        add(center.skipBackwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.engine?.seek(to: (self?.engine?.clock.currentTime ?? 0) - interval)
            return .success
        }

        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?
                .positionTime else { return .commandFailed }
            self?.engine?.seek(to: position)
            return .success
        }
    }

    private func add(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let token = command.addTarget(handler: handler)
        commandTargets.append((command, token))
    }

    private func updateNowPlaying() {
        guard let engine else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: max(0, engine.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, engine.clock.currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
