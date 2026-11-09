import Foundation

public enum SMBAddressError: LocalizedError, Equatable, Sendable {
    case empty
    case invalid(String)
    case invalidPort(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "地址不能为空"
        case .invalid(let value):
            "地址格式无效：\(value)"
        case .invalidPort(let value):
            "端口无效：\(value)"
        }
    }
}

/// 归一化后的 SMB 主机地址。
///
/// `raw` 保留用户填写的原始形式（仅去掉首尾空白），作为连接记录与钥匙串的身份；
/// `host` / `port` / `share` / `path` 只用于建立会话与导航，不写回记录。
public struct SMBHostAddress: Equatable, Sendable {
    public let raw: String
    public let host: String
    public let port: Int?
    public let share: String?
    public let path: String

    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SMBAddressError.empty }

        var working = trimmed
        if working.lowercased().hasPrefix("smb://") {
            working = String(working.dropFirst("smb://".count))
        }
        guard !working.isEmpty else { throw SMBAddressError.invalid(input) }

        let parts = working.split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        var authority = String(parts.first ?? "")
        let share: String?
        if parts.count > 1, !parts[1].isEmpty {
            share = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        } else {
            share = nil
        }
        let path: String
        if parts.count > 2 {
            let joined = parts[2...].joined(separator: "/")
            path = joined.removingPercentEncoding ?? joined
        } else {
            path = ""
        }

        // 去掉可能出现的 user@host 前缀；凭据单独传递，不参与地址身份。
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        guard !authority.isEmpty else { throw SMBAddressError.invalid(input) }

        var host = authority
        var port: Int?

        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                throw SMBAddressError.invalid(input)
            }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let remainder = authority[authority.index(after: close)...]
            if remainder.hasPrefix(":") {
                let text = String(remainder.dropFirst())
                guard let value = Int(text), (1...65535).contains(value) else {
                    throw SMBAddressError.invalidPort(text)
                }
                port = value
            }
        } else {
            let colonCount = authority.filter { $0 == ":" }.count
            if colonCount == 1, let colon = authority.lastIndex(of: ":") {
                let text = String(authority[authority.index(after: colon)...])
                if let value = Int(text) {
                    guard (1...65535).contains(value) else {
                        throw SMBAddressError.invalidPort(text)
                    }
                    host = String(authority[..<colon])
                    port = value
                }
            }
            // 多个冒号按裸 IPv6 处理，不加端口。
        }

        host = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .lowercased()
        guard !host.isEmpty else { throw SMBAddressError.invalid(input) }

        self.raw = trimmed
        self.host = host
        self.port = port
        self.share = share
        self.path = path
    }

    /// 传给 `SMB2Manager` 的 URL。只含主机与端口，不把共享/路径塞进去。
    public var url: URL? {
        var text = "smb://"
        if host.contains(":") {
            text += "[\(host)]"
        } else {
            text += host
        }
        if let port {
            text += ":\(port)"
        }
        return URL(string: text)
    }

    public var endpointDescription: String {
        if let port {
            "\(host):\(port)"
        } else {
            host
        }
    }
}

/// 名称解析。解析失败与连接失败必须给出不同错误，便于用户判断是改地址还是查网络。
public enum SMBHostResolver {
    public static func resolve(_ address: SMBHostAddress) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(address.host, nil, &hints, &result)
        defer {
            if let result {
                freeaddrinfo(result)
            }
        }

        guard status == 0 else {
            if status == EAI_NONAME || status == EAI_AGAIN {
                throw SMBConnectionError.nameNotResolved(address.raw)
            }
            let detail = String(cString: gai_strerror(status))
            throw SMBConnectionError.failed("名称解析失败：\(detail)")
        }

        var addresses: [String] = []
        var cursor = result
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let code = getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if code == 0 {
                let value = String(cString: buffer)
                if !value.isEmpty, !addresses.contains(value) {
                    addresses.append(value)
                }
            }
        }

        guard !addresses.isEmpty else {
            throw SMBConnectionError.nameNotResolved(address.raw)
        }
        return addresses
    }

    /// 在后台线程执行阻塞的 `getaddrinfo`，避免占用 Swift 并发线程。
    public static func resolveAsync(_ address: SMBHostAddress) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            try resolve(address)
        }.value
    }
}
