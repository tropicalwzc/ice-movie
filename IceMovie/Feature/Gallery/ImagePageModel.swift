import CoreGraphics
import Foundation
import IceCore
import ImageIO
import ImageKit
import MediaLibraryKit
import SwiftUI
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// 单张图片页的加载状态。
///
/// 网格缩略图先出现；完整压缩图只在页面成为当前页时读取，解码在后台线程完成。
/// 压缩数据保留在内存中，放大时可重新解码更高分辨率，不重新访问 SMB。
@MainActor
@Observable
final class ImagePageModel {
    private(set) var entry: MediaEntry
    let session: ImageGallerySession
    private let store: LibraryStore

    private(set) var thumbnail: UIImage?
    private(set) var image: UIImage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var livePhotoPackage: LivePhotoPackage?
    private(set) var hasMotion = false
    private var cachedMotionData: Data?

    private var compressedData: Data?
    /// 当前旋转角度的屏幕预览。只保留一份，避免 0/90/180/270 各缓存一张全尺寸位图。
    private(set) var rotatedPreview: RotatedPreview?
    @ObservationIgnored private let loadTaskBox = GalleryTaskBox()
    @ObservationIgnored private let highResolutionTaskBox = GalleryTaskBox()
    @ObservationIgnored private let rotationTaskBox = GalleryTaskBox()
    @ObservationIgnored private var requestedQuarterTurns = 0
    @ObservationIgnored private var requestedTargetPixelSize = 1024
    private var generation = 0
    /// 放大触发的重解是否已经成功/正在进行。取消或失败后必须复位，否则再次放大不会重试。
    private(set) var highResolutionRequested = false

    struct RotatedPreview {
        let turns: Int
        let image: UIImage
    }

    /// 仅用于测试：确认取消后加载任务盒子没有泄漏。
    var isLoadTaskActive: Bool { loadTaskBox.isActive }

    var isEditableImage: Bool {
        entry.kind == .image && !entry.isLivePhoto
    }

    var saveType: UTType? {
        switch entry.imageFormat {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .livePhoto, .none: nil
        }
    }

    var canEditCurrentImage: Bool {
        isEditableImage && saveType != nil && image != nil && compressedData != nil
    }

    var canSaveToPhotos: Bool {
        image != nil && compressedData != nil
    }

    init(entry: MediaEntry, session: ImageGallerySession, store: LibraryStore) {
        self.entry = entry
        self.session = session
        self.store = store
    }

    deinit {
        loadTaskBox.cancel()
        highResolutionTaskBox.cancel()
        rotationTaskBox.cancel()
    }

    /// 只取内存里已经有的缩略图，绝不触发新的 SMB 读取。
    func loadCachedThumbnail() {
        guard thumbnail == nil else { return }
        thumbnail = store.cachedThumbnail(for: entry)
    }

    func loadThumbnail() async {
        guard thumbnail == nil else { return }
        if let cached = store.cachedThumbnail(for: entry) {
            thumbnail = cached
            return
        }
        thumbnail = await store.thumbnail(for: entry)
    }

