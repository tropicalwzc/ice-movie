import Foundation
import IceCore
import SMBSession

/// 真机诊断：验证 SMB 共享是否可写，不触碰用户照片。
enum SMBWriteSelfTest {
    static func run(
        host: String,
        share: String,
        directory: String,
        credential: HostCredential?
    ) async {
        guard let credential else {
            Log.error(.smb, "写入探针跳过：钥匙串没有 host=\(host) 的凭据")
            return
        }
        let client = SMBClient()
        do {
            try await client.connect(
                host: host,
                user: credential.username,
                password: credential.password,
                share: share
            )
            let payload = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nGQAAAAASUVORK5CYII="
            ) ?? Data(repeating: 0x42, count: 256)
            _ = try await client.runWriteProbe(
                directoryPath: directory,
                payload: payload
            )
            Log.info(
                .smb,
                "写入探针完成 host=\(host) share=\(share) 目录=\(Log.shortPath(directory.isEmpty ? "/" : directory))"
            )
        } catch {
            Log.error(
                .smb,
                "写入探针异常 host=\(host) share=\(share) \(error.localizedDescription)"
            )
        }
        await client.disconnect()
    }
}
