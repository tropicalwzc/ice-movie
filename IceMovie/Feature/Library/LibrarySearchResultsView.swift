import MediaLibraryKit
import SwiftUI

struct LibrarySearchResultsView: View {
    @Environment(LibraryStore.self) private var store

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
                        Label("没有匹配的媒体", systemImage: "magnifyingglass")
                    } description: {
                        Text("关键字已保留，可以直接修改后重试。")
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.searchHits) { hit in
                        Button {
                            store.reveal(hit)
                        } label: {
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
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                    }
                } header: {
                    Text("\(store.searchHits.count) 个结果")
                }
            }
        }
        .listStyle(.plain)
    }

    private func episodeText(_ episode: Double) -> String {
        episode.rounded() == episode
            ? String(Int(episode))
            : String(format: "%.1f", episode)
    }
}
