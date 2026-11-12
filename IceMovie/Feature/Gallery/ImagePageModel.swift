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
    let entry: MediaEntry
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
    private var rotatedDisplayCache: [Int: UIImage] = [:]
    @ObservationIgnored private let loadTaskBox = GalleryTaskBox()
    @ObservationIgnored private let highResolutionTaskBox = GalleryTaskBox()
    private var generation = 0
    private var highResolutionRequested = false

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
                self.rotatedDisplayCache.removeAll()
                self.isLoading = false
                self.loadTaskBox.set(nil)
            } catch is CancellationError {
                guard generation == self.generation else { return }
                self.isLoading = false
                self.loadTaskBox.set(nil)
            } catch {
                guard generation == self.generation else { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.isLoading = false
                self.loadTaskBox.set(nil)
                Log.error(.thumbnail, "相册加载失败 \(Log.shortPath(self.entry.path)) \(error.localizedDescription)")
            }
        }
        loadTaskBox.set(task)
    }

    func reload(targetPixelSize: Int) {
        cancelLoading()
        image = nil
        compressedData = nil
        rotatedDisplayCache.removeAll()
        highResolutionRequested = false
        errorMessage = nil
        loadFullImage(targetPixelSize: targetPixelSize)
    }

    /// 屏幕预览用的旋转图；保存时另行按原图分辨率重解。
    func displayImage(quarterTurns: Int) -> UIImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0, let image, let cgImage = image.cgImage else {
            return image
        }
        if let cached = rotatedDisplayCache[turns] {
            return cached
        }
        guard let rotated = ImageEncoder.rotate(cgImage, quarterTurns: turns) else {
            return image
        }
        let uiImage = UIImage(cgImage: rotated)
        rotatedDisplayCache[turns] = uiImage
        return uiImage
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
        let rotatedImage = displayImage(quarterTurns: quarterTurns)
        let result = try await rotatedData(quarterTurns: quarterTurns)
        try await store.overwriteImage(
            path: entry.path,
            data: result.data,
            // 覆盖后必须刷新修改时间，否则大小恰好相同的旧缩略图会继续命中缓存。
            modified: Date()
        )
        // 放大触发的旧数据高分辨率解码可能还在路上；先取消并让 generation 失效，
        // 避免保存完成后页面又被未旋转的旧图覆盖。
        highResolutionTaskBox.cancel()
        generation += 1
        highResolutionRequested = false
        compressedData = result.data
        image = rotatedImage
        rotatedDisplayCache.removeAll()
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
                self.rotatedDisplayCache.removeAll()
                Log.debug(
                    .thumbnail,
                    "相册高分辨率重解完成 \(Log.shortPath(self.entry.path)) 目标=\(target)px"
                )
            } catch {
                Log.debug(
                    .thumbnail,
                    "相册高分辨率重解失败 \(Log.shortPath(self.entry.path)) \(error.localizedDescription)"
                )
            }
            self.highResolutionTaskBox.set(nil)
        }
        highResolutionTaskBox.set(task)
    }

    func cancelLoading() {
        generation += 1
        loadTaskBox.cancel()
        highResolutionTaskBox.cancel()
        // 离开当前页后不再保留整段动态视频，避免一次长按长期占住大块内存。
        cachedMotionData = nil
        isLoading = false
    }

    /// 内存警告时释放非当前页的大图与压缩数据，只保留缩略图。
    func releasePreview() {
        cancelLoading()
        image = nil
        compressedData = nil
        rotatedDisplayCache.removeAll()
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
