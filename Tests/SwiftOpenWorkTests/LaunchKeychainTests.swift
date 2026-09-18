import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

/// Launch must not read the Keychain: a read can block behind an authorisation prompt on the main
/// thread before the window exists, and the app hung with no window.
final class LaunchKeychainTests: XCTestCase {

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String] = []
        func add(_ key: String) { lock.lock(); keys.append(key); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return keys }
    }

    override func tearDown() {
        ProviderCredentials.reader = { KeychainManager.shared.getSecret(forKey: $0) }
        ProviderCredentials.resetCache()
    }

    private func cloud(_ id: String, key: String = "") -> ModelProvider {
        ModelProvider(id: id, name: id, type: .cloud, kind: .openai, baseUrl: "https://example.invalid/v1", apiKey: key, isEnabled: true, models: [])
    }

    func testLoadingProvidersReadsNoKeychainItems() throws {
        let source = try String(contentsOf: SourceTree.url("Sources/Storage/PersistenceManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func loadProviders()"))
        let end = try XCTUnwrap(source.range(of: "public func saveProviders(", range: start.upperBound..<source.endIndex))
        XCTAssertFalse(source[start.lowerBound..<end.lowerBound].contains("getSecret"),
                       "loadProviders runs on the main thread at launch and must not touch the Keychain")
    }

    func testAKeyIsReadOnFirstUseOnlyAndCached() async {
        let reads = Reads()
        ProviderCredentials.resetCache()
        ProviderCredentials.reader = { key in reads.add(key); return "sk-test" }

        let first = await ProviderCredentials.hydrated(cloud("openai"))
        let second = await ProviderCredentials.hydrated(cloud("openai"))
        XCTAssertEqual(first.apiKey, "sk-test")
        XCTAssertEqual(second.apiKey, "sk-test")
        XCTAssertEqual(reads.all, ["provider_key_openai"], "one Keychain read, then the cache")
    }

    /// A denied prompt must not be raised again on every request.
    func testAMissIsCachedToo() async {
        let reads = Reads()
        ProviderCredentials.resetCache()
        ProviderCredentials.reader = { key in reads.add(key); return nil }
        _ = await ProviderCredentials.hydrated(cloud("groq"))
        let again = await ProviderCredentials.hydrated(cloud("groq"))
        XCTAssertEqual(again.apiKey, "")
        XCTAssertEqual(reads.all.count, 1)
    }

    func testLocalProvidersAndLoadedKeysAreNeverRead() async {
        let reads = Reads()
        ProviderCredentials.resetCache()
        ProviderCredentials.reader = { key in reads.add(key); return "x" }
        let local = ModelProvider(id: "omlx-local", name: "Local", type: .local, kind: .omlx, baseUrl: "", apiKey: "", isEnabled: true, models: [])
        _ = await ProviderCredentials.hydrated(local)
        _ = await ProviderCredentials.hydrated(cloud("anthropic", key: "already-here"))
        XCTAssertTrue(reads.all.isEmpty)
    }

    func testASavedKeyIsRememberedWithoutReadingItBack() async {
        let reads = Reads()
        ProviderCredentials.resetCache()
        ProviderCredentials.reader = { key in reads.add(key); return "stale" }
        ProviderCredentials.remember("sk-new", for: "openrouter")
        let filled = await ProviderCredentials.hydrated(cloud("openrouter"))
        XCTAssertEqual(filled.apiKey, "sk-new")
        XCTAssertTrue(reads.all.isEmpty)
    }
}
