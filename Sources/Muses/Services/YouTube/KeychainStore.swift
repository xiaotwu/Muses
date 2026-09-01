import Foundation
import Security

/// Abstraction over macOS Keychain reads/writes so tests can inject fakes (the real implementation uses the Security framework).
protocol KeychainStoring: Sendable {
    /// Reads the Data stored under `account`; returns nil when missing or on failure.
    func data(for account: String) -> Data?
    /// Writes (overwriting) the Data; returns true on success.
    func set(_ data: Data, for account: String) -> Bool
    /// Deletes the entry; also returns true when nothing exists.
    func delete(_ account: String) -> Bool
}

/// Real Keychain implementation: stores multiple `account`s under one fixed `service`.
///
/// Used for YouTube OAuth (stores access/refresh tokens and the client configuration).
/// Never stored in UserDefaults, SwiftData, or plaintext files — credentials belong in the Keychain.
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
        // Try an update first, then add (avoids duplicate items).
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

/// In-memory Keychain (for tests).
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