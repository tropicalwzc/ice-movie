import MediaLibraryKit
import SwiftUI

/// 文档列表行。文档不参与视频缩略图，也不使用视频标题解析。
struct DocumentRow: View {
    let entry: MediaEntry

    @Environment(LibraryStore.self) private var store

    private var metadata: DocumentMetadata? {
        DocumentMetadata(entry: entry)
    }

    var body: some View {
        NavigationLink {
            DocumentReaderView(entry: entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: metadata?.format == .pdf ? "doc.richtext" : "doc.text")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(metadata?.format == .pdf ? Color.red : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.displayTitle(for: entry))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(store.subtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let metadata {
                    Text(metadata.typeLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(metadata.format == .pdf ? Color.red : Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(
                                    (metadata.format == .pdf ? Color.red : Color.accentColor)
                                        .opacity(0.12)
                                )
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("document.row.\(entry.name)")
        .accessibilityLabel(
            "\(store.displayTitle(for: entry))，\(metadata?.typeLabel ?? "文档") 文档"
        )
        .accessibilityHint("打开文档")
    }
}

/// 纯文档目录中的文件夹行。
struct DocumentDirectoryRow: View {
    let entry: MediaEntry

    @Environment(LibraryStore.self) private var store

    var body: some View {
        Button {
            store.enter(entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    )

                Text(store.displayTitle(for: entry))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("document.folder.\(entry.name)")
        .accessibilityLabel("\(store.displayTitle(for: entry))，文件夹")
        .accessibilityHint("进入文件夹")
    }
}
