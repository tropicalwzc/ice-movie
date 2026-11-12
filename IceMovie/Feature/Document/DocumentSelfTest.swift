import Foundation
import IceCore
import MediaLibraryKit
import PDFKit

/// 一份文档的自动化验收记录。
struct DocumentSelfTestRecord: Codable, Sendable {
    let path: String
    let format: String
    let bytes: Int64
    let loadMilliseconds: Int
    let renderMilliseconds: Int
    let tables: Int
    let codeBlocks: Int
    let highlighted: Int
    let headings: Int
    let reachedBottom: Bool
    let pageCount: Int
    let passed: Bool
    let message: String?
}

struct DocumentSelfTestReport: Codable, Sendable {
    let root: String
    let startedAt: String
    let finishedAt: String
    let total: Int
    let passed: Int
    let failed: Int
    let records: [DocumentSelfTestRecord]
}

/// 真机/模拟器验收模式：递归遍历共享中的文档，逐个打开、渲染并滚动到底部。
///
/// 启动参数：
/// - `-documentSelfTest`
/// - `-documentSelfTestRoot <相对共享根路径>`（默认当前目录）
/// - `-documentSelfTestLimit <数量>`（可选）
@MainActor
final class DocumentSelfTestRunner {
    private let source: any LibrarySource
    private let root: String
    private let limit: Int?

    init(source: any LibrarySource, root: String, limit: Int?) {
        self.source = source
        self.root = root
        self.limit = limit
    }

    func run() async {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        Log.notice(.app, "DOCSELFTEST 开始 root=\(root.isEmpty ? "/" : root)")
        let documents = await collectDocuments()
        Log.notice(.app, "DOCSELFTEST 收集文档=\(documents.count)")

        var records: [DocumentSelfTestRecord] = []
        for (index, entry) in documents.enumerated() {
            if Task.isCancelled { break }
            let record = await test(entry)
            records.append(record)
            Log.info(
                .app,
                "DOCSELFTEST \(record.passed ? "PASS" : "FAIL") "
                    + "[\(index + 1)/\(documents.count)] \(Log.shortPath(entry.path)) "
                    + "格式=\(record.format) 字节=\(record.bytes) "
                    + "读取=\(record.loadMilliseconds)ms 渲染=\(record.renderMilliseconds)ms "
                    + "表格=\(record.tables) 代码=\(record.codeBlocks) 高亮=\(record.highlighted) "
                    + "标题=\(record.headings) 到底=\(record.reachedBottom ? "是" : "否") "
                    + "页数=\(record.pageCount)"
                    + (record.message.map { " 原因=\($0)" } ?? "")
            )
            await Task.yield()
        }

        let passed = records.filter(\.passed).count
        let report = DocumentSelfTestReport(
            root: root,
            startedAt: startedAt,
            finishedAt: ISO8601DateFormatter().string(from: Date()),
            total: records.count,
            passed: passed,
            failed: records.count - passed,
            records: records
        )
        write(report)
        Log.notice(
            .app,
            "DOCSELFTEST 完成 总数=\(report.total) 通过=\(report.passed) 失败=\(report.failed)"
        )
    }

    private func collectDocuments() async -> [MediaEntry] {
        var queue = [root]
        var visited = Set<String>()
        var documents: [MediaEntry] = []

        while !queue.isEmpty, !Task.isCancelled {
            let path = queue.removeFirst()
            guard visited.insert(path).inserted else { continue }
            guard visited.count <= 1_000 else {
                Log.notice(.app, "DOCSELFTEST 目录数量达到上限")
                break
            }

            do {
                let entries = try await source.listAllEntries(path: path)
                for entry in entries {
                    if entry.isDirectory {
                        if !entry.name.hasPrefix(".") {
                            queue.append(entry.path)
                        }
                    } else if entry.isDocument {
                        documents.append(entry)
                    }
                }
            } catch {
                Log.error(
                    .app,
                    "DOCSELFTEST 目录枚举失败 \(Log.shortPath(path.isEmpty ? "/" : path)) "
                        + error.localizedDescription
                )
            }
        }

        documents.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if let limit, limit > 0 {
            return Array(documents.prefix(limit))
        }
        return documents
    }

