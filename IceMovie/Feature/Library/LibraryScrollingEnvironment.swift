import SwiftUI

/// 由媒体库网格下发，供单元格在快速滑动时暂缓改变行高。
struct LibraryScrollingEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var libraryIsScrolling: Bool {
        get { self[LibraryScrollingEnvironmentKey.self] }
        set { self[LibraryScrollingEnvironmentKey.self] = newValue }
    }
}
