import Foundation
import Security

/// Thread-safe macOS Keychain Manager providing hardware-backed encryption for API keys and sensitive credentials
public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let serviceName = "ai.openwork.OpenWorkSwift"
    private let lock = NSLock()

    private init() {}

    /// Save or update a sensitive credential in the macOS Keychain
    @discardableResult
    public func saveSecret(_ secret: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let data = secret.data(using: .utf8) else { return false }

        // First delete any existing item
        let queryDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(queryDelete as CFDictionary)

        guard !secret.isEmpty else { return true }

        let queryAdd: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(queryAdd as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a secret from the macOS Keychain
    public func getSecret(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete a secret from Keychain
    @discardableResult
    public func deleteSecret(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
