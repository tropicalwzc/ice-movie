import MediaLibraryKit
import SwiftUI

struct LibraryGridView: View {
    @Environment(LibraryStore.self) private var store
    @State private var isScrolling = false
    @State private var anchorTracker = ScrollAnchorTracker()
    @State private var prefetchSeed: (items: [MediaEntry], index: Int)?
    @State private var prefetchDebounceTask: Task<Void, Never>?
    /// 目录条目的列分配。同步在顶部插入新照片时，已有条目保持原列，
    /// 避免整张网格重新洗牌造成抖动。
    @State private var columnAssignments: [String: Int] = [:]

    var body: some View {
        GeometryReader { proxy in
            let columnCount = LibraryGridLayout.columnCount(availableWidth: proxy.size.width)
            let displayedEntries = store.favoritesOnly
                ? store.favoriteEntries
                : store.currentEntries

            ScrollViewReader { reader in
                ScrollView {
                if !store.favoritesOnly, store.isLoading, displayedEntries.isEmpty {
                    LibrarySkeletonGrid(columns: columnCount)
                        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
                        .padding(.vertical, 14)
                } else if !store.favoritesOnly,
                          let error = store.errorMessage,
                          displayedEntries.isEmpty {
                    errorState(error)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.7)
                } else if displayedEntries.isEmpty {
                    Group {
                        if store.favoritesOnly {
                            favoritesEmptyState
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.7)
                } else {
                    content(section: store.contentSections, columnCount: columnCount)
                }
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.2) { ids in
                anchorTracker.current = ids.first
            }
            .onScrollPhaseChange { _, phase in
                isScrolling = phase != .idle
                if phase == .idle {
                    ScrollFPSMonitor.shared.end()
                } else {
                    ScrollFPSMonitor.shared.begin(reason: "grid")
                }
            }
            .onChange(of: isScrolling) { _, scrolling in
                store.setGridScrolling(scrolling)
                if scrolling {
                    prefetchDebounceTask?.cancel()
                    store.cancelThumbnailPrefetches()
                } else {
                    schedulePrefetch()
                }
            }
            .environment(\.libraryIsScrolling, isScrolling)
            .onDisappear {
                prefetchDebounceTask?.cancel()
                store.cancelThumbnailPrefetches()
                store.setScrollAnchor(anchorTracker.current)
            }
            .onAppear {
                restoreScroll(reader)
            }
            .onChange(of: store.currentEntries.count) { oldCount, _ in
                // 内容从空到有：等布局完成后再恢复锚点。
                guard oldCount == 0 else { return }
                restoreScroll(reader)
            }
            .onChange(of: assignmentEntries.map(\.id)) { _, _ in
                columnAssignments = resolvedAssignments(
                    for: assignmentEntries,
                    columnCount: columnCount
                )
            }
            .onChange(of: columnCount) { _, newCount in
                columnAssignments = resolvedAssignments(
                    for: assignmentEntries,
                    columnCount: newCount
                )
            }
            .onChange(of: store.favoritesOnly) { _, _ in
                columnAssignments = [:]
            }
            .onChange(of: store.pendingScrollTarget) { _, target in
                guard let target else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    reader.scrollTo(target, anchor: .top)
                    try? await Task.sleep(for: .milliseconds(120))
                    if store.pendingScrollTarget == target {
                        store.consumePendingScrollTarget()
                    }
                }
            }
            }
        }
    }

    private func restoreScroll(_ reader: ScrollViewProxy) {
        guard let anchor = store.scrollAnchor(for: store.currentPath) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            reader.scrollTo(anchor, anchor: .top)
        }
    }

    @ViewBuilder
    private func content(
        section: LibraryContentSectioning,
        columnCount: Int
    ) -> some View {
        let gridItems = store.visibleGridItems
        switch section.presentation {
        case .empty:
            emptyState
                .frame(maxWidth: .infinity, minHeight: 240)
        case .mediaGrid:
            if gridItems.isEmpty {
                filterEmptyState
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                mediaGrid(items: gridItems, columnCount: columnCount)
            }
        case .mixed:
            VStack(alignment: .leading, spacing: 22) {
                if gridItems.isEmpty {
                    filterNotice
                } else {
                    mediaGrid(items: gridItems, columnCount: columnCount)
                }
                documentSection(items: section.documentItems)
            }
        case .documentsOnly:
            documentsOnlyList(items: section.documentListItems)
        }
    }

    /// 瀑布流：每个图片单元格按自身宽高比决定高度，避免固定 2:3 海报框留下大片黑边。
    /// 用两条独立的 LazyVStack 保持懒加载；条目按顺序交替分列，滚动位置稳定。
    private func mediaGrid(items: [MediaEntry], columnCount: Int) -> some View {
        // 条目少于列数时不要再保留空列，否则 iPad 4 列、只有 2-3 张图时
        // 右侧会出现一整列空白；列分配复用已有条目的稳定列。
        let buckets = buckets(for: items, columnCount: columnCount)
        return HStack(alignment: .top, spacing: LibraryGridLayout.spacing) {
            ForEach(buckets.indices, id: \.self) { column in
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(buckets[column].enumerated()), id: \.element.id) { index, entry in
                        LibraryCell(
                            entry: entry,
                            initialAspectRatio: store.aspectRatio(for: entry)
                        )
                        .id(entry.id)
                        .onAppear {
                            prefetchSeed = (buckets[column], index)
                            if !isScrolling {
                                schedulePrefetch()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .scrollTargetLayout()
            }
        }
        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    /// 停止滚动后延迟预取，避免 onAppear 密集触发几十个后台任务。
    private func schedulePrefetch() {
        guard !ProcessInfo.processInfo.arguments.contains("-disableThumbnailPrefetch") else {
            return
        }
        prefetchDebounceTask?.cancel()
        prefetchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, !isScrolling, let seed = prefetchSeed else { return }
            prefetchUpcoming(after: seed.index, in: seed.items)
        }
    }

    /// 每条瀑布流列各自向前预取；滑到该列底部前，封面和解码已经准备好。
    private func prefetchUpcoming(after index: Int, in items: [MediaEntry]) {
        guard index + 1 < items.count else { return }
        let upcoming = Array(items[(index + 1)...].prefix(12))
        store.prefetchThumbnails(for: upcoming)
    }

    /// 稳定列分配：已有条目保持原列，新条目分到当前条目最少的列。
    /// 这样同步在列表顶部插入照片时不会让整张网格重新洗牌。
    private var assignmentEntries: [MediaEntry] {
        store.favoritesOnly ? store.favoriteEntries : store.currentEntries
    }

    private func resolvedAssignments(
        for items: [MediaEntry],
        columnCount: Int
    ) -> [String: Int] {
        guard columnCount > 1 else {
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, 0) })
        }
        let ids = Set(items.map(\.id))
        var assignments = columnAssignments.filter {
            ids.contains($0.key) && $0.value >= 0 && $0.value < columnCount
        }
        var counts = Array(repeating: 0, count: columnCount)
        for column in assignments.values where column < columnCount {
            counts[column] += 1
        }
        for item in items where assignments[item.id] == nil {
            let column = counts.indices.min { lhs, rhs in
                if counts[lhs] != counts[rhs] { return counts[lhs] < counts[rhs] }
                return lhs < rhs
            } ?? 0
            assignments[item.id] = column
            counts[column] += 1
        }
        return assignments
    }

    /// 按稳定列分配把可见条目拆成瀑布流列；空列不参与宽度分配。
    private func buckets(
        for items: [MediaEntry],
        columnCount: Int
    ) -> [[MediaEntry]] {
        guard columnCount > 1 else {
            return items.isEmpty ? [] : [items]
        }
        let assignments = resolvedAssignments(
            for: assignmentEntries,
            columnCount: columnCount
        )
        var buckets = Array(repeating: [MediaEntry](), count: columnCount)
        for item in items {
            if let column = assignments[item.id], column < columnCount {
                buckets[column].append(item)
            }
        }
        return buckets.filter { !$0.isEmpty }
    }

    private func documentSection(items: [MediaEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            documentHeader(count: items.count)
            LazyVStack(spacing: 8) {
                ForEach(items) { entry in
                    DocumentRow(entry: entry)
                        .id(entry.id)
                }
            }
            .scrollTargetLayout()
        }
        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
        .padding(.bottom, 28)
    }

    private func documentsOnlyList(items: [MediaEntry]) -> some View {
        let directories = items.filter(\.isDirectory)
        let documents = items.filter(\.isDocument)

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(directories) { entry in
                DocumentDirectoryRow(entry: entry)
                    .id(entry.id)
            }

            if !documents.isEmpty {
                documentHeader(count: documents.count)
                    .padding(.top, directories.isEmpty ? 0 : 10)
                LazyVStack(spacing: 8) {
                    ForEach(documents) { entry in
                        DocumentRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .scrollTargetLayout()
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    private func documentHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("文档")
                .font(.headline)
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            Spacer(minLength: 0)
            Text("MD / PDF")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var filterNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("已隐藏全部视频和图片")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("显示全部") {
                withAnimation(.snappy(duration: 0.18)) {
                    store.resetMediaFilter()
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
        .padding(.top, 12)
    }

    private var filterEmptyState: some View {
        ContentUnavailableView {
            Label("当前筛选下没有内容", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("已隐藏全部视频和图片。显示全部即可恢复网格内容。")
        } actions: {
            Button("显示全部") {
                withAnimation(.snappy(duration: 0.18)) {
                    store.resetMediaFilter()
                }
            }
            .buttonStyle(.borderedProminent)
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

    private var favoritesEmptyState: some View {
        ContentUnavailableView {
            Label("还没有收藏照片", systemImage: "heart")
        } description: {
            Text("打开任意照片，点左上角的心形按钮即可加入收藏夹。")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("这里还没有可浏览的内容", systemImage: "film.stack")
        } description: {
            Text(
                store.canGoBack
                    ? "这个目录没有视频、图片、文档或子目录。"
                    : "共享根目录为空，或当前账号没有读取权限。"
            )
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

/// 只记录当前可见锚点，不参与 SwiftUI 观察，避免滚动时触发整页重算。
@MainActor
private final class ScrollAnchorTracker {
    var current: String?
}
