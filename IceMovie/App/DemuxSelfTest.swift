import DemuxKit
import Foundation
import IceCore
import SMBSession

/// 临时的解封装自检入口。
/// - `-demuxTest <本地路径>`：验证本地文件解封装与抽帧
/// - `-demuxSmb <共享内路径>`：配合 `-smbHost/-smbShare/-smbUser/-smbPassword` 验证通过字节源读取 SMB 文件
enum DemuxSelfTest {
    static func run(path: String) async {
        do {
            let info = try DemuxProbe.inspect(path: path)
            report(info, prefix: "本地")

            let began = Date()
            let png = try DemuxProbe.firstFramePNG(path: path, maxWidth: 960)
            let elapsed = String(format: "%.0fms", Date().timeIntervalSince(began) * 1000)
            let url = documentsURL.appendingPathComponent("frame.png")
            try png.write(to: url)
            Log.info(.demux, "首帧解码成功 \(png.count) 字节 耗时=\(elapsed) → \(url.path)")
        } catch {
            Log.error(.demux, "自检失败：\(error.localizedDescription)")
        }
    }

    /// 诊断用：在多个时间点抽帧，确认封面不是片头黑场，也用于比较解码结果。
    static func probeThumbnails(path: String, positions: [Double]) async {
        for position in positions {
            do {
                let began = Date()
                let image = try DemuxProbe.thumbnail(
                    path: path,
                    maxWidth: 480,
                    position: position
                )
                let elapsed = String(format: "%.0fms", Date().timeIntervalSince(began) * 1000)
                let url = documentsURL.appendingPathComponent(
                    "thumb-\(String(format: "%.0f", position)).png"
                )
                try image.data.write(to: url)
                Log.info(
                    .thumbnail,
                    "探测 position=\(position)s source=\(image.source.rawValue) "
                        + "\(image.width)x\(image.height) \(image.data.count)B 耗时=\(elapsed)"
                )
            } catch {
                Log.error(.thumbnail, "探测失败 position=\(position)s \(error.localizedDescription)")
            }
        }
    }

    static func runOverSMB(host: String, share: String, path: String, user: String, password: String) async {        let client = SMBClient()
        do {
            try await client.connect(host: host, user: user, password: password, share: share)

            let began = Date()
            let source = try await client.openByteSource(path: path)
            let info = try DemuxProbe.inspect(source: source)
            let elapsed = String(format: "%.0fms", Date().timeIntervalSince(began) * 1000)
            report(info, prefix: "SMB 字节源 耗时=\(elapsed)")
        } catch {
            Log.error(.demux, "SMB 解封装失败：\(error.localizedDescription)")
        }
    }

    private static func report(_ info: MediaInfo, prefix: String) {
        Log.info(
            .demux,
            "\(prefix) 容器=\(info.format) 时长=\(String(format: "%.1f", info.duration))s 轨道=\(info.streams.count)"
        )
        for stream in info.streams {
            Log.info(
                .demux,
                "轨道 #\(stream.index) \(stream.kind.rawValue) codec=\(stream.codec) \(stream.width)x\(stream.height) ch=\(stream.channels) sr=\(stream.sampleRate)"
            )
        }
    }

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
