import MediaLibraryKit
import SwiftUI

/// 常规宽度下的左栏：主机、共享、目录层级与当前目录的子目录。
struct LibrarySidebar: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("媒体库")
                    .font(.title2.bold())
                Text("\(store.currentEntries.count) 个条目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            List {
                Section("主机") {
                    Label(store.source.hostName, systemImage: "server.rack")
                        .lineLimit(1)
                }

                Section("共享") {
                    let shares = store.availableShares.isEmpty
                        ? [store.source.shareName]
                        : store.availableShares
                    ForEach(shares, id: \.self) { share in
                        Button {
                            Task { await store.switchShare(share) }
                        } label: {
                            HStack(spacing: 8) {
                                Label(share, systemImage: "externaldrive.connected.to.line.below")
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if share == store.source.shareName {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                if store.isSwitchingShare, share != store.source.shareName {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
                            .foregroundStyle(
                                share == store.source.shareName ? Color.accentColor : Color.primary
                            )
                            .fontWeight(share == store.source.shareName ? .semibold : .regular)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isSwitchingShare)
                        .hoverEffect(.highlight)
                    }
                }

                Section("位置") {
                    sidebarRow(
                        title: "共享根",
                        systemImage: "house",
                        path: "",
                        isCurrent: store.currentPath.isEmpty
                    )
                    ForEach(store.displayBreadcrumb, id: \.path) { item in
                        sidebarRow(
                            title: item.name,
                            systemImage: "folder",
                            path: item.path,
                            isCurrent: store.currentPath == item.path
                        )
                    }
                }

                if !store.subdirectories.isEmpty {
                    Section("目录") {
                        ForEach(store.subdirectories) { entry in
                            Button {
                                store.move(to: entry.path)
                            } label: {
                                Label {
                                    Text(store.displayTitle(for: entry))
                                        .lineLimit(2)
                                } icon: {
                                    Image(systemName: "folder")
                                }
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .task {
            await store.refreshShares()
        }
    }

    private func sidebarRow(
        title: String,
        systemImage: String,
        path: String,
        isCurrent: Bool
    ) -> some View {
        Button {
            store.move(to: path)
        } label: {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
            }
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            .fontWeight(isCurrent ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isCurrent
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .hoverEffect(.highlight)
    }
}
