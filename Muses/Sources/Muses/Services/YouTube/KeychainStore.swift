import Foundation
import Security

/// macOS Keychain 读写抽象,便于测试注入(真实实现用 Security framework)。
protocol KeychainStoring: Sendable {
    /// 读取 `account` 对应的 Data;不存在或失败返回 nil。
    func data(for account: String) -> Data?
    /// 写入(覆盖)Data;成功返回 true。
    func set(_ data: Data, for account: String) -> Bool
    /// 删除;不存在也返回 true。
    func delete(_ account: String) -> Bool
}

/// 真实 Keychain 实现:以固定 `service` 存取多个 `account`。
///
/// 用于 YouTube OAuth(存 access/refresh token 与 client config)。
/// 不用 UserDefaults / SwiftData / 明文文件(spec §4:凭证存 Keychain)。
struct KeychainStore: KeychainStoring {
    let service: String

    init(service: String = "muses.youtube.oauth") {
        self.service = service
    }

    func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    func set(_ data: Data, for account: String) -> Bool {
        // 先尝试更新,失败则新增(避免重复项)。
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// 内存 Keychain(测试用)。
final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()

    func data(for account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[account]
    }
    func set(_ data: Data, for account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store[account] = data
        return true
    }
    func delete(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store[account] = nil
        return true
    }
}