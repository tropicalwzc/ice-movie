import Foundation
import SwiftUI
import UIKit
import WebKit

/// 一条 Markdown 标题，用于目录。
struct MarkdownHeading: Identifiable, Equatable, Sendable {
    let level: Int
    let text: String
    let id: String
}

/// 让工具栏能向 WKWebView 发送“滚动到标题”命令。
@MainActor
@Observable
final class MarkdownWebController {
    weak var webView: WKWebView?

    func scroll(to headingID: String) {
        guard let data = try? JSONEncoder().encode(headingID),
              let quoted = String(data: data, encoding: .utf8) else {
            return
        }
        webView?.evaluateJavaScript("window.scrollToHeading(\(quoted));")
    }
}

struct MarkdownReaderView: View {
    let html: String
    let title: String

    @State private var headings: [MarkdownHeading] = []
    @State private var showTOC = false
    @State private var isReady = false
    @State private var renderError: String?
    @State private var reloadToken = 0
    @State private var controller = MarkdownWebController()

    init(html: String, title: String) {
        self.html = html
        self.title = title
    }

    var body: some View {
        ZStack {
            MarkdownWebView(
                html: html,
                controller: controller,
                onHeadings: { headings = $0 },
                onReady: {
                    isReady = true
                    renderError = nil
                },
                onError: { message in
                    isReady = true
                    renderError = message
                }
            )
            .id(reloadToken)
            .accessibilityIdentifier("document.reader.markdown")

            if !isReady {
                ProgressView("正在渲染文档…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            if let errorMessage = renderError {
                ContentUnavailableView {
                    Label("渲染失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重新加载") {
                        isReady = false
                        renderError = nil
                        headings = []
                        reloadToken += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar {
            if !headings.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTOC = true
                    } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                    .accessibilityLabel("目录")
                    .accessibilityIdentifier("document.toc")
                }
            }
        }
        .sheet(isPresented: $showTOC) {
            MarkdownTOCSheet(headings: headings) { heading in
                controller.scroll(to: heading.id)
                showTOC = false
            }
            .presentationDetents([.medium, .large])
        }
    }
}

struct MarkdownTOCSheet: View {
    let headings: [MarkdownHeading]
    let onSelect: (MarkdownHeading) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(headings) { heading in
                Button {
                    onSelect(heading)
                    dismiss()
                } label: {
                    Text(heading.text)
                        .font(heading.level == 1 ? .headline : heading.level == 2 ? .subheadline : .footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            .listStyle(.plain)
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct MarkdownWebView: UIViewRepresentable {
    let html: String
    let controller: MarkdownWebController
    let onHeadings: @MainActor ([MarkdownHeading]) -> Void
    let onReady: @MainActor () -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            onHeadings: onHeadings,
            onReady: onReady,
            onError: onError
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.messageHandlerName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.loadHTMLString(html, baseURL: nil)
        controller.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        controller.webView = webView
        context.coordinator.onHeadings = onHeadings
        context.coordinator.onReady = onReady
        context.coordinator.onError = onError
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageHandlerName
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.controller.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "documentReader"

        let controller: MarkdownWebController
        var onHeadings: @MainActor ([MarkdownHeading]) -> Void
        var onReady: @MainActor () -> Void
        var onError: @MainActor (String) -> Void

        init(
            controller: MarkdownWebController,
            onHeadings: @escaping @MainActor ([MarkdownHeading]) -> Void,
            onReady: @escaping @MainActor () -> Void,
            onError: @escaping @MainActor (String) -> Void
        ) {
            self.controller = controller
            self.onHeadings = onHeadings
            self.onReady = onReady
            self.onError = onError
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageHandlerName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "toc":
                let items = (body["items"] as? [[String: Any]] ?? []).compactMap { item -> MarkdownHeading? in
                    guard let level = item["level"] as? Int,
                          let text = item["text"] as? String,
                          let id = item["id"] as? String else {
                        return nil
                    }
                    return MarkdownHeading(level: level, text: text, id: id)
                }
                onHeadings(items)
            case "copy":
                if let text = body["text"] as? String {
                    UIPasteboard.general.string = text
                }
            case "ready":
                onReady()
            case "error":
                onError(body["message"] as? String ?? "未知渲染错误")
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.absoluteString == "about:blank" || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased()
            if navigationAction.navigationType == .linkActivated,
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // 文档内锚点由 JS scrollIntoView 处理；其他 scheme 一律不导航。
            decisionHandler(.cancel)
        }
    }
}
