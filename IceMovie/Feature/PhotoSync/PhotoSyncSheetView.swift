import MediaLibraryKit
import SwiftUI

struct PhotoSyncSheetView: View {
    @Environment(PhotoSyncModel.self) private var photoSync

    var body: some View {
        NavigationStack {
            Group {
                switch photoSync.phase {
                case .scanning:
                    scanningView
                case .review:
                    reviewView
                case .uploading:
                    progressDetailView
                case .summary, .interrupted:
                    summaryView
                case .upToDate:
                    upToDateView
                case .idle:
                    emptyView
                }
            }
            .navigationTitle("照片同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        photoSync.dismissSheet()
                    }
                    .accessibilityIdentifier("photoSync.sheet.close")
                }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
    }

    private var detents: Set<PresentationDetent> {
        switch photoSync.phase {
        case .review, .summary, .interrupted:
            [.large]
        default:
            [.medium]
        }
    }

    private var scanningView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("正在检查系统相册…")
                .font(.headline)
            Text("只读扫描，不会上传任何文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("取消") {
                photoSync.cancelSync()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("photoSync.scanning.cancel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var reviewView: some View {
        let counts = photoSync.plan?.counts ?? PhotoSyncCounts()
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(
                    title: "同步到 \(photoSync.targetDisplayName)",
                    subtitle: photoSync.target?.displayPath ?? "/"
                )

                if counts.limitedAccess {
                    Label(
                        "系统只授权了部分照片，本次仅同步可访问的照片。",
                        systemImage: "photo.badge.checkmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(spacing: 0) {
                    infoRow(
                        "照片权限",
                        photoSync.authorizationStatus.displayText,
                        identifier: "photoSync.review.authorization"
                    )
                    if let newest = counts.latestCaptureDate,
                       let oldest = counts.oldestCaptureDate {
                        infoRow(
                            "相册照片范围",
                            "\(dateText(oldest)) – \(dateText(newest))",
                            identifier: "photoSync.review.dateRange"
                        )
                    }
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )

                VStack(spacing: 0) {
                    countRow("系统相册可访问", counts.accessible, identifier: "photoSync.review.accessible")
                    countRow("动态照片", counts.livePhotos, note: "本期只同步静态图", identifier: "photoSync.review.live")
                    if counts.videos > 0 {
                        countRow("视频", counts.videos, note: "跳过", identifier: "photoSync.review.video")
                    }
                    countRow("格式不支持", counts.unsupported, note: "跳过", identifier: "photoSync.review.unsupported")
                    countRow("缺少拍摄时间", counts.missingDate, note: "跳过", identifier: "photoSync.review.missingDate")
                    if counts.missingMetadata > 0 {
                        countRow("缺少文件信息", counts.missingMetadata, note: "跳过", identifier: "photoSync.review.missingMetadata")
                    }
                    Divider().padding(.leading, 12)
                    countRow("目标已有图片", counts.remoteImages, identifier: "photoSync.review.remoteImages")
                    countRow("已匹配，将跳过", counts.matched, identifier: "photoSync.review.matched")
                    countRow(
                        "待同步",
                        counts.pending,
                        emphasized: true,
                        identifier: "photoSync.review.pending"
                    )
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )

                Text("确认后才会上传。文件名使用原名加拍摄时间，已有文件不会被覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("取消") {
                        photoSync.cancelSync()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photoSync.review.cancel")

                    Button("开始同步") {
                        photoSync.startUpload()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(counts.pending == 0)
                    .accessibilityIdentifier("photoSync.review.start")
                }
            }
            .padding(20)
        }
    }

    private var progressDetailView: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(
                title: "同步到 \(photoSync.targetDisplayName)",
                subtitle: "\(photoSync.processed)/\(photoSync.total) 张"
            )

            ProgressView(value: photoSync.progressFraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .accessibilityIdentifier("photoSync.progress.bar")

            if let current = photoSync.currentFileName {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在处理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(current)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack {
                Label(photoSync.formattedSpeed, systemImage: "arrow.up.circle")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已上传 \(photoSync.formattedUploadedBytes)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if photoSync.failureCount > 0 {
                Label("失败 \(photoSync.failureCount) 张", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            Button(photoSync.isCancelling ? "正在取消…" : "取消同步") {
                photoSync.cancelSync()
            }
            .buttonStyle(.bordered)
            .disabled(photoSync.isCancelling)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("photoSync.progress.cancel")
        }
        .padding(20)
    }

    private var summaryView: some View {
        let summary = photoSync.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(
                        systemName: summary?.interrupted == true
                            ? "exclamationmark.triangle.fill"
                            : (summary?.failureCount ?? 0) > 0
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                    )
                    .font(.system(size: 30))
                    .foregroundStyle(
                        summary?.interrupted == true || (summary?.failureCount ?? 0) > 0
                            ? .red
                            : .green
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(photoSync.titleText)
                            .font(.headline)
                        if let message = summary?.errorMessage, !message.isEmpty {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(spacing: 0) {
                    summaryRow("成功", summary?.successCount ?? 0)
                    summaryRow("失败", summary?.failureCount ?? 0)
                    summaryRow("跳过", summary?.skippedCount ?? 0)
                    summaryRow("已处理", "\(summary?.processedCount ?? 0)/\(summary?.totalCount ?? 0)")
                    summaryRow("用时", photoSync.formattedElapsed)
                    summaryRow("平均速度", photoSync.formattedAverageSpeed)
                    summaryRow("已上传", photoSync.formattedUploadedBytes)
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )

                if let summary, !summary.failures.isEmpty {
                    DisclosureGroup(
                        "失败原因（\(summary.failures.count)）",
                        isExpanded: .constant(true)
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(summary.failures.prefix(20))) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.fileName)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(failure.reason)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if summary.failures.count > 20 {
                                Text("还有 \(summary.failures.count - 20) 条失败记录")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.footnote)
                }

                HStack(spacing: 12) {
                    Button("完成") {
                        photoSync.dismissSheet()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photoSync.summary.done")

                    if (summary?.failureCount ?? 0) > 0
                        || summary?.cancelled == true
                        || summary?.interrupted == true {
                        Button("重试失败") {
                            photoSync.retryFailed()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("photoSync.summary.retry")
                    }
                }
            }
            .padding(20)
        }
    }

    private var upToDateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("已是最新")
                .font(.headline)
            if let counts = photoSync.plan?.counts {
                Text("目标已有 \(counts.remoteImages) 张图片，没有需要同步的新照片。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("完成") {
                photoSync.dismissSheet()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("photoSync.upToDate.done")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("准备中…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func infoRow(
        _ title: String,
        _ value: String,
        identifier: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day())
    }

    private func countRow(
        _ title: String,
        _ value: Int,
        note: String? = nil,
        emphasized: Bool = false,
        identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .accessibilityIdentifier(identifier)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(value)")
                .font((emphasized ? Font.subheadline.weight(.bold) : Font.subheadline).monospacedDigit())
                .foregroundStyle(emphasized ? Color.accentColor : .primary)
                .accessibilityIdentifier("\(identifier).value")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func summaryRow(_ title: String, _ value: Int) -> some View {
        summaryRow(title, "\(value)")
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
