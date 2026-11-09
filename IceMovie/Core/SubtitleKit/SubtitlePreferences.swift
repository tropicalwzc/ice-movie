import Foundation

/// 字幕偏好。放在 SubtitleKit 里，便于单元测试；实际存储用 UserDefaults。
public enum SubtitlePreferences {
    public static let defaultFontSize: Double = 22
    public static let defaultBottomPadding: Double = 130
    public static let defaultOffset: Double = 0

    /// 测试可替换成独立 suite，避免污染真实偏好。UserDefaults 本身线程安全。
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    private enum Key {
        static let enabled = "subtitle.enabled"
        static let language = "subtitle.lastLanguage"
        static let fontSize = "subtitle.fontSize"
        static let bottomPadding = "subtitle.bottomPadding"
        static let offset = "subtitle.offset"
    }

    public static var enabled: Bool {
        get {
            if defaults.object(forKey: Key.enabled) == nil { return true }
            return defaults.bool(forKey: Key.enabled)
        }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    public static var lastLanguage: SubtitleLanguage? {
        get {
            guard let raw = defaults.string(forKey: Key.language) else { return nil }
            return SubtitleLanguage(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.language)
            } else {
                defaults.removeObject(forKey: Key.language)
            }
        }
    }

    public static var fontSize: Double {
        get { clamp(defaults.object(forKey: Key.fontSize) as? Double ?? defaultFontSize, 14, 36) }
        set { defaults.set(clamp(newValue, 14, 36), forKey: Key.fontSize) }
    }

    public static var bottomPadding: Double {
        get { clamp(defaults.object(forKey: Key.bottomPadding) as? Double ?? defaultBottomPadding, 60, 260) }
        set { defaults.set(clamp(newValue, 60, 260), forKey: Key.bottomPadding) }
    }

    public static var offset: Double {
        get { clamp(defaults.object(forKey: Key.offset) as? Double ?? defaultOffset, -10, 10) }
        set { defaults.set(clamp(newValue, -10, 10), forKey: Key.offset) }
    }

    public static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    public static func reset() {
        for key in [Key.enabled, Key.language, Key.fontSize, Key.bottomPadding, Key.offset] {
            defaults.removeObject(forKey: key)
        }
    }
}
