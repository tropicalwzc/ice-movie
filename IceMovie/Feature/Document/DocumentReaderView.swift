import Foundation
import IceCore
import MediaLibraryKit
import SwiftUI

/// 文档阅读器的加载状态。Markdown 与 PDF 共用同一层外壳，
/// 只把已加载的内容交给对应的渲染器。
@MainActor
@Observable
final class DocumentReaderModel {
    enum Content {
        case markdownHTML(String)
        case pdf(PDFDocumentBox)
    }

    enum State {
        case loading
        case loaded(Content)
        case failed(String)
    }

    let entry: MediaEntry
    let loader: DocumentLoader
    let namespace: String
    private(set) var state: State = .loading
    private var task: Task<Void, Never>?
    private var generation = 0

    init(entry: MediaEntry, source: any LibrarySource) {
        self.entry = entry
        self.loader = DocumentLoader(source: source)
        self.namespace = source.cacheNamespace
    }

    func load() {
        task?.cancel()
        generation += 1
        let generation = generation
        state = .loading

        if let cached = DocumentHTMLCache.shared.html(for: entry, namespace: namespace) {
            Log.debug(.app, "文档 HTML 缓存命中 \(Log.shortPath(entry.path))")
            state = .loaded(.markdownHTML(cached))
            return
        }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loader.load(entry)
                guard !Task.isCancelled, generation == self.generation else { return }
                switch loaded.content {
                case .markdown(let markdown):
                    let html = MarkdownHTMLTemplate.make(markdown: markdown)
                    DocumentHTMLCache.shared.store(html, for: entry, namespace: namespace)
                    state = .loaded(.markdownHTML(html))
                case .pdf(let box):
                    state = .loaded(.pdf(box))
                }
            } catch {
                if error is CancellationError { return }
                if let loadError = error as? DocumentLoadError, loadError == .cancelled {
                    return
                }
                guard !Task.isCancelled, generation == self.generation else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                state = .failed(message)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// 文档阅读器外壳：负责读取、加载态、错误与重试，具体排版交给 Markdown/PDF 渲染器。
struct DocumentReaderView: View {
    let entry: MediaEntry
    @Environment(LibraryStore.self) private var store
    @State private var model: DocumentReaderModel?

    private var title: String {
        DocumentMetadata(entry: entry)?.title ?? entry.name
    }

    var body: some View {
        Group {
            if let model {
                switch model.state {
                case .loading:
                    loadingState
                case .loaded(let content):
                    switch content {
                    case .markdownHTML(let html):
                        MarkdownReaderView(html: html, title: title)
                    case .pdf(let box):
                        PDFReaderView(document: box.document, title: title)
                    }
                case .failed(let message):
                    failureState(message)
                }
            } else {
                loadingState
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let model = DocumentReaderModel(entry: entry, source: store.source)
            self.model = model
            model.load()
        }
        .onDisappear {
            model?.cancel()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("正在读取文档…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(uiColor: .systemBackground))
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("无法打开文档", systemImage: "doc.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                model?.load()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
