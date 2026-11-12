import Foundation

/// 照片同步的文件命名规则。
///
/// 目标目录平铺，文件名固定为 `原名_yyyyMMddHHmmss.ext`；扩展名由导出 UTI
/// 决定，冲突序号放在时间戳之前，保证 `PhotoTimestampParser` 仍能读到末尾时间。
public enum PhotoFileName {
    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif",
    ]

    public static let maxBaseCharacters = 160

    public static func normalizedExtension(_ raw: String) -> String? {
        let ext = raw.lowercased()
        switch ext {
        case "jpg", "jpeg": return "jpg"
        case "png": return "png"
        case "heic": return "heic"
        case "heif": return "heif"
        default: return nil
        }
    }

    public static func extensionForUniformTypeIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        switch identifier {
        case "public.jpeg": return "jpg"
        case "public.png": return "png"
        case "public.heic": return "heic"
        case "public.heif": return "heif"
        default: return nil
        }
    }

    /// 优先使用导出 UTI；UTI 缺失或无法识别时退回原始扩展名。
    public static func resolvedExtension(
        originalFilename: String,
        uniformTypeIdentifier: String?
    ) -> String? {
        if let mapped = extensionForUniformTypeIdentifier(uniformTypeIdentifier) {
            return mapped
        }
        let ext = (originalFilename as NSString).pathExtension
        return normalizedExtension(ext)
    }

    public static func timestampString(
        for date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02d%02d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    public static func baseName(from originalFilename: String) -> String {
        let base = (originalFilename as NSString).deletingPathExtension
        return base.isEmpty ? "Photo" : base
    }

    public static func sanitizedBase(_ raw: String) -> String {
        var value = ""
        for scalar in raw.unicodeScalars {
            let isForbidden = scalar == "/" || scalar == "\\" || scalar == ":"
                || scalar == "*" || scalar == "?" || scalar == "\""
                || scalar == "<" || scalar == ">" || scalar == "|"
                || scalar.value < 0x20 || scalar.value == 0x7F
            value.unicodeScalars.append(isForbidden ? "_" : scalar)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if value.isEmpty {
            value = "Photo"
        }
        if value.count > maxBaseCharacters {
            value = String(value.prefix(maxBaseCharacters))
        }
        return value
    }

    /// 生成最终文件名。UTI 与原始扩展名都不受支持时返回 nil。
    public static func fileName(
        originalFilename: String,
        captureDate: Date,
        uniformTypeIdentifier: String?,
        collisionIndex: Int = 0,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let ext = resolvedExtension(
            originalFilename: originalFilename,
            uniformTypeIdentifier: uniformTypeIdentifier
        ) else {
            return nil
        }
        return fileName(
            originalFilename: originalFilename,
            captureDate: captureDate,
            fileExtension: ext,
            collisionIndex: collisionIndex,
            timeZone: timeZone
        )
    }

    /// 已知扩展名时直接生成文件名，供测试与未来打包策略使用。
    public static func fileName(
        originalFilename: String,
        captureDate: Date,
        fileExtension: String,
        collisionIndex: Int = 0,
        timeZone: TimeZone = .current
    ) -> String {
        let timestamp = timestampString(for: captureDate, timeZone: timeZone)
        var base = sanitizedBase(baseName(from: originalFilename))
        let timestampSuffix = "_\(timestamp)"
        if base.lowercased().hasSuffix(timestampSuffix.lowercased()) {
            base = String(base.dropLast(timestampSuffix.count))
            if base.isEmpty {
                base = "Photo"
            }
        }
        let collision = collisionIndex > 0 ? "_\(collisionIndex + 1)" : ""
        return "\(base)\(collision)\(timestampSuffix).\(fileExtension.lowercased())"
    }
}
