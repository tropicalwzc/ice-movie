import MediaLibraryKit
import SwiftUI

struct LibrarySearchResultsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var openingImageID: String?
    @State private var imageOpenErrorID: String?
    @State private var openingDocumentID: String?
    @State private var documentOpenErrorID: String?

    var body: some View {
        List {
            if let note = store.searchScopeNote {                Section {
                    Label {
                        Text(note)
                    } icon: {
                        if store.isIndexing {
                            ProgressView()
                        } else {
                            Image(systemName: "info.circle")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if store.searchHits.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("没有匹配的内容", systemImage: "magnifyingglass")
                    } description: {
                        Text("关键字已保留，可以直接修改后重试。")
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.searchHits) { hit in
                        if hit.entry.isDocument {
                            Button {
                                openDocument(hit)
                            } label: {
                                documentRow(hit)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .disabled(openingDocumentID == hit.id)
                            .accessibilityIdentifier("search.document.\(hit.entry.name)")
                        } else if hit.entry.isImage {
                            Button {
                                openImage(hit)
                            } label: {
                                imageRow(hit)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .disabled(openingImageID == hit.id)
                            .accessibilityIdentifier("search.image.\(hit.entry.name)")
                        } else {
                            Button {
                                store.reveal(hit)
                            } label: {
                                videoRow(hit)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .accessibilityIdentifier("search.video.\(hit.entry.name)")
                        }
                    }
                } header: {
                    Text("\(store.searchHits.count) 个结果")
                }
            }
        }
        .listStyle(.plain)
    }

    private func openImage(_ hit: LibrarySearchHit) {
        imageOpenErrorID = nil
        openingImageID = hit.id
        Task {
            let opened = await store.openImageGallery(for: hit)
            openingImageID = nil
            if !opened {
                imageOpenErrorID = hit.id
            }
        }
    }

    private func openDocument(_ hit: LibrarySearchHit) {
        documentOpenErrorID = nil
        openingDocumentID = hit.id
        Task {
            let opened = await store.openDocumentFromSearch(hit)
            openingDocumentID = nil
            if !opened {
                documentOpenErrorID = hit.id
            }
        }
    }

    private func imageRow(_ hit: LibrarySearchHit) -> some View {
        HStack(spacing: 12) {
            poster(for: hit)
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayTitle(for: hit.entry))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("图片")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text(locationText(for: hit))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if openingImageID == hit.id {
                ProgressView()
                    .controlSize(.small)
            } else if imageOpenErrorID == hit.id {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func videoRow(_ hit: LibrarySearchHit) -> some View {
        HStack(spacing: 12) {
            poster(for: hit)
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayTitle(for: hit.entry))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if let episode = MediaTitleParser.parse(hit.entry.name).episode {
                        Text("第 \(episodeText(episode)) 集")
                    }
                    Text(locationText(for: hit))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// 其他共享的封面需要独立命名空间；索引阶段不额外打开缩略图会话，
    /// 先用类型图标占位，点入后再切换共享查看实际内容。
    @ViewBuilder
    private func poster(for hit: LibrarySearchHit) -> some View {
        if hit.share.isEmpty || hit.share == store.source.shareName {
            LibraryPoster(entry: hit.entry)
        } else {
            Image(systemName: hit.entry.isImage ? "photo" : "film")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 63)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                )
                .accessibilityLabel(hit.entry.isImage ? "图片" : "视频")
        }
    }

    private func documentRow(_ hit: LibrarySearchHit) -> some View {
        let metadata = DocumentMetadata(entry: hit.entry)
        return HStack(spacing: 12) {
            Image(systemName: metadata?.format == .pdf ? "doc.richtext" : "doc.text")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(metadata?.format == .pdf ? Color.red : Color.accentColor)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayTitle(for: hit.entry))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if let metadata {
                        Text(metadata.typeLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(
                                metadata.format == .pdf ? Color.red : Color.accentColor
                            )
                    }
                    Text(locationText(for: hit))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if openingDocumentID == hit.id {
                ProgressView()
                    .controlSize(.small)
            } else if documentOpenErrorID == hit.id {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    /// 跨共享命中时把共享名放在路径前，避免相同相对路径无法区分。
    private func locationText(for hit: LibrarySearchHit) -> String {
        let path = hit.displayPath == "/"
            ? "/"
            : MediaTitleParser.directoryPathDisplay(hit.displayPath)
        guard !hit.share.isEmpty, hit.share != store.source.shareName else {
            return path
        }
        return path == "/" ? hit.share : "\(hit.share) / \(path)"
    }

    private func episodeText(_ episode: Double) -> String {
        episode.rounded() == episode
            ? String(Int(episode))
            : String(format: "%.1f", episode)
    }
}
