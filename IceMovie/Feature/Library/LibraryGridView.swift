import MediaLibraryKit
import SwiftUI

struct LibraryGridView: View {
    @Environment(LibraryStore.self) private var store
    @State private var scrollAnchor: String?

    var body: some View {
        GeometryReader { proxy in
            let columnCount = LibraryGridLayout.columnCount(availableWidth: proxy.size.width)
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: LibraryGridLayout.spacing, alignment: .top),
                count: columnCount
            )

            ScrollView {
                if store.isLoading, store.currentEntries.isEmpty {
                    LibrarySkeletonGrid(columns: columnCount)
                        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
                        .padding(.vertical, 14)
                } else if let error = store.errorMessage, store.currentEntries.isEmpty {
                    errorState(error)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.7)
                } else if store.currentEntries.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.7)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(store.currentEntries) { entry in
                            LibraryCell(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, LibraryGridLayout.horizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
            .scrollPosition(id: $scrollAnchor, anchor: .top)
            .onAppear {
                scrollAnchor = store.scrollAnchor(for: store.currentPath)
            }
            .onChange(of: scrollAnchor) { _, newValue in
                guard let newValue else { return }
                store.setScrollAnchor(newValue)
            }
            .onChange(of: store.currentEntries.count) { _, _ in
                // 从搜索跳回目录时，条目加载完成后按记录的条目定位。
                if let anchor = store.scrollAnchor(for: store.currentPath), scrollAnchor == nil {
                    scrollAnchor = anchor
                }
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("无法打开这个目录", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                Task { await store.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("这里还没有视频", systemImage: "film.stack")
        } description: {
            Text(store.canGoBack ? "这个目录既没有可播放的视频，也没有子目录。" : "共享根目录为空，或当前账号没有读取权限。")
        } actions: {
            if store.canGoBack {
                Button("返回上一级") { store.goBack() }
            }
        }
    }
}

/// 加载骨架：尺寸与真实单元格一致，避免整屏空白与布局跳动。
struct LibrarySkeletonGrid: View {
    let columns: Int

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: LibraryGridLayout.spacing, alignment: .top),
                count: max(1, columns)
            ),
            alignment: .leading,
            spacing: 22
        ) {
            ForEach(0..<(max(1, columns) * 2), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                        .aspectRatio(2 / 3, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(height: 11)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(uiColor: .quaternarySystemFill))
                        .frame(width: 60, height: 9)
                }
                .redacted(reason: .placeholder)
            }
        }
    }
}
