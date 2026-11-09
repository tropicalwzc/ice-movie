import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import SubtitleKit

/// 一次字幕加载的完整产物：时间轴用于兜底文字渲染，脚本与字体用于 libass。
struct LoadedSubtitles: Sendable {
    let timeline: SubtitleTimeline
    let script: String?
    let fonts: [SubtitleFont]
}

/// 把一条字幕轨加载成时间轴。外挂读文件，内封用独立字节源提取，避免干扰播放读流。
struct SubtitleLoader {
    let source: any LibrarySource
    let entry: MediaEntry

    func load(_ track: SubtitleTrack) async throws -> LoadedSubtitles {
        switch track.source {
        case .external(let fileName):
            let path = entry.directoryPath.isEmpty
                ? fileName
                : entry.directoryPath + "/" + fileName
            let byteSource = try await source.openByteSource(path: path)
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let data = try await readAll(byteSource)
                await byteSource.close()
                let text = decode(data)
                let cues = SubtitleParser.parse(text, format: track.format)
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                Log.info(.subtitle, "外挂字幕加载 \(Log.shortPath(path)) 条目=\(cues.count) 耗时=\(elapsed)ms")
                guard !cues.isEmpty else {
                    throw SubtitleLoadError.empty(track.title)
                }
                let script = track.format == .ass ? text : nil
                let fonts = script == nil ? [] : await containerFonts()
                return LoadedSubtitles(
                    timeline: SubtitleTimeline(cues: cues),
                    script: script,
                    fonts: fonts
                )
            } catch {
                await byteSource.close()
                throw error
            }

        case .embedded(let index):
            let byteSource = try await source.openByteSource(path: entry.path)
            let reader = try MediaReader.open(source: byteSource, label: entry.path)
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let text = try reader.readSubtitleScript(streamIndex: index)
                let fonts = reader.attachments()
                    .filter(\.isFont)
                    .map { SubtitleFont(name: $0.name, data: $0.data) }
                reader.close()
                await byteSource.close()
                let cues = SubtitleParser.parse(text, format: .ass)
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                Log.info(
                    .subtitle,
                    "内封字幕加载 stream=\(index) 条目=\(cues.count) 字体附件=\(fonts.count) 耗时=\(elapsed)ms"
                )
                guard !cues.isEmpty else {
                    throw SubtitleLoadError.empty(track.title)
                }
                return LoadedSubtitles(
                    timeline: SubtitleTimeline(cues: cues),
                    script: track.format == .ass ? text : nil,
                    fonts: fonts
                )
            } catch {
                reader.close()
                await byteSource.close()
                throw error
            }
        }
    }

    /// 外挂 ASS 的字体可能仍在视频容器里；单独开一次字节源只读附件，失败不影响字幕。
    private func containerFonts() async -> [SubtitleFont] {
        do {
            let byteSource = try await source.openByteSource(path: entry.path)
            let reader = try MediaReader.open(source: byteSource, label: entry.path)
            let fonts = reader.attachments()
                .filter(\.isFont)
                .map { SubtitleFont(name: $0.name, data: $0.data) }
            reader.close()
            await byteSource.close()
            if !fonts.isEmpty {
                Log.info(.subtitle, "容器字体附件 \(fonts.count) 个：\(fonts.map(\.name).joined(separator: ", "))")
            }
            return fonts
        } catch {
            Log.error(.subtitle, "容器字体附件读取失败：\(error.localizedDescription)")
            return []
        }
    }

    private func readAll(_ source: any ByteSource) async throws -> Data {
        var data = Data()
        var offset: Int64 = 0
        let chunkSize = 1 << 20
        while true {
            let chunk = try await source.read(at: offset, count: chunkSize)
            if chunk.isEmpty { break }
            data.append(chunk)
            offset += Int64(chunk.count)
            if let length = source.length, offset >= length { break }
        }
        return data
    }

    private func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum SubtitleLoadError: LocalizedError {
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .empty(let title): "字幕没有可显示的内容：\(title)"
        }
    }
}