    func loadFullImage(targetPixelSize: Int) {
        guard image == nil, !loadTaskBox.isActive else { return }
        generation += 1
        let generation = generation
        isLoading = true
        errorMessage = nil

        let task = Task { [weak self] in
            guard let self else { return }
            // 无论成功、失败还是 generation 提前返回，都必须由当前这一轮加载收尾；
            // 否则 loadTaskBox 会一直 active，后续 loadFullImage 永久被拒绝。
            defer {
                if generation == self.generation {
                    self.isLoading = false
                    self.loadTaskBox.set(nil)
                }
            }
            do {
                let data = try await self.fetchStillData()
                try Task.checkCancellation()
                let cgImage = try await Self.decode(
                    data: data,
                    targetPixelSize: targetPixelSize,
                    label: self.entry.path
                )
                guard !Task.isCancelled, generation == self.generation else { return }
                self.compressedData = data
                self.image = UIImage(cgImage: cgImage)
                self.refreshRotationPreview()
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation else { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                Log.error(.thumbnail, "相册加载失败 \(Log.shortPath(self.entry.path)) \(error.localizedDescription)")
            }
        }
        loadTaskBox.set(task)
    }

    func reload(targetPixelSize: Int) {
        cancelLoading()
        image = nil
        compressedData = nil
        rotationTaskBox.cancel()
        rotatedPreview = nil
        highResolutionRequested = false
        errorMessage = nil
        loadFullImage(targetPixelSize: targetPixelSize)
    }

    /// 屏幕预览用的旋转图。这里只读缓存，真正的重绘在后台任务里完成，
    /// 避免在 SwiftUI body 中同步分配全尺寸位图并修改可观察状态。
    func displayImage(quarterTurns: Int) -> UIImage? {
        let turns = Self.normalizedTurns(quarterTurns)
        guard turns != 0, let image else { return image }
        // 新角度生成期间先显示上一张旋转预览，避免闪回未旋转的原图。
        if let rotatedPreview {
            return rotatedPreview.image
        }
        return image
    }

    /// 用户点击旋转后异步生成预览；同一时间只保留一个角度的图。
    func prepareDisplayRotation(quarterTurns: Int, targetPixelSize: Int) {
        let turns = Self.normalizedTurns(quarterTurns)
        requestedQuarterTurns = turns
        requestedTargetPixelSize = max(512, targetPixelSize)
        rotationTaskBox.cancel()
        guard turns != 0 else {
            rotatedPreview = nil
            return
        }
        if rotatedPreview?.turns == turns { return }
        scheduleRotationPreview()
    }

    /// 图片分辨率变化（首次加载/高清重解）后，按新图重新生成当前角度预览。
    private func refreshRotationPreview() {
        guard requestedQuarterTurns != 0 else { return }
        rotationTaskBox.cancel()
        // 旧预览先留着，新的准备好后再替换，避免旋转后闪回原方向。
        scheduleRotationPreview()
    }

    private func scheduleRotationPreview() {
        guard requestedQuarterTurns != 0,
              let image,
              let cgImage = image.cgImage else {
            return
        }
        let turns = requestedQuarterTurns
        let target = requestedTargetPixelSize
        let generation = generation
        let source = SendableCGImage(value: cgImage)
        let task = Task { [weak self] in
            let box = await Task.detached(priority: .userInitiated) {
                RotatedPreviewBox(
                    cgImage: ImageEncoder.rotatedPreview(
                        source.value,
                        quarterTurns: turns,
                        maxPixelSize: target
                    )
                )
            }.value
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            if let cgImage = box.cgImage {
                self.rotatedPreview = RotatedPreview(
                    turns: turns,
                    image: UIImage(cgImage: cgImage)
                )
            }
            self.rotationTaskBox.set(nil)
        }
        rotationTaskBox.set(task)
    }

    private static func normalizedTurns(_ quarterTurns: Int) -> Int {
        ((quarterTurns % 4) + 4) % 4
    }

    private struct SendableCGImage: @unchecked Sendable {
        let value: CGImage
    }

    private struct RotatedPreviewBox: @unchecked Sendable {
        let cgImage: CGImage?
    }

    func rotatedData(quarterTurns: Int) async throws -> (data: Data, type: UTType) {
        guard isEditableImage, let compressedData, let saveType else {
            throw ImageEncoderError.unsupportedFormat
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try ImageEncoder.rotatedImageData(
                originalData: compressedData,
                type: saveType,
                quarterTurns: quarterTurns
            )
        }.value
        return (data, saveType)
    }

    /// 覆盖 SMB 原照片；成功后让当前页继续显示旋转后的结果。
    func saveRotated(quarterTurns: Int) async throws {
        let turns = Self.normalizedTurns(quarterTurns)
        let preview = rotatedPreview?.turns == turns ? rotatedPreview?.image : nil
        let displayTarget = max(
            512,
            max(image?.cgImage?.width ?? 0, image?.cgImage?.height ?? 0)
        )
        let result = try await rotatedData(quarterTurns: turns)
        let savedAt = Date()
        try await store.overwriteImage(
            path: entry.path,
            data: result.data,
            // 覆盖后必须刷新修改时间，否则大小恰好相同的旧缩略图会继续命中缓存。
            modified: savedAt
        )
        let updatedEntry = MediaEntry(
            path: entry.path,
            name: entry.name,
            isDirectory: false,
            size: Int64(result.data.count),
            modified: savedAt
        )
        entry = updatedEntry
        session.replaceEntry(updatedEntry)
        // 放大触发的旧数据高分辨率解码可能还在路上；先取消并让 generation 失效，
        // 避免保存完成后页面又被未旋转的旧图覆盖。
        highResolutionTaskBox.cancel()
        rotationTaskBox.cancel()
        generation += 1
        highResolutionRequested = false
        compressedData = result.data
        if let preview {
            image = preview
        } else if let decoded = try? await Self.decode(
            data: result.data,
            targetPixelSize: displayTarget,
            label: entry.path
        ) {
            image = UIImage(cgImage: decoded)
        }
        // 原图已经被旋转写回，页面不再需要“显示角度”这一层。
        requestedQuarterTurns = 0
        rotatedPreview = nil
        Log.info(
            .app,
            "旋转照片已覆盖 \(Log.shortPath(entry.path)) \(result.data.count)B"
        )
    }

    /// 把当前图片的完整数据加入系统照片库，不修改 SMB 原图。
    ///
    /// 未旋转时直接保存原始压缩数据，避免无意义的重编码；LIVP 保存其中的静态图。
    func saveToPhotoLibrary(quarterTurns: Int) async throws {
        if quarterTurns == 0,
           let compressedData,
           let type = Self.detectedType(compressedData) {
            try await PhotoLibrarySaver.save(
                data: compressedData,
                type: type,
                filename: entry.name
            )
        } else {
            let result = try await rotatedData(quarterTurns: quarterTurns)
            try await PhotoLibrarySaver.save(
                data: result.data,
                type: result.type,
                filename: entry.name
            )
        }
        Log.info(.app, "照片已保存到系统相册 \(entry.name)")
    }

    private static func detectedType(_ data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else {
            return nil
        }
        return UTType(identifier as String)
    }

    /// 放大到一定程度后，用已保留的压缩数据重解一份更高分辨率。
    func ensureHighResolution(targetPixelSize: Int, scale: CGFloat) {
        guard scale > 1.3, !highResolutionRequested, let data = compressedData else { return }
        highResolutionRequested = true
        let generation = generation
        let target = min(4096, max(targetPixelSize * 2, targetPixelSize + 512))
        highResolutionTaskBox.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let cgImage = try await Self.decode(
                    data: data,
                    targetPixelSize: target,
                    label: self.entry.path
                )
                guard !Task.isCancelled, generation == self.generation else { return }
                self.image = UIImage(cgImage: cgImage)
                self.refreshRotationPreview()
                Log.debug(
                    .thumbnail,
                    "相册高分辨率重解完成 \(Log.shortPath(self.entry.path)) 目标=\(target)px"
                )
            } catch {
                // 网络抖动、取消或解码失败都允许下一次放大重试，否则这张图会永久停在低清。
                if generation == self.generation {
                    self.highResolutionRequested = false
                }
                Log.debug(
                    .thumbnail,
                    "相册高分辨率重解失败 \(Log.shortPath(self.entry.path)) \(error.localizedDescription)"
                )
            }
            if generation == self.generation {
                self.highResolutionTaskBox.set(nil)
            }
        }
        highResolutionTaskBox.set(task)
    }

    func cancelLoading() {
        generation += 1
        loadTaskBox.cancel()
        highResolutionTaskBox.cancel()
        rotationTaskBox.cancel()
        // 重解被取消或尚未完成时，返回这一页必须允许再次触发。
        highResolutionRequested = false
        // 离开当前页后不再保留整段动态视频，避免一次长按长期占住大块内存。
        cachedMotionData = nil
        isLoading = false
    }

    /// 内存警告时释放非当前页的大图与压缩数据，只保留缩略图。
    func releasePreview() {
        cancelLoading()
        image = nil
        compressedData = nil
        rotationTaskBox.cancel()
        rotatedPreview = nil
        highResolutionRequested = false
        errorMessage = nil
    }

    func motionDataForPlayback() async throws -> Data {
        if let cachedMotionData {
            return cachedMotionData
        }
        let data = try await fetchMotionData()
        cachedMotionData = data
        hasMotion = true
        return data
    }

    private func fetchMotionData() async throws -> Data {
        let source = try await store.source.openImageByteSource(path: entry.path)
        do {
            let package: LivePhotoPackage
            if let livePhotoPackage {
                package = livePhotoPackage
            } else {
                package = try await LivePhotoPackage.parse(source: source, label: entry.path)
                self.livePhotoPackage = package
            }
            let data = try await package.motionData(source: source, label: entry.path)
            await source.close()
            return data
        } catch {
            await source.close()
            throw error
        }
    }

    private func fetchStillData() async throws -> Data {
        let source = try await store.source.openImageByteSource(path: entry.path)
        do {
            let data: Data
            if entry.isLivePhoto {
                let package = try await LivePhotoPackage.parse(source: source, label: entry.path)
                livePhotoPackage = package
                hasMotion = package.hasMotion
                data = try await package.stillImageData(source: source, label: entry.path)
            } else {
                data = try await ImageDataReader.readAll(
                    source: source,
                    maxBytes: 64 * 1024 * 1024,
                    label: entry.path
                )
            }
            await source.close()
            return data
        } catch {
            await source.close()
            throw error
        }
    }

    private struct DecodedImageBox: @unchecked Sendable {
        let image: CGImage
    }

    private nonisolated static func decode(
        data: Data,
        targetPixelSize: Int,
        label: String
    ) async throws -> CGImage {
        let box = try await Task.detached(priority: .userInitiated) {
            let image = try ImageDecoder.displayImage(
                data: data,
                maxPixelSize: max(512, targetPixelSize),
                label: label
            )
            return DecodedImageBox(image: image)
        }.value
        return box.image
    }
}

/// 可在 deinit 中安全取消的任务盒子，避免 @Observable 的存储属性限制。
private final class GalleryTaskBox: @unchecked Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    var isActive: Bool {
        task.withLock { $0 != nil }
    }

    func set(_ newTask: Task<Void, Never>?) {
        task.withLock { $0 = newTask }
    }

    func cancel() {
        task.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}
