import MediaLibraryKit
import SwiftUI
import UIKit

/// 2:3 海报。封面未就绪时占位尺寸固定，避免网格跳动。
struct LibraryPoster: View {
    let entry: MediaEntry

    @Environment(LibraryStore.self) private var store
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                ZStack {
                    placeholder

                    if entry.isDirectory {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    } else if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: loadFailed ? "film.slash" : "film")
                                .font(.system(size: 26, weight: .light))
                            if loadFailed {
                                Text("无封面")
                                    .font(.caption2)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .clipped()
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
        guard !entry.isDirectory else { return }
        image = await store.thumbnail(for: entry)
        loadFailed = image == nil
    }
}

struct LibraryCell: View {
    let entry: MediaEntry

    @Environment(LibraryStore.self) private var store

    var body: some View {
        Button {
            store.activate(entry)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                LibraryPoster(entry: entry)

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
        .accessibilityLabel(entry.name)
        .accessibilityHint(entry.isDirectory ? "进入文件夹" : "开始播放")
    }
}
