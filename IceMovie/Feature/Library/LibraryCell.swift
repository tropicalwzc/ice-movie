import MediaLibraryKit
import SwiftUI
import UIKit

/// 2:3 海报。封面未就绪时占位尺寸固定，避免网格跳动。
struct LibraryPoster: View {
    let entry: MediaEntry
    /// 图片宽/高；nil 时使用原来的 2:3 海报比例。
    let aspectRatio: CGFloat?
    let onAspectRatio: (CGFloat) -> Void

    @Environment(LibraryStore.self) private var store
    @State private var image: UIImage?
    @State private var loadFailed = false

    init(
        entry: MediaEntry,
        aspectRatio: CGFloat? = nil,
        onAspectRatio: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.entry = entry
        self.aspectRatio = aspectRatio
        self.onAspectRatio = onAspectRatio
    }

    private var posterAspectRatio: CGFloat {
        guard entry.isImage, let aspectRatio else { return 2 / 3 }
        return min(2.5, max(0.4, aspectRatio))
    }

    var body: some View {
        Color.clear
            .aspectRatio(posterAspectRatio, contentMode: .fit)
            .overlay {
                ZStack {
                    placeholder

                    if entry.isDirectory {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 34, weight: .regular))
                                .foregroundStyle(.white.opacity(0.92))
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        }
                    } else if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: entry.isImage ? .fit : .fill)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 6) {
                            Image(
                                systemName: loadFailed
                                    ? (entry.isImage ? "photo.slash" : "film.slash")
                                    : (entry.isImage ? "photo" : "film")
                            )
                            .font(.system(size: 26, weight: .light))
                            if loadFailed {
                                Text(entry.isImage ? "无预览" : "无封面")
                                    .font(.caption2)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .clipped()
            }
            .overlay(alignment: .topLeading) {
                if entry.isLivePhoto {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.black.opacity(0.48))
                        )
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if entry.isDirectory, image != nil {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.48)))
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if entry.isDirectory, store.isPhotoLibraryTarget(path: entry.path) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(
                            Circle()
                                .fill(Color.accentColor.opacity(0.9))
                        )
                        .padding(7)
                        .accessibilityLabel("照片库路径")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
            }
            .task(id: taskID) { await load() }
    }

    private var taskID: String {
        "\(entry.path)|\(entry.size)|\(entry.modified?.timeIntervalSince1970 ?? 0)"
    }

    @ViewBuilder
    private var placeholder: some View {
        if entry.isDirectory {
            LinearGradient(
                colors: [
                    Color(uiColor: .tertiarySystemFill),
                    Color(uiColor: .secondarySystemFill),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if entry.isImage {
            // 图片用深色底完整居中，不再在浅色页面上留下明显白边。
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.09),
                    Color(red: 0.12, green: 0.13, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color(uiColor: .secondarySystemBackground),
                    Color(uiColor: .tertiarySystemBackground),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func load() async {
        if entry.isDirectory {
            image = await store.folderCover(for: entry)
            return
        }

        // 单元格滑出屏幕时请求会被取消；取消不是“图片损坏”，不能把它记成永久失败。
        // 预取取消、快速滑动都可能让第一次请求返回空，这里再重试一次。
        for attempt in 0..<2 {
            let loaded = await store.thumbnail(for: entry)
            if Task.isCancelled { return }
            if let loaded {
                // 先回填比例，再让图片进入视图，避免旧 2:3 占位框闪一帧黑边。
                if entry.isImage, loaded.size.height > 0 {
                    onAspectRatio(loaded.size.width / loaded.size.height)
                }
                image = loaded
                loadFailed = false
                return
            }
            guard attempt == 0 else { break }
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
        }
        loadFailed = true
    }
}

struct LibraryCell: View {
    let entry: MediaEntry
    @State private var aspectRatio: CGFloat?
    @State private var pendingAspectRatio: CGFloat?

    @Environment(LibraryStore.self) private var store
    @Environment(PhotoSyncModel.self) private var photoSync
    @Environment(\.libraryIsScrolling) private var isScrolling
    @State private var showsPreparing = false

    init(entry: MediaEntry, initialAspectRatio: CGFloat? = nil) {
        self.entry = entry
        _aspectRatio = State(initialValue: initialAspectRatio)
    }

    /// 当前点击的视频正在打开 SMB 文件、探测媒体信息，播放器还没出现。
    private var isPreparing: Bool {
        entry.kind == .video && store.preparingPlaybackID == entry.id
    }

    private func applyAspectRatio(_ ratio: CGFloat) {
        guard abs((aspectRatio ?? -1) - ratio) > 0.01 else { return }
        aspectRatio = ratio
    }

    private var accessibilityHint: String {
        switch entry.kind {
        case .directory: "进入文件夹"
        case .video: "开始播放"
        case .image: "打开图片"
        case .markdown, .pdf: "打开文档"
        case .other: ""
        }
    }

    var body: some View {
        Button {
            store.activate(entry)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                LibraryPoster(
                    entry: entry,
                    aspectRatio: aspectRatio,
                    onAspectRatio: { ratio in
                        store.rememberAspectRatio(ratio, for: entry)
                        if isScrolling, aspectRatio != nil {
                            // 已有比例时，滑动中不再改高度；首次加载必须立即应用，
                            // 否则会先按 2:3 显示一帧黑边再跳成真实比例。
                            pendingAspectRatio = ratio
                        } else {
                            applyAspectRatio(ratio)
                        }
                    }
                )
                .overlay { preparingOverlay }

                Text(store.displayTitle(for: entry))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(store.subtitle(for: entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .accessibilityIdentifier("media.\(entry.id)")
        .accessibilityLabel(entry.name)
        .accessibilityHint(accessibilityHint)
        .accessibilityValue(isPreparing ? Text("正在打开") : Text(""))
        .contextMenu {
            if entry.isDirectory {
                if photoSync.isTarget(path: entry.path) {
                    Button(role: .destructive) {
                        photoSync.unmark(path: entry.path)
                    } label: {
                        Label("取消照片库标记", systemImage: "photo.stack")
                    }
                    .accessibilityIdentifier("photoSync.cell.unmark.\(entry.id)")
                } else {
                    Button {
                        photoSync.requestMark(path: entry.path)
                    } label: {
                        Label("设为照片库路径", systemImage: "photo.stack")
                    }
                    .accessibilityIdentifier("photoSync.cell.mark.\(entry.id)")
                }
            }
        }
        .onChange(of: isScrolling) { _, scrolling in
            guard !scrolling, let pendingAspectRatio else { return }
            self.pendingAspectRatio = nil
            applyAspectRatio(pendingAspectRatio)
        }
        .task(id: isPreparing) {
            guard isPreparing else {
                withAnimation(.easeOut(duration: 0.15)) { showsPreparing = false }
                return
            }
            // 起播很快时不必闪一下转圈，超过一小段等待再显示。
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { showsPreparing = true }
        }
    }

    @ViewBuilder
    private var preparingOverlay: some View {
        if showsPreparing {
            ZStack {
                Color.black.opacity(0.32)

                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)

                    Text("正在打开…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}
