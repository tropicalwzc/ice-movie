import MediaLibraryKit
import SwiftUI

struct LibrarySearchResultsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var openingImageID: String?
    @State private var imageOpenErrorID: String?

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
                            NavigationLink {
                                DocumentReaderView(entry: hit.entry)
                            } label: {
                                documentRow(hit)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .accessibilityIdentifier("search.document.\(hit.entry.name)")
                        } else if hit.entry.isImage {
                            Button {
                                openImage(hit)
                            } label: {
                                imageRow(hit)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .disabled(openingImageID == hit.entry.id)
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
        openingImageID = hit.entry.id
        Task {
            let opened = await store.openImageGallery(for: hit)
            openingImageID = nil
            if !opened {
                imageOpenErrorID = hit.entry.id
            }
        }
    }

    private func imageRow(_ hit: LibrarySearchHit) -> some View {
        HStack(spacing: 12) {
            LibraryPoster(entry: hit.entry)
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
                    Text(
                        hit.entry.directoryPath.isEmpty
                            ? "/"
                            : MediaTitleParser.directoryPathDisplay(hit.entry.directoryPath)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if openingImageID == hit.entry.id {
                ProgressView()
                    .controlSize(.small)
            } else if imageOpenErrorID == hit.entry.id {
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
            LibraryPoster(entry: hit.entry)
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
                    Text(
                        hit.entry.directoryPath.isEmpty
                            ? "/"
                            : MediaTitleParser.directoryPathDisplay(hit.entry.directoryPath)
                    )
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
                    Text(hit.entry.displayDirectoryPath)
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

    private func episodeText(_ episode: Double) -> String {
        episode.rounded() == episode
            ? String(Int(episode))
            : String(format: "%.1f", episode)
    }
}
