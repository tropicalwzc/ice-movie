import Foundation
import IceCore
import SMBSession

/// 照片同步原子创建的 App 内验收。
///
/// 用启动参数触发，避免单元测试宿主重复链接 SMBSession 导致的类重复问题：
/// `-photoSyncSMBProbe -smbHost 127.0.0.1:4450 -smbShare Photos -smbUser test -smbPassword test`
enum PhotoSyncSMBWriteSelfTest {
    static func run(
        host: String,
        share: String,
        user: String,
        password: String
    ) async {
        let client = SMBClient(heartbeatInterval: .seconds(60))
        var probePath: String?
        do {
            try await client.connect(
                host: host,
                user: user,
                password: password,
                share: share
            )

            if let existing = try? await client.listDirectory(path: "") {
                let artifacts = existing.filter {
                    !$0.isDirectory
                        && ($0.name.hasPrefix("__photo_sync_probe_")
                            || $0.name.hasPrefix("__photo_sync_cancel_"))
                }
                for artifact in artifacts {
                    try? await client.removeFile(path: artifact.name)
                }
                if !artifacts.isEmpty {
                    Log.info(
                        .smb,
                        "PHOTOSYNC_SMB_PROBE 清理旧测试文件 \(artifacts.count) 个"
                    )
                }
            }

            let name = "__photo_sync_probe_\(UUID().uuidString).jpg"
            let data = Data(repeating: 0x5A, count: 4096)
            let modified = Date(timeIntervalSince1970: 1_700_000_000)
            try await client.createFile(
                path: name,
                data: data,
                modified: modified,
                onProgress: { _ in true }
            )
            probePath = name

            let entries = try await client.listDirectory(path: "")
            guard let entry = entries.first(where: { $0.name == name }) else {
                throw SMBConnectionError.failed("创建后目录中找不到探针文件")
            }
            guard entry.size == Int64(data.count) else {
                throw SMBConnectionError.failed(
                    "探针大小不一致：\(entry.size)/\(data.count)"
                )
            }
            let modifiedDelta = abs(
                (entry.modified?.timeIntervalSince1970 ?? 0)
                    - modified.timeIntervalSince1970
            )
            guard modifiedDelta <= 2 else {
                throw SMBConnectionError.failed("探针修改时间未设置")
            }

            do {
                try await client.createFile(
                    path: name,
                    data: Data([0x01]),
                    modified: nil,
                    onProgress: { _ in true }
                )
                throw SMBConnectionError.failed("已存在文件被覆盖")
            } catch let error as SMBConnectionError {
                guard case .alreadyExists = error else { throw error }
            }

            let source = try await client.openByteSource(path: name)
            let read = try await source.read(at: 0, count: data.count)
            await source.close()
            guard read == data else {
                throw SMBConnectionError.failed("拒绝覆盖后原内容发生变化")
            }

            let cancelName = "__photo_sync_cancel_\(UUID().uuidString).jpg"
            do {
                try await client.createFile(
                    path: cancelName,
                    data: Data(repeating: 0x11, count: 2 * 1024 * 1024),
                    modified: nil,
                    onProgress: { _ in false }
                )
                throw SMBConnectionError.failed("取消回调没有中止写入")
            } catch {
                // 期望中止；下面确认无残留。
            }
            let after = try await client.listDirectory(path: "")
            guard !after.contains(where: { $0.name.hasPrefix(cancelName) }) else {
                throw SMBConnectionError.failed("取消后留下最终文件")
            }
            guard !after.contains(where: {
                $0.name.contains(".icemovie-tmp-") && $0.name.contains(cancelName)
            }) else {
                throw SMBConnectionError.failed("取消后留下临时文件")
            }

            Log.info(
                .smb,
                "PHOTOSYNC_SMB_PROBE PASS file=\(name) 大小=\(data.count) "
                    + "覆盖拒绝=是 取消清理=是 修改时间=是"
            )
        } catch {
            Log.error(
                .smb,
                "PHOTOSYNC_SMB_PROBE FAIL host=\(host) share=\(share) "
                    + "\(error.localizedDescription)"
            )
        }
        if let probePath {
            try? await client.removeFile(path: probePath)
        }
        await client.disconnect()
    }
}
