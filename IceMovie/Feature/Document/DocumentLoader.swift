import Foundation
import IceCore
import MediaLibraryKit
import PDFKit

/// 一次文档加载的完整结果。
enum DocumentContent: Sendable {
    case markdown(String)
    case pdf(PDFDocumentBox)
}

/// PDFDocument 本身不是 Sendable，但加载完成后只读使用；
/// 用不可变包装把它从后台读取任务交给主线程的 PDFView。
final class PDFDocumentBox: @unchecked Sendable {
    let document: PDFDocument

    init?(_ data: Data) {
        guard let document = PDFDocument(data: data) else { return nil }
        self.document = document
    }
}

struct LoadedDocument: Sendable {
    let entry: MediaEntry
    let format: DocumentFormat
    let content: DocumentContent
    let byteCount: Int64
    let loadMilliseconds: Int
}

enum DocumentLoadError: LocalizedError, Equatable {
    case unsupportedFormat
    case cancelled
    case tooLarge(DocumentFormat, limit: Int64)
    case readFailed(String)
    case decodeFailed
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "这个文件不是可阅读的文档"
        case .cancelled:
            "文档打开已取消"
        case .tooLarge(let format, let limit):
            "\(format.displayName) 文件超过 \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))，无法打开"
        case .readFailed(let detail):
            "读取文档失败：\(detail)"
        case .decodeFailed:
            "无法解码文档文本，文件可能不是 UTF-8 或 GB18030 编码"
        case .invalidPDF:
            "PDF 文件损坏或无法解析"
        }
    }
}

/// 从当前 SMB/本地数据源读取完整文档。读取在调用方的 Task 中执行，
/// 关闭阅读器时通过 Task 取消来中止并关闭字节源。
struct DocumentLoader: Sendable {
    let source: any LibrarySource

    func load(_ entry: MediaEntry) async throws -> LoadedDocument {
        guard let format = entry.documentFormat else {
            throw DocumentLoadError.unsupportedFormat
        }
        if entry.size > format.maxByteCount {
            throw DocumentLoadError.tooLarge(format, limit: format.maxByteCount)
        }

        let began = ProcessInfo.processInfo.systemUptime
        let byteSource = try await source.openDocumentByteSource(path: entry.path)
        let data: Data
        do {
            data = try await Self.readAll(
                byteSource,
                limit: format.maxByteCount,
                format: format
            )
            await byteSource.close()
        } catch {
            await byteSource.close()
            throw Self.normalize(error, format: format)
        }

        let content: DocumentContent
        switch format {
        case .markdown:
            content = .markdown(try Self.decodeMarkdown(data))
        case .pdf:
            guard let box = PDFDocumentBox(data) else {
                throw DocumentLoadError.invalidPDF
            }
            content = .pdf(box)
        }

        let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
        Log.info(
            .app,
            "文档就绪 \(Log.shortPath(entry.path)) 格式=\(format.rawValue) "
                + "字节=\(data.count) 耗时=\(elapsed)ms"
        )
        return LoadedDocument(
            entry: entry,
            format: format,
            content: content,
            byteCount: Int64(data.count),
            loadMilliseconds: elapsed
        )
    }

    /// 分块读取整文件。超过上限时立即停止，不保留半截内容。
    static func readAll(
        _ source: any ByteSource,
        limit: Int64,
        format: DocumentFormat
    ) async throws -> Data {
        if let length = source.length, length > limit {
            throw DocumentLoadError.tooLarge(format, limit: limit)
        }

        var data = Data()
        var offset: Int64 = 0
        let chunkSize = 1 << 20

        while true {
            try Task.checkCancellation()
            let remaining = limit - Int64(data.count)
            if remaining < 0 {
                throw DocumentLoadError.tooLarge(format, limit: limit)
            }

            // 到达上限时多读 1 字节，用来判断文件是否恰好等于上限。
            let request = Int(min(Int64(chunkSize), remaining + 1))
            let chunk = try await source.read(at: offset, count: request)
            if chunk.isEmpty { break }

            data.append(chunk)
            offset += Int64(chunk.count)
            if Int64(data.count) > limit {
                throw DocumentLoadError.tooLarge(format, limit: limit)
            }
            if let length = source.length, offset >= length { break }
        }

        // 空读只表示当前读取结束，不能证明文件已完整；声明长度更大时必须报错，
        // 否则 Markdown/PDF 会把半截内容当成成功加载。
        if let length = source.length, Int64(data.count) != length {
            throw DocumentLoadError.readFailed(
                "文件读取不完整（\(data.count)/\(length) 字节）"
            )
        }
        return data
    }

    /// Markdown 优先 UTF-8，失败回退 GB18030；两种都失败时明确报错。
    static func decodeMarkdown(_ data: Data) throws -> String {
        if var text = String(data: data, encoding: .utf8) {
            if text.hasPrefix("\u{FEFF}") {
                text.removeFirst()
            }
            return text
        }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            return text
        }
        throw DocumentLoadError.decodeFailed
    }

    private static func normalize(_ error: any Error, format: DocumentFormat) -> any Error {
        if let loadError = error as? DocumentLoadError {
            return loadError
        }
        if error is CancellationError {
            return DocumentLoadError.cancelled
        }
        return DocumentLoadError.readFailed(error.localizedDescription)
    }
}
