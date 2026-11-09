import Foundation

/// 网格列数计算。与 SwiftUI 无关，可直接做单元测试。
public enum LibraryGridLayout {
    /// 单元格最小宽度（design.md D12）。
    public static let minimumCellWidth: CGFloat = 160
    public static let spacing: CGFloat = 14
    public static let horizontalPadding: CGFloat = 16

    /// 按可用宽度计算列数。增加宽度时增加列数，而不是放大部分封面。
    public static func columnCount(
        availableWidth: CGFloat,
        spacing: CGFloat = LibraryGridLayout.spacing,
        horizontalPadding: CGFloat = LibraryGridLayout.horizontalPadding
    ) -> Int {
        let contentWidth = max(0, availableWidth - horizontalPadding * 2)
        guard contentWidth > 0 else { return 1 }
        let raw = (contentWidth + spacing) / (minimumCellWidth + spacing)
        return max(1, Int(raw.rounded(.down)))
    }
}
