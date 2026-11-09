import Foundation

/// 目录导航状态。紧凑单栈与常规分栏两种外壳都只是它的投影，
/// 因此切换外壳不会丢失当前目录或滚动位置。
public struct LibraryNavigationState: Equatable, Sendable {
    public private(set) var host: String
    public private(set) var share: String
    /// 从共享根开始的目录名栈，空数组表示共享根。
    public private(set) var stack: [String]
    /// 每个目录最近一次停留的顶部条目 ID，用于返回或切换外壳后恢复滚动位置。
    private var scrollAnchors: [String: String]

    public init(host: String, share: String, stack: [String] = []) {
        self.host = host
        self.share = share
        self.stack = stack
        self.scrollAnchors = [:]
    }

    public var currentPath: String {
        stack.joined(separator: "/")
    }

    public var canGoBack: Bool { !stack.isEmpty }

    public var parentPath: String? {
        guard !stack.isEmpty else { return nil }
        return stack.dropLast().joined(separator: "/")
    }

    /// 共享根到当前位置的逐级路径，供分栏外壳渲染层级。
    public var breadcrumb: [(name: String, path: String)] {
        var items: [(String, String)] = []
        var current: [String] = []
        for component in stack {
            current.append(component)
            items.append((component, current.joined(separator: "/")))
        }
        return items
    }

    public mutating func enter(_ directoryName: String) {
        let name = directoryName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return }
        stack.append(name)
    }

    /// 直接跳到某个目录。用于分栏左栏、面包屑与检索结果的“进入所在位置”。
    public mutating func move(to path: String) {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        stack = components
    }

    /// 切换到同一主机下的另一个共享，目录栈与滚动锚点一并重置。
    public mutating func changeShare(_ share: String) {
        self.share = share
        stack = []
        scrollAnchors.removeAll()
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard !stack.isEmpty else { return false }
        stack.removeLast()
        return true
    }

    public mutating func setScrollAnchor(_ entryID: String?, for path: String) {        if let entryID {
            scrollAnchors[path] = entryID
        } else {
            scrollAnchors.removeValue(forKey: path)
        }
    }

    public func scrollAnchor(for path: String) -> String? {
        scrollAnchors[path]
    }

    public mutating func resetScrollAnchors() {
        scrollAnchors.removeAll()
    }
}

/// 外壳类型。只影响视图结构，不写入目录导航状态。
public enum LibraryShell: String, Sendable {
    case compact
    case split
}

/// 外壳与导航的组合。切换外壳时只改 `shell`，导航状态原样保留。
public struct LibraryPresentation: Equatable, Sendable {
    public var shell: LibraryShell
    public var navigation: LibraryNavigationState

    public init(shell: LibraryShell, navigation: LibraryNavigationState) {
        self.shell = shell
        self.navigation = navigation
    }

    public mutating func switchShell(to shell: LibraryShell) {
        self.shell = shell
    }
}

/// 分栏断点。按实际可用宽度判断，而不是设备型号。
public enum LibraryBreakpoint {
    /// 小于该宽度用单栈，大于等于时用分栏。留出足够宽度让右栏至少排出 3 列。
    public static let regularWidth: CGFloat = 700
}
