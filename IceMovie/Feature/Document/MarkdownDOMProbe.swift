import Foundation
import WebKit

/// WKWebView 渲染后的 DOM 摘要。用于真机验收与渲染回归：
/// 确认表格、代码块、高亮、目录标题都存在，并且能滚动到文档底部。
struct MarkdownDOMSnapshot: Sendable {
    let tables: Int
    let codeBlocks: Int
    let highlighted: Int
    let headings: Int
    let documentHeight: Double
    let reachedBottom: Bool
    let pwned: Bool
    let inlineScripts: Int
    let eventAttributes: Int
    let remoteResources: Int
}

enum MarkdownDOMProbeError: LocalizedError {
    case timeout
    case invalidResult
    case webViewUnavailable

    var errorDescription: String? {
        switch self {
        case .timeout: "Markdown 渲染超时"
        case .invalidResult: "无法读取 Markdown 渲染结果"
        case .webViewUnavailable: "WebView 不可用"
        }
    }
}

/// 在离屏 WKWebView 中渲染同一份 HTML，并读取 DOM 指标。
/// 生产界面与验收共用同一个 MarkdownHTMLTemplate，避免“测试通过但界面不同”。
@MainActor
final class MarkdownDOMProbe: NSObject, WKScriptMessageHandler {
    private static let messageHandlerName = "documentReader"

    private var webView: WKWebView?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func snapshot(html: String, timeout: Duration = .seconds(20)) async throws -> MarkdownDOMSnapshot {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: Self.messageHandlerName)

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 1366),
            configuration: configuration
        )
        self.webView = webView

        do {
            try await waitForReady(html: html, timeout: timeout)
            _ = try await evaluateString("window.scrollTo(0, document.body.scrollHeight); true")
            try await Task.sleep(for: .milliseconds(250))

            let json = try await evaluateString(
                """
                JSON.stringify({
                  tables: document.querySelectorAll('.table-wrap table').length,
                  codeBlocks: document.querySelectorAll('.code-block').length,
                  highlighted: document.querySelectorAll('.code-block code.hljs').length,
                  headings: document.querySelectorAll('h1,h2,h3').length,
                  height: document.body.scrollHeight,
                  y: window.scrollY,
                  viewport: window.innerHeight,
                  pwned: window.__pwned !== undefined,
                  inlineScripts: document.querySelectorAll('main script').length,
                  eventAttributes: document.querySelectorAll('main [onclick], main [onerror]').length,
                  remoteResources: performance.getEntriesByType('resource')
                    .filter(function (entry) { return entry.name.indexOf('example.com') >= 0; })
                    .length
                })
                """
            )

            guard let text = json,
                  let data = text.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MarkdownDOMProbeError.invalidResult
            }

            let height = object["height"] as? Double ?? 0
            let y = object["y"] as? Double ?? 0
            let viewport = object["viewport"] as? Double ?? 0
            return MarkdownDOMSnapshot(
                tables: object["tables"] as? Int ?? 0,
                codeBlocks: object["codeBlocks"] as? Int ?? 0,
                highlighted: object["highlighted"] as? Int ?? 0,
                headings: object["headings"] as? Int ?? 0,
                documentHeight: height,
                reachedBottom: y + viewport >= height - 4,
                pwned: object["pwned"] as? Bool ?? false,
                inlineScripts: object["inlineScripts"] as? Int ?? 0,
                eventAttributes: object["eventAttributes"] as? Int ?? 0,
                remoteResources: object["remoteResources"] as? Int ?? 0
            )
        } catch {
            cleanup()
            throw error
        }
        cleanup()
    }

    private func waitForReady(html: String, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let continuation = self.readyContinuation else { return }
                self.readyContinuation = nil
                continuation.resume(throwing: MarkdownDOMProbeError.timeout)
            }
            webView?.loadHTMLString(html, baseURL: nil)
        }
    }

    private func evaluateString(_ script: String) async throws -> String? {
        guard let webView else {
            throw MarkdownDOMProbeError.webViewUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String)
                }
            }
        }
    }

    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName
        )
        webView?.stopLoading()
        webView = nil
        readyContinuation = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }
        guard type == "ready" || type == "error" else { return }
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if type == "error" {
            continuation.resume(
                throwing: MarkdownDOMProbeError.invalidResult
            )
        } else {
            continuation.resume()
        }
    }
}
