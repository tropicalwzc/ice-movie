import Foundation
import Photos
import UniformTypeIdentifiers

enum PhotoLibrarySaveError: LocalizedError, Sendable {
    case permissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "没有照片库写入权限，请在系统设置中允许 IceMovie 添加照片"
        case .saveFailed(let detail):
            "保存到系统相册失败：\(detail)"
        }
    }
}

/// 把图片数据写入系统照片库（相机胶卷），不读取用户照片。
enum PhotoLibrarySaver {
    static func save(
        data: Data,
        type: UTType,
        filename: String
    ) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.permissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                options.uniformTypeIdentifier = type.identifier
                request.addResource(with: .photo, data: data, options: options)
            }
        } catch {
            throw PhotoLibrarySaveError.saveFailed(error.localizedDescription)
        }
    }
}
