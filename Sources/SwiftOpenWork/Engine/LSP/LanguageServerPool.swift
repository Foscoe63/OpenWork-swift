import Foundation
import SwiftOpenWorkCore

/// The running language servers, one per server and project root.
///
/// - Started on first use, so a workspace nobody asks about costs nothing.
/// - Restarted when found dead, and the answer says so. A server that crashes three times in five
///   minutes is left down: restarting it forever would hide the crash and burn the machine.
/// - Stopped after ten idle minutes. sourcekit-lsp on a large package holds gigabytes.
public actor LanguageServerPool {
    public static let shared = LanguageServerPool()

    /// A running session, and anything worth telling the caller about how it was obtained.
    public struct Lease: Sendable {
        public let session: LanguageServerSession
        public let notes: [String]
    }

    private var sessions: [String: LanguageServerSession] = [:]
    private var starting: [String: Task<LanguageServerSession, Error>] = [:]
    private var crashes: [String: [Date]] = [:]
    private var reaper: Task<Void, Never>?
    private let locator: ExecutableLocator
    private let idleTimeout: TimeInterval

    static let crashLimit = 3
    static let crashWindow: TimeInterval = 300

    init(locator: ExecutableLocator = ExecutableLocator(), idleTimeout: TimeInterval = 600) {
        self.locator = locator
        self.idleTimeout = idleTimeout
    }

    /// The session that answers for `file`, starting or restarting its server as needed.
    public func session(for file: String, workspaceRoot: String) async throws -> Lease {
        let path = LanguageServerCatalog.standardized(file)
        let root = LanguageServerCatalog.standardized(workspaceRoot)
        guard path.hasPrefix(root + "/") else { throw LanguageServerError.outsideWorkspace(file) }

        let resolution: LanguageServerCatalog.Resolution
        switch LanguageServerCatalog.resolve(file: path, workspaceRoot: root, locator: locator) {
        case .success(let value): resolution = value
        case .failure(let reason): throw LanguageServerError.unavailable(reason)
        }

        let key = resolution.spec.id + "\u{0}" + resolution.root
        var notes: [String] = []
        if let existing = sessions[key] {
            if existing.isAlive { return Lease(session: existing, notes: []) }
            sessions[key] = nil
            let reason = existing.connection.terminationReason ?? "it stopped responding"
            await existing.shutdown()
            let recent = (crashes[key, default: []] + [Date()]).filter { Date().timeIntervalSince($0) < Self.crashWindow }
            crashes[key] = recent
            if recent.count >= Self.crashLimit {
                throw LanguageServerError.crashLooping(server: resolution.spec.id, reason: reason)
            }
            notes.append("\(resolution.spec.id) had stopped (\(reason)) and was restarted, so it re-indexed.")
            AppLog.verbose(.tools, "lsp restart \(resolution.spec.id) at \(resolution.root): \(reason)")
        }

        if let pending = starting[key] {
            return Lease(session: try await pending.value, notes: notes)
        }
        let task = Task { try await LanguageServerSession.start(resolution) }
        starting[key] = task
        do {
            let session = try await task.value
            starting[key] = nil
            sessions[key] = session
            startReaperIfNeeded()
            AppLog.verbose(.tools, "lsp started \(resolution.spec.id) at \(resolution.root) using \(resolution.executable)")
            return Lease(session: session, notes: notes)
        } catch {
            starting[key] = nil
            throw error
        }
    }

    /// Tell servers that files changed, ahead of the file-system events that will also say so.
    ///
    /// `created` lists the paths that did not exist before; a server may ignore a new file it is
    /// told merely changed (see `FileChangeWatcher.classify`). Paths that no longer exist are
    /// reported as deleted whatever the caller says.
    public func filesChanged(_ paths: [String], created: Set<String> = []) {
        guard !sessions.isEmpty else { return }
        let createdPaths = Set(created.map(LanguageServerCatalog.standardized))
        let standardized = paths.map(LanguageServerCatalog.standardized)
        for session in sessions.values {
            let changes = standardized.compactMap { path -> (String, SessionEvents.FileChange)? in
                guard FileChangeWatcher.isRelevant(path, root: session.root, spec: session.resolution.spec) else { return nil }
                guard FileManager.default.fileExists(atPath: path) else { return (path, .deleted) }
                return (path, createdPaths.contains(path) ? .created : .changed)
            }
            if !changes.isEmpty { session.events.record(changes) }
        }
    }

    /// Stop every server under `root`: a workspace that was closed, or a test's temporary package.
    public func shutdown(under root: String) async {
        let base = LanguageServerCatalog.standardized(root)
        let matching = sessions.filter { $0.value.root == base || $0.value.root.hasPrefix(base + "/") }
        for (key, session) in matching {
            sessions[key] = nil
            await session.shutdown()
        }
    }

    public func shutdownAll() async {
        let all = sessions
        sessions.removeAll()
        for session in all.values {
            await session.shutdown()
        }
    }

    var runningServers: [(server: String, root: String)] {
        sessions.values.map { ($0.server, $0.root) }
    }

    // MARK: - Idle shutdown

    private func startReaperIfNeeded() {
        guard reaper == nil else { return }
        let interval = min(60, idleTimeout / 2)
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                await self.stopIdleServers()
            }
        }
    }

    func stopIdleServers() async {
        for (key, session) in sessions {
            let busy = await session.inFlight > 0
            let idle = await Date().timeIntervalSince(session.lastUsed)
            // A dead server is left for `session(for:)` to find, so the crash is counted and reported.
            guard !busy, idle >= idleTimeout else { continue }
            sessions[key] = nil
            await session.shutdown()
            AppLog.verbose(.tools, "lsp stopped idle \(session.server) at \(session.root)")
        }
        if sessions.isEmpty {
            reaper?.cancel()
            reaper = nil
        }
    }
}
