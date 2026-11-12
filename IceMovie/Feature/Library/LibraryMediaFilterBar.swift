import MediaLibraryKit
import SwiftUI
import UIKit

/// 搜索栏下方的媒体类型过滤条。只在同时含视频与图片的目录出现。
struct LibraryMediaFilterBar: View {
    @Bindable var store: LibraryStore
    @Environment(PhotoSyncModel.self) private var photoSync
    @State private var showCalendar = false

    var body: some View {
        HStack(spacing: 8) {
            if store.mediaFilterIsApplicable {
                chip(
                    title: "视频",
                    systemImage: "film",
                    selected: store.showsVideos,
                    identifier: "filter.video"
                ) {
                    store.showsVideos.toggle()
                }

                chip(
                    title: "图片",
                    systemImage: "photo",
                    selected: store.showsImages,
                    identifier: "filter.image"
                ) {
                    store.showsImages.toggle()
                }
            } else if store.hasPhotoCalendar {
                Label("按拍摄日期", systemImage: "calendar")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if store.isCurrentDirectoryPhotoLibraryTarget {
                Label("照片库路径", systemImage: "photo.stack")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if store.hasPhotoCalendar {
                if let jump = store.photoCalendarJump {
                    dateJumpChip(jump)
                }
                calendarButton
            }
            if store.isCurrentDirectoryPhotoLibraryTarget {
                syncButton
            }
        }
        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("媒体类型过滤")
    }

    private var syncButton: some View {
        Button {
            if photoSync.phase == .uploading {
                photoSync.showDetails()
            } else {
                photoSync.beginSync()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        photoSync.failureCount > 0
                            ? Color.red.opacity(0.12)
                            : Color.accentColor.opacity(0.12)
                    )
                if photoSync.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            photoSync.failureCount > 0 ? Color.red : Color.accentColor
                        )
                }
                if photoSync.failureCount > 0, !photoSync.isBusy {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 11, y: -10)
                }
            }
            .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("同步系统相册到照片库路径")
        .accessibilityValue(
            photoSync.isBusy
                ? Text("正在同步 \(photoSync.processed)/\(photoSync.total)")
                : Text("")
        )
        .accessibilityIdentifier("photoSync.button")
    }

    private func dateJumpChip(_ jump: LibraryStore.PhotoCalendarJump) -> some View {
        Button {
            store.clearPhotoCalendarJump()
        } label: {
            HStack(spacing: 4) {
                Text(jump.compactTitle)
                    .font(.caption.weight(.semibold))
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.clearCalendarJump")
        .accessibilityLabel(
            Text("清除日期筛选，显示全部照片，当前 \(jump.title)")
        )
    }

    private var calendarButton: some View {
        Button {
            showCalendar = true
        } label: {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("照片日历")
        .accessibilityIdentifier("filter.calendar")
        .popover(isPresented: $showCalendar, arrowEdge: .top) {
            PhotoCalendarMenu(
                calendarIndex: store.photoCalendar,
                onSelect: { day in
                    store.requestPhotoJump(to: day)
                    showCalendar = false
                },
                onSelectMonth: { year, month in
                    store.requestPhotoJump(toYear: year, month: month)
                    showCalendar = false
                },
                onShowAll: {
                    store.clearPhotoCalendarJump()
                    showCalendar = false
                }
            )
        }
    }

    private func chip(
        title: String,
        systemImage: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.18)) {
                action()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold))
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? Color.accentColor.opacity(0.14)
                            : Color(uiColor: .tertiarySystemFill)
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.35) : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选中" : "未选中")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
