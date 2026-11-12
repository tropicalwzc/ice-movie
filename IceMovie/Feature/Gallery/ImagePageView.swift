import IceCore
import ImageKit
import MediaLibraryKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImagePageView: View {
    let entry: MediaEntry
    let session: ImageGallerySession
    let isCurrent: Bool
    let targetPixelSize: Int
    let memoryWarningToken: Int
    let rotation: Int
    let onModelReady: (ImagePageModel) -> Void
    @Binding var isZoomed: Bool

    @Environment(LibraryStore.self) private var store
    @State private var model: ImagePageModel?
    @State private var showProgress = false
    @State private var motionController: LivePhotoMotionController?
    @State private var isMotionPlaying = false
    @State private var motionTask: Task<Void, Never>?
    @State private var motionError: String?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let model {
                if let image = model.displayImage(quarterTurns: rotation) {
                    ZoomableImageView(
                        image: image,
                        resetToken: "\(entry.id)|\(isCurrent)|\(rotation)",
                        isZoomed: $isZoomed,
                        onZoomScaleChanged: { scale in
                            model.ensureHighResolution(
                                targetPixelSize: targetPixelSize,
                                scale: scale
                            )
                        },
                        onLongPressBegan: {
                            startMotion(model: model)
                        },
                        onLongPressEnded: {
                            stopMotion()
                        }
                    )
                    .ignoresSafeArea()
                } else if let thumbnail = model.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .transition(.opacity)
                }

                if isMotionPlaying, let player = motionController?.player {
                    LivePhotoMotionView(player: player)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if model.isLoading, model.image == nil, showProgress {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)
                }

                if let error = model.errorMessage {
                    errorView(message: error, model: model)
                }

                if let motionError {
                    Text(motionError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 90)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: entry.id) {
            model?.cancelLoading()
            stopMotion()
            let newModel = ImagePageModel(entry: entry, session: session, store: store)
            model = newModel
            if isCurrent {
                onModelReady(newModel)
            }
            await newModel.loadThumbnail()
            if isCurrent {
                newModel.loadFullImage(targetPixelSize: targetPixelSize)
                // 动态视频只在长按时读取；页面打开时预取整段 MOV 会抢占静态图带宽并常驻大块内存。
            }
        }
        .onChange(of: isCurrent) { _, current in
            if current {
                if let model {
                    onModelReady(model)
                }
                model?.loadFullImage(targetPixelSize: targetPixelSize)
            } else {
                stopMotion()
                model?.cancelLoading()
                isZoomed = false
            }
        }
        .onChange(of: isZoomed) { _, zoomed in
            if zoomed {
                stopMotion()
            }
        }
        .onChange(of: memoryWarningToken) { _, _ in
            if !isCurrent {
                model?.releasePreview()
            }
        }
        .onDisappear {
            stopMotion()
        }
        .task(id: model?.isLoading) {
            showProgress = false
            guard model?.isLoading == true else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, model?.isLoading == true else { return }
            showProgress = true
        }
        .task(id: motionError) {
            guard motionError != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            motionError = nil
        }
    }

    private func startMotion(model: ImagePageModel) {
        guard entry.isLivePhoto, !isZoomed else { return }
        motionTask?.cancel()
        motionTask = Task {
            do {
                let data = try await model.motionDataForPlayback()
                guard !Task.isCancelled else { return }
                let controller = LivePhotoMotionController(
                    data: data,
                    contentType: .quickTimeMovie
                )
                controller.onFinished = {
                    stopMotion()
                }
                controller.onFailed = { message in
                    motionError = message
                    stopMotion()
                }
                motionController = controller
                isMotionPlaying = true
                controller.start()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Log.info(
                    .thumbnail,
                    "LIVP 动态开始 \(Log.shortPath(entry.path)) \(data.count)B"
                )
            } catch {
                guard !Task.isCancelled else { return }
                if let packageError = error as? LivePhotoPackageError,
                   case .missingMotion = packageError {
                    // 没有动态条目时只保留静态图，不打扰用户。
                    return
                }
                motionError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                Log.error(
                    .thumbnail,
                    "LIVP 动态失败 \(Log.shortPath(entry.path)) \(error.localizedDescription)"
                )
            }
        }
    }

    private func stopMotion() {
        motionTask?.cancel()
        motionTask = nil
        motionController?.stop()
        motionController?.teardown()
        motionController = nil
        if isMotionPlaying {
            isMotionPlaying = false
            Log.debug(.thumbnail, "LIVP 动态停止 \(Log.shortPath(entry.path))")
        }
    }

    private func errorView(message: String, model: ImagePageModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)
            Button("重试") {
                model.reload(targetPixelSize: targetPixelSize)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
