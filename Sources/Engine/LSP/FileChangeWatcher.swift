import CoreServices
import Foundation

/// File-level FSEvents for one directory tree.
///
/// A language server that outlives a single request has to hear about edits it did not make:
/// an agent's `terminal_command`, a `git checkout`, the user saving in another editor. Tools that
/// write files also notify the pool directly, because FSEvents arrive a fraction of a second
/// late and an agent often edits and queries back to back.
///
/// Call `stop()` when done: the running stream keeps the watcher alive.
final class FileChangeWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([(path: String, change: SessionEvents.FileChange)]) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).lsp-file-events")
    private let lock = NSLock()

    init?(root: String, latency: TimeInterval = 0.2, handler: @escaping Handler) {
        self.handler = handler
        // The stream retains the watcher, so a callback already queued when `stop()` runs never
        // reaches a freed object. `stop()` releasing the stream is what breaks the cycle.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FileChangeWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FileChangeWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            var files: [(path: String, change: SessionEvents.FileChange)] = []
            for index in 0..<min(count, paths.count) {
                let flags = Int(eventFlags[index])
                // Directory events carry no file to re-read; file events inside them arrive too.
                guard flags & kFSEventStreamEventFlagItemIsFile != 0 else { continue }
                let path = LanguageServerCatalog.standardized(paths[index])
                files.append((path, FileChangeWatcher.classify(flags: flags, exists: FileManager.default.fileExists(atPath: path))))
            }
            if !files.isEmpty { watcher.handler(files) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    func stop() {
        let current: FSEventStreamRef? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    /// What happened to a file, in LSP's terms.
    ///
    /// The difference between created and changed is not cosmetic: sourcekit-lsp adds a file to
    /// its package, and so to the index, only when told it was *created*. Reported as changed, a
    /// new file is never indexed and references to it are silently missing. An atomic save
    /// (write a temporary file, rename it over the original) also carries the renamed flag, so it
    /// is reported as created too; that costs the server a package reload, not a wrong answer.
    static func classify(flags: Int, exists: Bool) -> SessionEvents.FileChange {
        guard exists else { return .deleted }
        let created = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
        return flags & created != 0 ? .created : .changed
    }

    /// Whether a changed file matters to a server: a source file it handles or a project file,
    /// and not inside build output, dependencies or version control.
    static func isRelevant(_ path: String, root: String, spec: LanguageServerSpec) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        let components = path.dropFirst(root.count + 1).split(separator: "/")
        guard let name = components.last else { return false }
        for directory in components.dropLast() {
            if directory.hasPrefix(".") || directory == "node_modules" || directory == "DerivedData" {
                return false
            }
        }
        return spec.languageId(forPath: path) != nil || spec.rootMarkers.contains(String(name))
    }
}
