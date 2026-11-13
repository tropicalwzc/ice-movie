import IceCore
import MediaLibraryKit
import SwiftUI
import UIKit

struct ImageGalleryView: View {
    let session: ImageGallerySession
    let onClose: () -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    @State private var currentID: String?
    @State private var isZoomed = false
    @State private var memoryWarningToken = 0
    @State private var rotations: [String: Int] = [:]
    @State private var activeModel: ImagePageModel?
    @State private var isSaving = false
    @State private var showSaveConfirmation = false
    @State private var saveError: String?
    @State private var saveNotice: String?
    @State private var saveNoticeToken = 0
    @State private var showDeleteConfirmation = false
    @State private var deleteError: String?
    @State private var isDeleting = false

    init(session: ImageGallerySession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _currentID = State(initialValue: session.initialEntry?.id)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if session.entries.isEmpty {
                ContentUnavailableView {
                    Label("没有可浏览的图片", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("当前目录没有图片。")
                } actions: {
                    Button("关闭") { onClose() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 0) {
                    topChrome
                    GeometryReader { pagerProxy in
                        pager(pageSize: pagerProxy.size)
                    }
                    bottomChrome
                }
                .safeAreaPadding(.top, 4)
                .safeAreaPadding(.bottom, 4)
            }
        }
        .background(Color.black)
        .onChange(of: currentID) { _, _ in
            isZoomed = false
            // 不在这里清空 activeModel：新页面的 onModelReady 可能先于父视图回调执行。
            // 通过 currentModel 的 ID 校验屏蔽旧页面，避免依赖两个 onChange 的调用顺序。
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            memoryWarningToken += 1
        }
        .alert("覆盖原照片？", isPresented: $showSaveConfirmation) {
            Button("取消", role: .cancel) {}
            Button("覆盖保存", role: .destructive) {
                saveToServer()
            }
        } message: {
            Text("旋转后的图片会覆盖共享里的原文件。")
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert("删除这张照片？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteCurrent()
            }
        } message: {
            Text("会直接删除 SMB 共享里的原文件，无法恢复。")
        }
        .alert(
            "删除失败",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .task(id: saveNoticeToken) {
            guard saveNotice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            saveNotice = nil
        }
    }

    /// 相同文案在 4 秒内再次出现时也要重新计时。
    private func showSaveNotice(_ message: String) {
        saveNotice = message
        saveNoticeToken += 1
    }

    @ViewBuilder
    private func pager(pageSize: CGSize) -> some View {
        if pageSize.width > 0, pageSize.height > 0 {
            // 只按 pager 的实际可用区域解码；上下工具条已扣掉，避免多占 10–15% 内存。
            let targetPixelSize = Int(max(pageSize.width, pageSize.height) * displayScale)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(session.entries) { entry in
                            ImagePageView(
                                entry: entry,
                                session: session,
                                isCurrent: currentID == entry.id,
                                targetPixelSize: targetPixelSize,
                                memoryWarningToken: memoryWarningToken,
                                rotation: rotations[entry.id] ?? 0,
                                onModelReady: { model in
                                    if currentID == entry.id {
                                        activeModel = model
                                    }
                                },
                                isZoomed: $isZoomed
                            )
                            .frame(width: pageSize.width, height: pageSize.height)
                            .id(entry.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)
                .scrollDisabled(isZoomed)
                .onAppear {
                    guard let initialID = session.initialEntry?.id else { return }
                    DispatchQueue.main.async {
                        reader.scrollTo(initialID, anchor: .center)
                    }
                }
                .onChange(of: pageSize) { _, _ in
                    // 设备旋转/分屏后页宽突变，LazyHStack 会按新宽度重排；
                    // 重新锚定当前页，避免停在两页之间或页码漂移。
                    guard let currentID else { return }
                    DispatchQueue.main.async {
                        reader.scrollTo(currentID, anchor: .center)
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    private var topChrome: some View {
        HStack(spacing: 8) {
            Button {
                showDeleteConfirmation = true
            } label: {
                Group {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(isDeleting || currentEntry == nil)
            .accessibilityIdentifier("gallery.delete")
            .accessibilityLabel("删除照片")

            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isCurrentFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isCurrentFavorite ? Color.accentColor : .white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(currentEntry == nil)
            .accessibilityIdentifier("gallery.favorite")
            .accessibilityLabel(isCurrentFavorite ? "取消收藏" : "收藏照片")

            if let saveNotice {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(saveNotice)
                        .accessibilityIdentifier("gallery.notice")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            Text(counterText)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.12)))
                .accessibilityIdentifier("gallery.counter")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.black)
        .animation(.easeInOut(duration: 0.2), value: saveNotice)
    }

    private var bottomChrome: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    if currentEntry?.isLivePhoto == true {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.75)))
                    }
                    Text(currentEntry?.name ?? "")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Button {
                rotateCurrent()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(!canEditCurrent || isSaving)
            .opacity(canEditCurrent ? 1 : 0.35)
            .accessibilityLabel("顺时针旋转 90 度")
            .accessibilityIdentifier("gallery.rotate")

            if canSaveCurrent {
                Menu {
                    if currentRotation != 0, canEditCurrent {
                        Button {
                            showSaveConfirmation = true
                        } label: {
                            Label("覆盖原照片", systemImage: "square.and.arrow.down")
                        }
                    }

                    Button {
                        saveToPhotos()
                    } label: {
                        Label("保存到系统相册", systemImage: "photo.badge.plus")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.accentColor.opacity(0.8)))
                }
                .disabled(isSaving)
                .accessibilityLabel("保存图片")
                .accessibilityIdentifier("gallery.save")
            }

            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 36, height: 40)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭相册")
            .accessibilityIdentifier("gallery.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    private var currentRotation: Int {
        guard let currentID else { return 0 }
        return rotations[currentID] ?? 0
    }

    private var isCurrentFavorite: Bool {
        currentEntry.map { store.isFavorite($0) } ?? false
    }

    private func toggleFavorite() {
        guard let currentEntry else { return }
        store.toggleFavorite(currentEntry)
    }

    private func deleteCurrent() {
        guard let entry = currentEntry else { return }
        isDeleting = true
        Task {
            do {
                try await store.delete(entry: entry)
                isDeleting = false
                onClose()
            } catch {
                isDeleting = false
                deleteError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// 只接受与当前页 ID 一致的模型，翻页瞬间旧模型不会误操作新页面。
    private var currentModel: ImagePageModel? {
        guard let currentID, activeModel?.entry.id == currentID else { return nil }
        return activeModel
    }

    private var canEditCurrent: Bool {
        guard let currentEntry, !currentEntry.isLivePhoto else { return false }
        return currentModel?.canEditCurrentImage == true
    }

    private var canSaveCurrent: Bool {
        currentModel?.canSaveToPhotos == true
    }

    private func rotateCurrent() {
        guard canEditCurrent, let currentID else { return }
        let next = ((rotations[currentID] ?? 0) + 1) % 4
        rotations[currentID] = next
        Log.debug(.app, "相册旋转 \(Log.shortPath(currentEntry?.path ?? "")) 角度=\(next * 90)")
    }

    private func saveToServer() {
        guard let currentID, let model = currentModel else { return }
        let rotation = rotations[currentID] ?? 0
        guard rotation != 0 else { return }
        isSaving = true
        Task {
            do {
                try await model.saveRotated(quarterTurns: rotation)
                rotations[currentID] = 0
                showSaveNotice("已覆盖原照片")
                isSaving = false
            } catch {
                isSaving = false
                saveError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func saveToPhotos() {
        guard let currentID, let model = currentModel else { return }
        let rotation = rotations[currentID] ?? 0
        isSaving = true
        Task {
            do {
                try await model.saveToPhotoLibrary(quarterTurns: rotation)
                showSaveNotice("已保存到系统相册")
                isSaving = false
            } catch {
                isSaving = false
                saveError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private var currentIndex: Int {
        if let currentID,
           let index = session.entries.firstIndex(where: { $0.id == currentID }) {
            return index
        }
        return session.initialIndex
    }

    private var currentEntry: MediaEntry? {
        guard session.entries.indices.contains(currentIndex) else { return session.entries.first }
        return session.entries[currentIndex]
    }

    private var counterText: String {
        "\(currentIndex + 1) / \(session.entries.count)"
    }

    private var currentTitle: String {
        if let currentEntry {
            return store.displayTitle(for: currentEntry)
        }
        return session.title
    }
}
