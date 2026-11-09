import Foundation
import Security

/// 一台主机的登录凭据。只有这里的 `password` 会进入钥匙串。
public struct HostCredential: Codable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum CredentialStoreError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case encoding
    case decoding

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "钥匙串操作失败（\(status)）"
        case .encoding:
            "凭据编码失败"
        case .decoding:
            "凭据解码失败"
        }
    }
}

/// 凭据存取抽象。单元测试可换成内存实现，业务层不直接依赖 Security。
public protocol CredentialStoring: Sendable {
    func save(_ credential: HostCredential, for address: String) throws
    func credential(for address: String) throws -> HostCredential?
    func deleteCredential(for address: String) throws
}

/// 基于系统钥匙串的实现。
///
/// 以 `kSecClassGenericPassword` 保存一条 JSON：service 固定为应用命名空间，
/// account 使用用户填写的原始主机地址，因此别名、IP 与 `smb://` 形式各自独立。
/// 不记录密码到日志。
public final class KeychainCredentialStore: CredentialStoring {
    public static let defaultService = "com.wangzicheng.icemovie.smb"

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func save(_ credential: HostCredential, for address: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw CredentialStoreError.encoding
        }

        let query = baseQuery(address: address)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            Log.info(.smb, "凭据已覆盖 host=\(address) user=\(credential.username)")
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
        Log.info(.smb, "凭据已保存 host=\(address) user=\(credential.username)")
    }

    public func credential(for address: String) throws -> HostCredential? {
        var query = baseQuery(address: address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw CredentialStoreError.decoding
        }
        do {
            return try JSONDecoder().decode(HostCredential.self, from: data)
        } catch {
            throw CredentialStoreError.decoding
        }
    }

    public func deleteCredential(for address: String) throws {
        let status = SecItemDelete(baseQuery(address: address) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
        Log.info(.smb, "凭据已删除 host=\(address)")
    }

    private func baseQuery(address: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: address,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// 测试与预览用的内存实现。生产路径仍走钥匙串。
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: HostCredential] = [:]

    public init() {}

    public func save(_ credential: HostCredential, for address: String) throws {
        lock.withLock {
            storage[address] = credential
        }
    }

    public func credential(for address: String) throws -> HostCredential? {
        lock.withLock {
            storage[address]
        }
    }

    public func deleteCredential(for address: String) throws {
        lock.withLock {
            storage.removeValue(forKey: address)
        }
    }
}
