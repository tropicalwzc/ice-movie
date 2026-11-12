import Foundation
import MediaLibraryKit

/// 会话内 Markdown HTML 缓存。
///
/// key 包含数据源命名空间、路径、大小与修改时间；共享切换或源文件变化后
/// 自然失效。缓存只存已生成的 HTML，不存 WKWebView。
@MainActor
final class DocumentHTMLCache {
    static let shared = DocumentHTMLCache()

    private let cache = NSCache<NSString, NSString>()

    private init() {
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func html(for entry: MediaEntry, namespace: String) -> String? {
        cache.object(forKey: key(for: entry, namespace: namespace) as NSString) as String?
    }

    func store(_ html: String, for entry: MediaEntry, namespace: String) {
        cache.setObject(
            html as NSString,
            forKey: key(for: entry, namespace: namespace) as NSString,
            cost: html.utf8.count
        )
    }

    private func key(for entry: MediaEntry, namespace: String) -> String {
        let modified = entry.modified?.timeIntervalSince1970 ?? 0
        return "\(namespace)|\(entry.path)|\(entry.size)|\(modified)"
    }
}
