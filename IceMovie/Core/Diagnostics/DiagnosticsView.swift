import IceCore
import SwiftUI
import UIKit

/// App 内诊断页：查看、过滤、复制日志，避免复现问题时必须连 Mac 抓 Console。
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LogEntry] = []
    @State private var category: LogCategory?
    @State private var showDebug = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(entry.category.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(entry.level.label)
                            .font(.caption2.monospaced())
                            .foregroundStyle(color(for: entry.level))
                    }
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .listStyle(.plain)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "text.alignleft")
                }
            }
            .searchable(text: $query, prompt: "筛选内容")
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("分类", selection: $category) {
                            Text("全部").tag(LogCategory?.none)
                            ForEach(LogCategory.allCases, id: \.self) { item in
                                Text(item.rawValue).tag(LogCategory?.some(item))
                            }
                        }
                        Toggle("显示 DEBUG", isOn: $showDebug)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("复制全部", systemImage: "doc.on.doc") { copyAll() }
                        Button("清空", systemImage: "trash", role: .destructive) {
                            LogStore.shared.clear()
                            entries = []
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await poll() }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .notice: .orange
        case .error: .red
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func refresh() {
        var result = LogStore.shared.snapshot(
            minimumLevel: showDebug ? .debug : .info,
            category: category
        )
        let keyword = query.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            result = result.filter { $0.message.localizedCaseInsensitiveContains(keyword) }
        }
        entries = result
    }

    private func copyAll() {
        let text = entries
            .map { "\($0.date.formatted(.iso8601)) [\($0.category.rawValue)] \($0.level.label) \($0.message)" }
            .joined(separator: "\n")
        UIPasteboard.general.string = text
    }
}
