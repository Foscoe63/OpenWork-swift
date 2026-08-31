import Foundation

public final class StorageService: @unchecked Sendable {
    public static let shared = StorageService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let openworkDir = appSupport.appendingPathComponent("OpenWorkSwift", isDirectory: true)
        if !fileManager.fileExists(atPath: openworkDir.path) {
            try? fileManager.createDirectory(at: openworkDir, withIntermediateDirectories: true)
        }
        return openworkDir
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
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("OpenWorkBackup-\(UUID().uuidString)", isDirectory: true)
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
