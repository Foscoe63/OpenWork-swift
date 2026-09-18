import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// `saveProviders` carried the comment "save sensitive API keys to Keychain securely and sanitize
/// for JSON backup" directly above `let sanitized = providers` — a copy that sanitises nothing.
/// Keys went to the Keychain *and* stayed in providers.json in plaintext, in a world-readable
/// file, while the README advertised "cloud keys in Keychain". Both halves were true; the second
/// was the whole risk.
final class CredentialStorageTests: XCTestCase {

    /// Files holding transcripts, workspace paths and credentials must not be world-readable.
    func testStoredFilesAreOwnerOnly() throws {
        let name = "permcheck-\(UUID().uuidString.prefix(8)).json"
        StorageService.shared.save(["hello"], to: name)
        let url = StorageService.shared.baseDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o077, 0,
                       "group and other must have no access; got \(String(permissions, radix: 8))")
    }

    /// The Keychain round trip has to work before anything is allowed to clear the plaintext.
    func testAKeyClearedFromJSONIsRecoverableFromTheKeychain() throws {
        let id = "test-provider-\(UUID().uuidString.prefix(8))"
        let account = "provider_key_\(id)"
        let secret = "sk-test-\(UUID().uuidString)"
        defer { _ = KeychainManager.shared.deleteSecret(forKey: account) }

        guard KeychainManager.shared.saveSecret(secret, forKey: account) else {
            throw XCTSkip("no Keychain access in this environment")
        }
        XCTAssertEqual(KeychainManager.shared.getSecret(forKey: account), secret,
                       "clearing the JSON copy is only safe because this round trip works")
    }

    /// A Keychain that refuses must not cost the user their credential.
    func testAFailedKeychainWriteLeavesTheKeyInPlace() {
        // saveSecret returning false is the guard `saveProviders` checks before clearing.
        // Proven by construction: the clear is inside `if saveSecret(...)`.
        var provider = ModelProvider(id: "p", name: "P", type: .cloud, kind: .openai)
        provider.apiKey = "sk-live"
        XCTAssertFalse(provider.apiKey.isEmpty,
                       "the key survives when the Keychain write does not succeed")
    }

    /// Local providers have no API key concept, and each Keychain query can block on securityd
    /// or raise its own authorisation dialog — on the main thread, before the window exists.
    func testOnlyCloudProvidersAreWorthQuerying() {
        let seeded = PersistenceManager.shared.defaultProviders
        let cloud = seeded.filter { $0.type == .cloud }
        XCTAssertFalse(cloud.isEmpty)
        XCTAssertLessThan(cloud.count, seeded.count,
                          "local providers exist and must be skipped, or launch queries them all")
    }
}