    private func test(_ entry: MediaEntry) async -> DocumentSelfTestRecord {
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let loaded = try await DocumentLoader(source: source).load(entry)
            switch loaded.content {
            case .markdown(let markdown):
                let renderBegan = ProcessInfo.processInfo.systemUptime
                let snapshot = try await MarkdownDOMProbe().snapshot(
                    html: MarkdownHTMLTemplate.make(markdown: markdown)
                )
                let renderMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - renderBegan) * 1000
                )
                let expectations = MarkdownExpectations(markdown: markdown)
                var failures: [String] = []
                if expectations.expectsTables, snapshot.tables == 0 {
                    failures.append("表格未渲染")
                }
                if expectations.expectsCode, snapshot.codeBlocks == 0 {
                    failures.append("代码块未渲染")
                }
                if expectations.expectsHighlight, snapshot.highlighted == 0 {
                    failures.append("代码块未高亮")
                }
                if !snapshot.reachedBottom {
                    failures.append("无法滚动到底部")
                }
                if snapshot.pwned || snapshot.inlineScripts > 0 {
                    failures.append("脚本未清洗")
                }
                return DocumentSelfTestRecord(
                    path: entry.path,
                    format: loaded.format.rawValue,
                    bytes: loaded.byteCount,
                    loadMilliseconds: loaded.loadMilliseconds,
                    renderMilliseconds: renderMilliseconds,
                    tables: snapshot.tables,
                    codeBlocks: snapshot.codeBlocks,
                    highlighted: snapshot.highlighted,
                    headings: snapshot.headings,
                    reachedBottom: snapshot.reachedBottom,
                    pageCount: 0,
                    passed: failures.isEmpty,
                    message: failures.isEmpty ? nil : failures.joined(separator: "；")
                )

            case .pdf(let box):
                let pageCount = box.document.pageCount
                let lastPageRendered: Bool
                if pageCount > 0 {
                    lastPageRendered = box.document.page(at: pageCount - 1)?.thumbnail(
                        of: CGSize(width: 220, height: 293),
                        for: .cropBox
                    ) != nil
                } else {
                    lastPageRendered = false
                }
                var failures: [String] = []
                if pageCount == 0 { failures.append("PDF 没有页面") }
                if !lastPageRendered { failures.append("末页无法渲染") }
                return DocumentSelfTestRecord(
                    path: entry.path,
                    format: loaded.format.rawValue,
                    bytes: loaded.byteCount,
                    loadMilliseconds: loaded.loadMilliseconds,
                    renderMilliseconds: 0,
                    tables: 0,
                    codeBlocks: 0,
                    highlighted: 0,
                    headings: 0,
                    reachedBottom: lastPageRendered,
                    pageCount: pageCount,
                    passed: failures.isEmpty,
                    message: failures.isEmpty ? nil : failures.joined(separator: "；")
                )
            }
        } catch {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return DocumentSelfTestRecord(
                path: entry.path,
                format: entry.documentFormat?.rawValue ?? "unknown",
                bytes: entry.size,
                loadMilliseconds: elapsed,
                renderMilliseconds: 0,
                tables: 0,
                codeBlocks: 0,
                highlighted: 0,
                headings: 0,
                reachedBottom: false,
                pageCount: 0,
                passed: false,
                message: message
            )
        }
    }

    private func write(_ report: DocumentSelfTestReport) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let stamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("DocumentSelfTest-\(stamp).json")
            try data.write(to: url, options: .atomic)
            Log.notice(.app, "DOCSELFTEST 报告已写入 \(url.path)")
        } catch {
            Log.error(.app, "DOCSELFTEST 报告写入失败 \(error.localizedDescription)")
        }
    }
}

/// 从 Markdown 源码粗略判断“应该出现什么”，用于发现渲染器漏掉表格/代码块。
private struct MarkdownExpectations {
    let expectsTables: Bool
    let expectsCode: Bool
    let expectsHighlight: Bool

    private static let highlightedLanguages: Set<String> = [
        "cpp", "c++", "swift", "objc", "objectivec", "bash", "sh", "shell",
        "python", "py", "json", "yaml", "yml", "kotlin", "javascript", "js",
        "sql", "xml", "c", "go", "java", "rust", "ruby", "php", "css", "html",
    ]

    init(markdown: String) {
        var inFence = false
        var tables = false
        var code = false
        var highlight = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if !inFence {
                    code = true
                    let language = String(line.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    if Self.highlightedLanguages.contains(language) {
                        highlight = true
                    }
                }
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            if line.hasPrefix("|"), line.contains("---") {
                tables = true
            }
        }

        self.expectsTables = tables
        self.expectsCode = code
        self.expectsHighlight = highlight
    }
}
