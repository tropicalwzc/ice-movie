import AVFoundation
import AVKit
import IceCore

/// 用 `AVSampleBufferDisplayLayer` 作为内容源的画中画控制器。
///
/// 进入画中画后由系统提供播放/暂停、快进快退与关闭按钮；
/// 这里把这些操作转回 `PlaybackEngine`，播放管线与字幕时间轴保持不变。
@MainActor
public final class PictureInPictureCoordinator: NSObject {
    public private(set) var isSupported: Bool
    public private(set) var isEnabled = false
    public private(set) var isActive = false
    public private(set) var lastError: String?
    public var onStateChange: ((Bool) -> Void)?

    /// 弱持有：这个协调器挂在 SwiftUI 的 @State 里，视图状态一旦被系统缓存，
    /// 强持有会把引擎和它的预读缓冲一起钉住（跨文件播放时逐会话泄漏）。
    private weak var engine: PlaybackEngine?
    private weak var layer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?

    public init(engine: PlaybackEngine) {
        self.engine = engine
        self.isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        super.init()
        Log.info(.render, "画中画支持=\(isSupported)")
    }

    deinit {
        // 协调器强持有 engine；若它不释放，切文件时每个会话都会连带泄漏引擎。
        Log.info(.render, "画中画协调器释放")
    }

    /// 显示层创建后调用。控制器在第一次绑定后创建，之后由系统在退后台时自动进入。
    public func bind(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        createControllerIfNeeded()
    }

    /// 播放页消失时调用：释放控制器与显示层引用。
    ///
    /// 协调器本体挂在 SwiftUI 的 `@State` 上，可能比播放会话活得久；
    /// 而 `AVPictureInPictureController.ContentSource` 会强持有显示层，
    /// 不主动拆掉的话每切一个文件就多压一个 VideoToolbox 解码会话在进程里，
    /// 累积到第 8 个左右，10-bit H.264（软解路径）就会开始持续解码失败。
    public func teardown() {
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller = nil
        layer = nil
    }

    /// 设置页开关：默认关闭；关闭时停止正在进行的画中画并禁止自动进入。
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        createControllerIfNeeded()
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
        if !enabled, controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        Log.info(.render, "画中画开关=\(enabled ? "开" : "关")")
    }

    public func toggle() {
        guard isEnabled else {
            lastError = "画中画已在设置中关闭"
            Log.notice(.render, "画中画不可用：设置中未开启")
            return
        }
        createControllerIfNeeded()
        guard let controller else {
            lastError = isSupported ? "画中画控制器尚未就绪" : "当前设备不支持画中画"
            Log.error(.render, "画中画不可用：\(lastError ?? "")")
            return
        }

        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            Log.info(.render, "请求进入画中画")
            controller.startPictureInPicture()
        } else {
            lastError = "当前画面尚不可进入画中画"
            Log.notice(.render, "画中画不可用：possible=false active=\(controller.isPictureInPictureActive)")
        }
    }

    public func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    private func createControllerIfNeeded() {
        guard controller == nil, isSupported, let layer else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let created = AVPictureInPictureController(contentSource: source)
        created.delegate = self
        created.canStartPictureInPictureAutomaticallyFromInline = isEnabled
        controller = created
        Log.info(.render, "画中画控制器已创建 自动进入=\(isEnabled ? "是" : "否")")
    }
}

extension PictureInPictureCoordinator: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Log.info(.render, "画中画播放控制 playing=\(playing)")
        if playing {
            engine?.play()
        } else {
            engine?.pause()
        }
        pictureInPictureController.invalidatePlaybackState()
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        let duration = CMTime(
            seconds: max(0, engine?.duration ?? 0),
            preferredTimescale: 600
        )
        return CMTimeRange(start: .zero, duration: duration)
    }

    public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !(engine?.isPlaying ?? false)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Log.debug(.render, "画中画尺寸 \(newRenderSize.width)x\(newRenderSize.height)")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let target = (engine?.clock.currentTime ?? 0) + skipInterval.seconds
        Log.info(.render, "画中画跳转 \(String(format: "%.1f", skipInterval.seconds))s 目标=\(String(format: "%.1f", target))s")
        engine?.seek(to: target)
        completionHandler()
    }
}

extension PictureInPictureCoordinator: @preconcurrency AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Log.info(.render, "画中画即将开始")
    }

    public func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = true
        onStateChange?(true)
        Log.info(.render, "画中画已开始")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        lastError = error.localizedDescription
        isActive = false
        onStateChange?(false)
        Log.error(.render, "画中画启动失败：\(error.localizedDescription)")
    }

    public func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Log.info(.render, "画中画即将停止")
    }

    public func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = false
        onStateChange?(false)
        Log.info(.render, "画中画已停止")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
