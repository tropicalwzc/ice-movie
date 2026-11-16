import DemuxKit
import Foundation
import IceCore
import SMBSession
import SubtitleKit

/// 字幕轨发现自检（任务 7.1）：内封轨 + 同目录外挂，一起列出并标注语言。
enum SubtitleSelfTest {
    static func runEmbedded(path: String) async {
        do {
            let reader = try MediaReader.open(path: path)
            let streams = reader.info.streams.filter { $0.kind == .subtitle }
            guard let stream = streams.first else {
                Log.error(.subtitle, "内封字幕自检：没有字幕轨")
                return
            }
            let began = Date()
            let text = try reader.readSubtitleScript(streamIndex: stream.index)
            let cues = SubtitleParser.parse(text, format: .ass)
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)
            Log.info(
                .subtitle,
                "内封字幕自检 stream=\(stream.index) codec=\(stream.codec) "
                    + "解析条目=\(cues.count) 耗时=\(elapsed)ms 结论=\(cues.isEmpty ? "失败" : "通过")"
            )
            reader.close()
        } catch {
            Log.error(.subtitle, "内封字幕自检失败：\(error.localizedDescription)")
        }
    }

    static func runOverSMB(
        host: String,
        share: String,
        path: String,
        user: String,
        password: String,
        dumpExternal: Bool = false
    ) async {
        let client = SMBClient()
        do {
            try await client.connect(host: host, user: user, password: password, share: share)
            let source = try await client.openByteSource(path: path)
            let reader = try MediaReader.open(source: source, label: "smb://\(host)/\(share)")
            let info = reader.info

            let embedded = SubtitleDiscovery.embedded(
                info.streams.filter { $0.kind == .subtitle }.map {
                    SubtitleDiscovery.EmbeddedSource(
                        streamIndex: $0.index,
                        codec: $0.codec,
                        languageTag: $0.language,
                        title: $0.title
                    )
                }
            )

            let directory = (path as NSString).deletingLastPathComponent
            let entries = try await client.listDirectory(path: directory)

            // 同目录 + 字幕子目录（真实库常见 `- Sub` 结构）。
            var filesByDirectory: [String: [String]] = [
                "": entries.filter { !$0.isDirectory }.map(\.name)
            ]
            for entry in entries where entry.isDirectory
                && SubtitleDiscovery.isSubtitleDirectory(entry.name) {
                let subPath = directory.isEmpty ? entry.name : "\(directory)/\(entry.name)"
                let subEntries = try await client.listDirectory(path: subPath)
                filesByDirectory[entry.name] = subEntries.filter { !$0.isDirectory }.map(\.name)
                Log.info(.subtitle, "扫描字幕目录 \(entry.name) 文件=\(subEntries.count)")
            }

            let external = SubtitleDiscovery.external(
                videoFileName: (path as NSString).lastPathComponent,
                filesByDirectory: filesByDirectory
            )

            Log.info(.subtitle, "字幕发现 内封=\(embedded.count) 外挂=\(external.count)")
            for track in embedded + external {
                let origin: String
                switch track.source {
                case .embedded(let index): origin = "内封#\(index)"
                case .external(let name): origin = "外挂 \(name)"
                }
                Log.info(
                    .subtitle,
                    "  \(origin) 语言=\(track.language.displayName) 格式=\(track.format.rawValue) "
                        + "强制=\(track.isForced ? "是" : "否")"
                )
            }
            Log.info(
                .subtitle,
                "字幕发现结果 默认选中=\(SubtitleDiscovery.preferred(from: embedded + external)?.title ?? "无") "
                    + "结论=\(embedded.count + external.count > 0 ? "通过" : "未发现")"
            )
            if dumpExternal {
                try await dumpExternalSubtitles(
                    client: client,
                    directory: directory,
                    tracks: external
                )
            }
        } catch {
            Log.error(.subtitle, "字幕发现失败：\(error.localizedDescription)")
        }
        try? await client.disconnect()
    }

    private static func dumpExternalSubtitles(
        client: SMBClient,
        directory: String,
        tracks: [SubtitleTrack]
    ) async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubtitleDebug", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        for track in tracks {
            guard case .external(let name) = track.source else { continue }
            let path = directory.isEmpty ? name : "\(directory)/\(name)"
            let source = try await client.openByteSource(path: path, priority: .subtitle)
            var data = Data()
            var offset: Int64 = 0
            while true {
                let chunk = try await source.read(at: offset, count: 1 << 20)
                if chunk.isEmpty { break }
                data.append(chunk)
                offset += Int64(chunk.count)
                if let length = source.length, offset >= length { break }
            }
            await source.close()

            let url = root.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            let encodings = textEncodings(data)
            for (encoding, text) in encodings {
                let cues = SubtitleParser.parse(text, format: track.format)
                let lowered = text.lowercased()
                let prefix = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                Log.info(
                    .subtitle,
                    "字幕转储 \(name) bytes=\(data.count) 头=\(prefix) 编码=\(encoding) "
                        + "行=\(text.components(separatedBy: .newlines).count) "
                        + "事件=\(lowered.components(separatedBy: "\ndialogue:").count - 1) "
                        + "解析=\(cues.count) 路径=\(url.lastPathComponent)"
                )
            }
        }
    }

    private static func textEncodings(_ data: Data) -> [(String, String)] {
        var result: [(String, String)] = []
        if let text = String(data: data, encoding: .utf8) {
            result.append(("UTF-8", text))
        }
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            result.append(("UTF-16LE", text))
        }
        if let text = String(data: data, encoding: .utf16BigEndian) {
            result.append(("UTF-16BE", text))
        }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            result.append(("GB18030", text))
        }
        return result
    }
}
