import Foundation
import PDFKit
import SwiftUI

/// PDF 阅读状态。PDFDocument 在文档加载层创建并只读使用，
/// 这里只负责 PDFView 绑定、页码同步与跳转。
@MainActor
@Observable
final class PDFReaderModel {
    let document: PDFDocument
    var currentPage = 1
    weak var pdfView: PDFView?

    init(document: PDFDocument) {
        self.document = document
        self.currentPage = 1
    }

    var pageCount: Int { document.pageCount }

    func syncPage() {
        guard let page = pdfView?.currentPage else { return }
        let index = document.index(for: page) + 1
        if index != currentPage {
            currentPage = index
        }
    }

    func go(to pageNumber: Int) {
        guard pageCount > 0 else { return }
        let target = min(max(1, pageNumber), pageCount)
        guard let page = document.page(at: target - 1) else { return }
        pdfView?.go(to: page)
        currentPage = target
    }
}

struct PDFReaderView: View {
    let title: String

    @State private var model: PDFReaderModel
    @State private var showPages = false

    init(document: PDFDocument, title: String) {
        self.title = title
        _model = State(initialValue: PDFReaderModel(document: document))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PDFKitView(document: model.document, model: model)
                .accessibilityIdentifier("document.reader.pdf")

            if model.pageCount > 0 {
                Text("\(model.currentPage) / \(model.pageCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(14)
                    .accessibilityIdentifier("document.pageIndicator")
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .toolbar {
            if model.pageCount > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPages = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityLabel("页面")
                    .accessibilityIdentifier("document.pages")
                }
            }
        }
        .sheet(isPresented: $showPages) {
            PDFPageThumbnailsSheet(
                document: model.document,
                currentPage: model.currentPage
            ) { page in
                model.go(to: page)
                showPages = false
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let model: PDFReaderModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        view.minScaleFactor = view.scaleFactor
        view.maxScaleFactor = max(view.scaleFactor, 4)
        model.pdfView = view
        context.coordinator.observe(view)
        context.coordinator.updatePage()
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        model.pdfView = view
        if view.document !== document {
            view.document = document
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        coordinator.model.pdfView = nil
        view.document = nil
    }

    @MainActor
    final class Coordinator {
        let model: PDFReaderModel
        private var observer: NSObjectProtocol?

        init(model: PDFReaderModel) {
            self.model = model
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updatePage()
                }
            }
        }

        func stopObserving() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
        }

        func updatePage() {
            model.syncPage()
        }
    }
}

private struct PDFPageThumbnailsSheet: View {
    let document: PDFDocument
    let currentPage: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(1...max(1, document.pageCount), id: \.self) { pageNumber in
                        Button {
                            onSelect(pageNumber)
                        } label: {
                            PDFPageThumbnail(
                                document: document,
                                pageNumber: pageNumber,
                                isCurrent: pageNumber == currentPage
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("document.page.\(pageNumber)")
                    }
                }
                .padding(16)
            }
            .navigationTitle("页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct PDFPageThumbnail: View {
    let document: PDFDocument
    let pageNumber: Int
    let isCurrent: Bool

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.accentColor : Color(uiColor: .separator),
                        lineWidth: isCurrent ? 2 : 0.5
                    )
            }

            Text("\(pageNumber)")
                .font(.caption2.weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .task(id: pageNumber) {
            guard image == nil, let page = document.page(at: pageNumber - 1) else { return }
            image = page.thumbnail(
                of: CGSize(width: 220, height: 293),
                for: .cropBox
            )
        }
    }
}
