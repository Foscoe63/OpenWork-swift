import Foundation
import Security
import SwiftOpenWorkCore

/// Thread-safe macOS Keychain Manager providing hardware-backed encryption for API keys and sensitive credentials
public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let serviceName = AppIdentity.keychainService
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

        guard !secret.isEmpty else {
            // Clearing a key must also clear the 1.1 copy, or `getSecret` falls back to it.
            var legacyDelete = queryDelete
            legacyDelete[kSecAttrService as String] = AppIdentity.legacyKeychainService
            SecItemDelete(legacyDelete as CFDictionary)
            return true
        }

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
    ///
    /// A miss falls back to the service name 1.1 used (the app was renamed, and its bundle ID with
    /// it). A secret found there is copied to the current service so the fallback runs once per
    /// credential. The old item is left in place: deleting a user's stored secret is not a
    /// migration's call, and leaving it costs nothing.
    public func getSecret(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let secret = read(service: serviceName, key: key) {
            return secret
        }
        guard let legacy = read(service: AppIdentity.legacyKeychainService, key: key) else {
            return nil
        }
        add(legacy, service: serviceName, key: key)
        return legacy
    }

    private func read(service: String, key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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

    private func add(_ secret: String, service: String, key: String) {
        guard let data = secret.data(using: .utf8), !secret.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
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
        // Otherwise the fallback in `getSecret` would bring a deleted credential back from 1.1.
        var legacyQuery = query
        legacyQuery[kSecAttrService as String] = AppIdentity.legacyKeychainService
        SecItemDelete(legacyQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
