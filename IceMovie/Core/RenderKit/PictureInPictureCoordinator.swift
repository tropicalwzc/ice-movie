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
    public private(set) var isActive = false
    public private(set) var lastError: String?
    public var onStateChange: ((Bool) -> Void)?

    private let engine: PlaybackEngine
    private weak var layer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?

    public init(engine: PlaybackEngine) {
        self.engine = engine
        self.isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        super.init()
        Log.info(.render, "画中画支持=\(isSupported)")
    }

    /// 显示层创建后调用。控制器在第一次绑定后创建，之后由系统在退后台时自动进入。
    public func bind(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        createControllerIfNeeded()
    }

    public func toggle() {
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
        created.canStartPictureInPictureAutomaticallyFromInline = true
        controller = created
        Log.info(.render, "画中画控制器已创建 自动进入=是")
    }
}

extension PictureInPictureCoordinator: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Log.info(.render, "画中画播放控制 playing=\(playing)")
        if playing {
            engine.play()
        } else {
            engine.pause()
        }
        pictureInPictureController.invalidatePlaybackState()
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        let duration = CMTime(
            seconds: max(0, engine.duration),
            preferredTimescale: 600
        )
        return CMTimeRange(start: .zero, duration: duration)
    }

    public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !engine.isPlaying
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
        let target = engine.clock.currentTime + skipInterval.seconds
        Log.info(.render, "画中画跳转 \(String(format: "%.1f", skipInterval.seconds))s 目标=\(String(format: "%.1f", target))s")
        engine.seek(to: target)
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
