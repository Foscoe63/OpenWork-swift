import Foundation

public final class StorageService: @unchecked Sendable {
    public static let shared = StorageService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public var baseDirectory: URL {
        let directory = Self.resolveBaseDirectory(
            environment: ProcessInfo.processInfo.environment,
            isTestProcess: AutomationScheduler.isHostedByTests,
            applicationSupport: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!,
            temporaryDirectory: fileManager.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Where settings, sessions, agents and automations live for this process. Pure, for tests.
    ///
    /// A test process gets a folder of its own. The unit tests are hosted by the app, so without
    /// this every `swift test` and `xcodebuild test` read and rewrote the real `settings.json` and
    /// `mcp_servers.json` — restoring them afterwards when every test was careful, and not when
    /// one was not. `SWIFTOPENWORK_DATA_DIRECTORY` overrides both, for a deliberate run against
    /// real data or a smoke test against a prepared folder.
    static func resolveBaseDirectory(
        environment: [String: String],
        isTestProcess: Bool,
        applicationSupport: URL,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        if let override = environment["SWIFTOPENWORK_DATA_DIRECTORY"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        if isTestProcess {
            return temporaryDirectory.appendingPathComponent("SwiftOpenWork-tests-\(processIdentifier)", isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(AppIdentity.applicationSupportFolderName, isDirectory: true)
    }

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func fileURL(for filename: String) -> URL {
        baseDirectory.appendingPathComponent(filename)
    }

    public func save<T: Encodable>(_ object: T, to filename: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try encoder.encode(object)
            let url = fileURL(for: filename)
            try data.write(to: url, options: .atomic)
            // Owner-only. These files hold workspace paths, full chat transcripts and — until
            // `saveProviders` was fixed — API keys, and were being written world-readable (644).
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            print("[StorageService] Error saving \(filename): \(error.localizedDescription)")
        }
    }

    public func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(type, from: data)
        } catch {
            print("[StorageService] Error loading \(filename): \(error.localizedDescription)")
            return nil
        }
    }

    public func exportBackup() -> URL? {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("SwiftOpenWorkBackup-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let files = (try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let dest = tempDir.appendingPathComponent(file.lastPathComponent)
            try? fileManager.copyItem(at: file, to: dest)
        }
        return tempDir
    }

    public func clearAllData() {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
}
