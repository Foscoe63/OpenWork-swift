import Foundation

public final class StorageService: @unchecked Sendable {
    public static let shared = StorageService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public var baseDirectory: URL {
        let directory = Self.resolvedBaseDirectory
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Names a data folder to use instead of Application Support. For a deliberate test run
    /// against real data, point it at `~/Library/Application Support/SwiftOpenWork`.
    public static let dataDirectoryEnvironmentKey = "SWIFTOPENWORK_DATA_DIRECTORY"

    /// Where settings, sessions, agents and automations live.
    ///
    /// Under XCTest this is a folder of its own, one per test process. `xcodebuild test` launches
    /// the real app as the test host, and tests save settings through the shared store; against
    /// Application Support, a test that crashed before restoring left the developer's settings
    /// changed, and anything the app does at launch ran on real data. Resolved once, so every
    /// store in the process agrees for its whole life.
    static let resolvedBaseDirectory: URL = resolveBaseDirectory(
        environment: ProcessInfo.processInfo.environment,
        hostedByTests: AutomationScheduler.isHostedByTests,
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!,
        temporaryDirectory: FileManager.default.temporaryDirectory,
        processIdentifier: ProcessInfo.processInfo.processIdentifier
    )

    static var testDirectoryPrefix: String { "\(AppIdentity.applicationSupportFolderName)-tests-" }

    /// Delete test data folders whose process has exited, so runs do not pile up.
    static func removeFinishedTestDirectories(
        in temporaryDirectory: URL,
        isRunning: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
        for name in names where name.hasPrefix(testDirectoryPrefix) {
            guard let pid = Int32(name.dropFirst(testDirectoryPrefix.count)), !isRunning(pid) else { continue }
            try? fileManager.removeItem(at: temporaryDirectory.appendingPathComponent(name))
        }
    }

    static func resolveBaseDirectory(
        environment: [String: String],
        hostedByTests: Bool,
        applicationSupport: URL,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        if let explicit = environment[dataDirectoryEnvironmentKey], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
        }
        if hostedByTests {
            removeFinishedTestDirectories(in: temporaryDirectory)
            return temporaryDirectory.appendingPathComponent("\(testDirectoryPrefix)\(processIdentifier)", isDirectory: true)
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
