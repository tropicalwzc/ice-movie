import AVFoundation
import AVFAudio
import Foundation
import ImageKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 用内存中的 MOV 数据供给 AVPlayer，不生成任何本地视频文件。
final class LivePhotoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let data: Data
    private let contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentLength = Int64(data.count)
            information.contentType = contentType.identifier
            information.isByteRangeAccessSupported = true
        }

        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        guard !data.isEmpty else {
            loadingRequest.finishLoading(
                with: NSError(
                    domain: "IceMovie.LivePhoto",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "LIVP 动态数据为空"]
                )
            )
            return true
        }

        let offset = max(0, request.requestedOffset)
        let requestedLength = Int64(request.requestedLength)
        let available = Int64(data.count) - offset
        let length = requestedLength > 0 ? min(requestedLength, available) : available
        guard length > 0 else {
            loadingRequest.finishLoading()
            return true
        }

        let end = offset + length
        var cursor = offset
        while cursor < end {
            if loadingRequest.isCancelled {
                return true
            }
            let chunkEnd = min(end, cursor + 256 * 1024)
            request.respond(
                with: data.subdata(in: Int(cursor)..<Int(chunkEnd))
            )
            cursor = chunkEnd
        }
        loadingRequest.finishLoading()
        return true
    }
}

/// 一次 LIVP 动态播放。页面切换、松手、关闭或缩放时立即停止并释放。
@MainActor
final class LivePhotoMotionController {
    let player: AVPlayer
    var onFinished: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private let asset: AVURLAsset
    private let item: AVPlayerItem
    private let loader: LivePhotoResourceLoader
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var didReportFailure = false

    init(data: Data, contentType: UTType) {
        let loader = LivePhotoResourceLoader(data: data, contentType: contentType)
        let url = URL(string: "icemovie-livp://motion/\(UUID().uuidString).mov")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(
            loader,
            queue: DispatchQueue(label: "icemovie.livp.resource-loader")
        )
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.loader = loader
        self.asset = asset
        self.item = item
        self.player = player

        let endBox = MainNotificationBox { [weak self] in
            self?.onFinished?()
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            endBox.call()
        }
        let failureBox = MainNotificationBox { [weak self] in
            let message = self?.player.currentItem?.error?.localizedDescription
                ?? "动态播放失败"
            self?.reportFailure(message)
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            failureBox.call()
        }
        // 解封装失败通常只把 item.status 置为 .failed，不会发 FailedToPlayToEndTime；
        // 不监听就会表现为“长按后什么都没发生”。
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "动态播放失败"
            Task { @MainActor [weak self] in
                self?.reportFailure(message)
            }
        }
    }

    /// 同一次播放只提示一次，避免通知与 KVO 同时触发。
    private func reportFailure(_ message: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailed?(message)
    }

    @MainActor
    func start() async {
        try? await PlaybackAudioSession.activate()
        _ = await player.seek(to: .zero)
        if item.status == .failed {
            reportFailure(item.error?.localizedDescription ?? "动态播放失败")
            return
        }
        player.play()
    }

    func stop() {
        player.pause()
    }

    func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }
}

struct LivePhotoMotionView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerContainer, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerLayerContainer: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

/// NotificationCenter 的闭包是 @Sendable；这里把主队列回调显式收回 MainActor。
private final class MainNotificationBox: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        MainActor.assumeIsolated {
            handler()
        }
    }
}
