import SwiftUI

/// 媒体库内容区顶部的同步状态条。固定不随网格滚动，切换目录时继续可见。
struct PhotoSyncStatusBar: View {
    @Environment(PhotoSyncModel.self) private var photoSync

    private var isFailure: Bool {
        photoSync.phase == .interrupted
            || (photoSync.phase == .summary && photoSync.failureCount > 0)
    }

    private var tint: Color {
        isFailure ? .red : .accentColor
    }

    private var iconName: String {
        switch photoSync.phase {
        case .interrupted: "exclamationmark.triangle.fill"
        case .summary:
            photoSync.summary?.cancelled == true
                ? "xmark.circle.fill"
                : (isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        default: "arrow.up.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                photoSync.showDetails()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(photoSync.titleText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if photoSync.phase == .uploading {
                                Text("\(photoSync.processed)/\(photoSync.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            if photoSync.phase == .summary,
                               photoSync.failureCount > 0 {
                                Text("失败 \(photoSync.failureCount)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                            }

                            Spacer(minLength: 0)

                            if photoSync.phase == .uploading {
                                Text(photoSync.formattedSpeed)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("查看详情")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                            .tint(tint)
                            .accessibilityIdentifier("photoSync.statusBar.progress")
                            .accessibilityValue(
                                Text("\(photoSync.processed)/\(photoSync.total)")
                            )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("photoSync.statusBar")
            .accessibilityLabel(
                Text("照片同步状态，\(photoSync.titleText)，\(photoSync.processed)/\(photoSync.total)")
            )
            .accessibilityValue(Text(photoSync.formattedSpeed))

            if photoSync.phase == .uploading {
                Button {
                    photoSync.cancelSync()
                } label: {
                    if photoSync.isCancelling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .accessibilityIdentifier("photoSync.statusBar.cancel")
                .accessibilityLabel("取消照片同步")
            } else {
                Button {
                    photoSync.dismissStatus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .accessibilityIdentifier("photoSync.statusBar.close")
                .accessibilityLabel("关闭照片同步状态")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            isFailure
                ? Color.red.opacity(0.08)
                : Color(uiColor: .secondarySystemGroupedBackground)
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("照片同步状态")
    }

    private var progressValue: Double {
        switch photoSync.phase {
        case .uploading:
            return photoSync.progressFraction
        case .summary, .interrupted:
            return photoSync.total > 0
                ? min(1, Double(photoSync.processed) / Double(photoSync.total))
                : 1
        default:
            return 0
        }
    }
}
