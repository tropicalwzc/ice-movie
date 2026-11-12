import MediaLibraryKit
import SwiftUI
import UIKit

/// 全量缩略图预热进度条；只在有任务且尚未结束时出现。
struct ThumbnailPrewarmBanner: View {
    @Bindable var controller: ThumbnailPrewarmController
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if controller.isActive {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)

                    Text(
                        controller.isPaused
                            ? "缩略图预热已暂停"
                            : "正在生成缩略图 \(controller.completed)/\(controller.total)"
                    )
                    .font(.caption.weight(.medium))

                    Spacer(minLength: 0)

                    if controller.isPaused {
                        Button("继续") {
                            store.resumeThumbnailPrewarm()
                        }
                        .accessibilityIdentifier("prewarm.resume")
                    } else {
                        Button("暂停") {
                            store.pauseThumbnailPrewarm()
                        }
                        .accessibilityIdentifier("prewarm.pause")
                    }

                    Button("取消", role: .destructive) {
                        store.cancelThumbnailPrewarm()
                    }
                    .accessibilityIdentifier("prewarm.cancel")
                }

                ProgressView(value: controller.progress)
                    .tint(Color.accentColor)
                    .accessibilityIdentifier("prewarm.progress")
            }
            .font(.caption2)
            .padding(.horizontal, LibraryGridLayout.horizontalPadding)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(alignment: .bottom) {
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("prewarm.banner")
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
