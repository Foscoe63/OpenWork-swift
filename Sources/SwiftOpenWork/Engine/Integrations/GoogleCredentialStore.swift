import Foundation

/// Google secrets, cached in memory and read from or written to the Keychain off the main thread.
///
/// The settings page used to read all five secrets synchronously in `onAppear`, on the main thread,
/// and every read of `isSignedIn` read two more. A Keychain read can block on securityd and, after
/// any change to the app's code signature, wait on an authorisation prompt — the same hang that
/// `ProviderCredentials` removed from launch. Its `onChange` handlers then wrote each value straight
/// back, so merely opening the page rewrote five Keychain items, and typing rewrote one per keystroke
/// on the main thread.
///
/// Now `load` reads everything once in the background, values are served from memory afterwards,
/// and a write updates memory at once and reaches the Keychain on a serial queue, in order.
/// A value equal to what is already stored is not written at all.
public final class GoogleCredentialStore: @unchecked Sendable {

    public struct Snapshot: Equatable, Sendable {
        public var clientId: String
        public var clientSecret: String
        public var apiKey: String
        public var accessToken: String
        public var refreshToken: String
    }

    private let read: @Sendable (String) -> String?
    private let write: @Sendable (String, String) -> Void
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private let writes = DispatchQueue(label: "SwiftOpenWork.GoogleCredentialStore.writes", qos: .userInitiated)

    public init(
        read: @escaping @Sendable (String) -> String? = { KeychainManager.shared.getSecret(forKey: $0) },
        write: @escaping @Sendable (String, String) -> Void = { value, key in KeychainManager.shared.saveSecret(value, forKey: key) }
    ) {
        self.read = read
        self.write = write
    }

    /// Read any of `keys` not yet cached, off the calling thread. Misses are cached as empty, so a
    /// denied prompt is not raised again on every read.
    public func load(keys: [String]) async {
        let missing = lock.withLock { keys.filter { cache[$0] == nil } }
        guard !missing.isEmpty else { return }
        let read = self.read
        // Let queued writes land first, so a load never returns a value older than one just set.
        let values: [String: String] = await withCheckedContinuation { continuation in
            writes.async {
                var found: [String: String] = [:]
                for key in missing { found[key] = read(key) ?? "" }
                continuation.resume(returning: found)
            }
        }
        lock.withLock {
            // A value set while the read was running wins over what the read found.
            for (key, value) in values where cache[key] == nil { cache[key] = value }
        }
    }

    /// The cached value; reads the Keychain synchronously only if `load` has not run for `key`.
    public func value(for key: String) -> String {
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let value = read(key) ?? ""
        return lock.withLock {
            if let raced = cache[key] { return raced }
            cache[key] = value
            return value
        }
    }

    public func set(_ value: String, for key: String) {
        let changed: Bool = lock.withLock {
            guard cache[key] != value else { return false }
            cache[key] = value
            return true
        }
        guard changed else { return }
        let write = self.write
        writes.async { write(value, key) }
    }

    /// Wait for queued Keychain writes. For tests.
    func waitForWrites() {
        writes.sync {}
    }
}
