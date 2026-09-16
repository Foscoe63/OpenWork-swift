import Foundation

/// Why a code-intelligence request could not be answered.
public enum LanguageServerError: Error, LocalizedError, Equatable {
    case unavailable(LanguageServerCatalog.Unavailable)
    case outsideWorkspace(String)
    case fileUnreadable(String)
    /// The server kept crashing, so it is not restarted again for a while.
    case crashLooping(server: String, reason: String)
    case indexTimeout(server: String, seconds: Int)
    case unsupported(server: String, method: String)
    case request(server: String, LSPConnection.Failure)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason.localizedDescription
        case .outsideWorkspace(let path):
            return "\(path) is outside the workspace, so no language server is started for it."
        case .fileUnreadable(let path):
            return "Could not read \(path) as UTF-8 text."
        case .crashLooping(let server, let reason):
            return "\(server) crashed three times in five minutes and will not be restarted yet. Last failure: \(reason)"
        case .indexTimeout(let server, let seconds):
            return "\(server) was still indexing after \(seconds)s. Answering now would miss files, so nothing was returned. Try again shortly."
        case .unsupported(let server, let method):
            return "\(server) does not support \(method)."
        case .request(let server, let failure):
            return "\(server): \(failure.localizedDescription)"
        }
    }
}

/// State the server pushes at us, written from the connection's reader thread.
final class SessionEvents: @unchecked Sendable {

    struct PublishedDiagnostics {
        var version: Int?
        var items: [[String: Any]]
        var received: Date
    }

    enum FileChange: Int {
        // Values are LSP's FileChangeType.
        case created = 1
        case changed = 2
        case deleted = 3
    }

    struct ProgressReport: Equatable {
        var title: String
        var message: String?
        var percentage: Int?
    }

    private let lock = NSLock()
    private var activeProgress = Set<String>()
    /// Titles and latest reports of open progress, in the order they began.
    private var reports: [(token: String, report: ProgressReport)] = []
    private var lastActivity = Date()
    private var diagnostics: [String: PublishedDiagnostics] = [:]
    private var fileChanges: [String: FileChange] = [:]

    func progress(token: String, kind: String, title: String? = nil, message: String? = nil, percentage: Int? = nil) {
        lock.withLock {
            switch kind {
            case "begin":
                activeProgress.insert(token)
                reports.removeAll { $0.token == token }
                reports.append((token, ProgressReport(title: title ?? "Working", message: message, percentage: percentage)))
            case "report":
                if let index = reports.firstIndex(where: { $0.token == token }) {
                    if let message { reports[index].report.message = message }
                    if let percentage { reports[index].report.percentage = percentage }
                }
            case "end":
                activeProgress.remove(token)
                reports.removeAll { $0.token == token }
            default:
                break
            }
            lastActivity = Date()
        }
    }

    /// One line describing open progress, e.g. "Indexing: 12 / 40 (30%)", or nil when idle.
    var progressSummary: String? {
        let open = lock.withLock { reports.map(\.report) }
        guard !open.isEmpty else { return nil }
        return open.map { report in
            var line = report.title
            if let message = report.message, !message.isEmpty { line += ": \(message)" }
            if let percentage = report.percentage, !(report.message ?? "").contains("%") { line += " (\(percentage)%)" }
            return line
        }.joined(separator: "; ")
    }

    func activity() {
        lock.withLock { lastActivity = Date() }
    }

    var progressState: (active: Int, lastActivity: Date) {
        lock.withLock { (activeProgress.count, lastActivity) }
    }

    func publish(path: String, version: Int?, items: [[String: Any]]) {
        lock.withLock { diagnostics[path] = PublishedDiagnostics(version: version, items: items, received: Date()) }
    }

    func published(path: String) -> PublishedDiagnostics? {
        lock.withLock { diagnostics[path] }
    }

    func record(_ changes: [(String, FileChange)]) {
        lock.withLock {
            for (path, change) in changes {
                // A file created and then edited before we look is still new to the server.
                if fileChanges[path] == .created, change == .changed { continue }
                fileChanges[path] = change
            }
        }
    }

    func takeFileChanges() -> [String: FileChange] {
        lock.withLock {
            defer { fileChanges.removeAll() }
            return fileChanges
        }
    }
}

/// One running language server for one project root.
///
/// Long-lived on purpose: the first request pays for launching and indexing, later ones do not.
/// That makes staying in step with the disk this type's main job. Every request re-reads the files
/// it names, and file-system events for everything else are forwarded before the next request, so
/// an edit made by a tool, a shell command or the user in another editor is seen.
public actor LanguageServerSession {

    public nonisolated let resolution: LanguageServerCatalog.Resolution
    nonisolated let connection: LSPConnection
    nonisolated let events: SessionEvents
    private var watcher: FileChangeWatcher?
    private var capabilities: [String: Any] = [:]
    private var documents: [String: OpenDocument] = [:]
    private var synchronizeUnsupported = false
    /// Older sourcekit-lsp refuses `buildServerUpdates` even with the feature requested.
    private var buildServerUpdatesUnsupported = false
    private var pullDiagnosticsUnsupported = false
    private let started = Date()
    private(set) var lastUsed = Date()
    private(set) var inFlight = 0

    static let maxOpenDocuments = 40

    struct OpenDocument {
        var version: Int
        var text: String
        var lastUsed: Date
    }

    public nonisolated var server: String { resolution.spec.id }
    public nonisolated var root: String { resolution.root }
    public nonisolated var isAlive: Bool { connection.isAlive }

    // MARK: - Start and stop

    static func start(_ resolution: LanguageServerCatalog.Resolution, initializeTimeout: TimeInterval = 120) async throws -> LanguageServerSession {
        let events = SessionEvents()
        let root = resolution.root
        let connection: LSPConnection
        do {
            connection = try LSPConnection.launch(
                executable: URL(fileURLWithPath: resolution.executable),
                arguments: resolution.arguments,
                environment: resolution.environment,
                workingDirectory: root,
                onServerRequest: { method, params in
                    answerServerRequest(method: method, params: params, root: root, events: events)
                },
                onNotification: { method, params in
                    handleNotification(method: method, params: params, events: events)
                }
            )
        } catch let failure as LSPConnection.Failure {
            throw LanguageServerError.request(server: resolution.spec.id, failure)
        }
        let session = LanguageServerSession(resolution: resolution, connection: connection, events: events)
        do {
            try await session.initialize(timeout: initializeTimeout)
        } catch {
            connection.terminateNow()
            throw error
        }
        return session
    }

    private init(resolution: LanguageServerCatalog.Resolution, connection: LSPConnection, events: SessionEvents) {
        self.resolution = resolution
        self.connection = connection
        self.events = events
    }

    private func initialize(timeout: TimeInterval) async throws {
        let rootURI = URL(fileURLWithPath: root, isDirectory: true).absoluteString
        let linkSupport: [String: Any] = ["linkSupport": true]
        let options = resolution.spec.initializationOptions
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        let result = try await send("initialize", [
            "initializationOptions": options,
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "clientInfo": ["name": AppIdentity.displayName],
            "rootUri": rootURI,
            "rootPath": root,
            "workspaceFolders": [["uri": rootURI, "name": (root as NSString).lastPathComponent]],
            "capabilities": [
                "window": ["workDoneProgress": true],
                "workspace": [
                    "workspaceFolders": true,
                    "configuration": true,
                    "didChangeWatchedFiles": ["dynamicRegistration": false],
                    "workspaceEdit": ["documentChanges": true],
                    "symbol": [:] as [String: Any],
                ],
                "textDocument": [
                    "synchronization": ["didSave": false],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": linkSupport,
                    "declaration": linkSupport,
                    "typeDefinition": linkSupport,
                    "implementation": linkSupport,
                    "references": [:] as [String: Any],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "rename": ["prepareSupport": true],
                    "publishDiagnostics": ["versionSupport": true],
                    "diagnostic": ["dynamicRegistration": false],
                    "callHierarchy": [:] as [String: Any],
                ],
            ] as [String: Any],
        ], timeout: timeout)
        capabilities = ((result as? [String: Any])?["capabilities"] as? [String: Any]) ?? [:]
        connection.notify("initialized", [:])

        let spec = resolution.spec
        let root = self.root
        watcher = FileChangeWatcher(root: root) { [events] changes in
            let relevant = changes.compactMap { item -> (String, SessionEvents.FileChange)? in
                FileChangeWatcher.isRelevant(item.path, root: root, spec: spec) ? (item.path, item.change) : nil
            }
            if !relevant.isEmpty { events.record(relevant) }
        }
    }

    deinit {
        watcher?.stop()
    }

    public func shutdown() async {
        watcher?.stop()
        watcher = nil
        await connection.shutdown()
    }

    // MARK: - Requests

    /// Send a request, translating transport failures into errors that name the server.
    func send(_ method: String, _ params: Any?, timeout: TimeInterval = 60) async throws -> Any? {
        lastUsed = Date()
        inFlight += 1
        defer {
            inFlight -= 1
            lastUsed = Date()
        }
        do {
            return try await connection.request(method, params, timeout: timeout)
        } catch let failure as LSPConnection.Failure {
            if failure.isMethodNotFound {
                throw LanguageServerError.unsupported(server: server, method: method)
            }
            throw LanguageServerError.request(server: server, failure)
        }
    }

    /// Wait until the server's index covers the workspace, or throw.
    ///
    /// Index-backed answers — references, callers, a rename — silently cover only the files
    /// indexed so far. A timeout is therefore an error, never a partial answer.
    ///
    /// `onProgress` receives a line whenever the server's reported progress changes, so a caller
    /// can show a first index that takes minutes as work rather than a hang.
    func waitUntilIndexed(timeout: TimeInterval, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        flushFileChanges()
        let reporter = onProgress.map { report in
            Task { [events, server] in
                var last: String?
                let started = Date()
                var announced = false
                while !Task.isCancelled {
                    if let summary = events.progressSummary, summary != last {
                        report("\(server): \(summary)")
                        last = summary
                        announced = true
                    } else if !announced, Date().timeIntervalSince(started) >= 2 {
                        report("Waiting for \(server) to finish loading the project…")
                        announced = true
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        defer { reporter?.cancel() }

        if resolution.spec.readiness == .synchronizeRequest, !synchronizeUnsupported {
            do {
                // `buildServerUpdates` waits for build settings as well as the index. It is an
                // experimental option, enabled through `initializationOptions`; a server that
                // still refuses it gets the index-only request.
                var params: [String: Any] = ["index": true]
                if !buildServerUpdatesUnsupported { params["buildServerUpdates"] = true }
                do {
                    _ = try await send("workspace/synchronize", params, timeout: timeout)
                } catch LanguageServerError.request(_, .server(_, let message)) where message.contains("experimental") && !buildServerUpdatesUnsupported {
                    buildServerUpdatesUnsupported = true
                    _ = try await send("workspace/synchronize", ["index": true], timeout: timeout)
                }
                // A server with background indexing turned off returns at once. Its progress
                // reports are then the only signal left, so fall through when any are open.
                if events.progressState.active == 0 { return }
            } catch LanguageServerError.unsupported {
                synchronizeUnsupported = true
            } catch LanguageServerError.request(_, .timedOut) {
                throw LanguageServerError.indexTimeout(server: server, seconds: Int(timeout))
            }
        }
        try await waitForQuietProgress(timeout: timeout)
    }

    /// Ready once no work-done progress is open and none has been reported for `quiet` seconds.
    /// `grace` covers a server still loading its project that has not reported anything yet.
    private func waitForQuietProgress(timeout: TimeInterval, quiet: TimeInterval = 1.5, grace: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isAlive else {
                throw LanguageServerError.request(server: server, .unavailable(connection.terminationReason ?? "\(server) exited."))
            }
            let (active, last) = events.progressState
            let now = Date()
            if active == 0, now.timeIntervalSince(started) >= grace, now.timeIntervalSince(last) >= quiet {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LanguageServerError.indexTimeout(server: server, seconds: Int(timeout))
    }

    // MARK: - Documents

    /// Make the server's copy of `path` match the disk, and return its URI and text.
    func open(_ path: String) throws -> (uri: String, text: String) {
        flushFileChanges()
        return try sync(path)
    }

    @discardableResult
    private func sync(_ path: String) throws -> (uri: String, text: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw LanguageServerError.fileUnreadable(path)
        }
        let uri = URL(fileURLWithPath: path).absoluteString
        if var document = documents[path] {
            if document.text != text {
                document.version += 1
                document.text = text
                connection.notify("textDocument/didChange", [
                    "textDocument": ["uri": uri, "version": document.version],
                    "contentChanges": [["text": text]],
                ])
            }
            document.lastUsed = Date()
            documents[path] = document
        } else {
            if documents.count >= Self.maxOpenDocuments,
               let oldest = documents.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                close(oldest)
            }
            connection.notify("textDocument/didOpen", [
                "textDocument": [
                    "uri": uri,
                    "languageId": resolution.spec.languageId(forPath: path) ?? "plaintext",
                    "version": 1,
                    "text": text,
                ],
            ])
            documents[path] = OpenDocument(version: 1, text: text, lastUsed: Date())
        }
        return (uri, text)
    }

    private func close(_ path: String) {
        documents[path] = nil
        connection.notify("textDocument/didClose", ["textDocument": ["uri": URL(fileURLWithPath: path).absoluteString]])
    }

    func version(of path: String) -> Int? {
        documents[path]?.version
    }

    /// Tell the server about files that changed on disk since the last request.
    func flushFileChanges() {
        let changes = events.takeFileChanges()
        guard !changes.isEmpty else { return }
        for (path, change) in changes where documents[path] != nil {
            if change == .deleted {
                close(path)
            } else {
                _ = try? sync(path)
            }
        }
        connection.notify("workspace/didChangeWatchedFiles", [
            "changes": changes.sorted { $0.key < $1.key }.map { path, change in
                ["uri": URL(fileURLWithPath: path).absoluteString, "type": change.rawValue]
            },
        ])
    }

    // MARK: - Diagnostics

    /// Diagnostics for one file: pulled where the server supports it, otherwise the next set it
    /// publishes for the version we sent.
    func diagnostics(for path: String, timeout: TimeInterval) async throws -> [[String: Any]] {
        let (uri, _) = try open(path)
        if !pullDiagnosticsUnsupported {
            do {
                let report = try await send("textDocument/diagnostic", ["textDocument": ["uri": uri]], timeout: timeout)
                return ((report as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            } catch LanguageServerError.unsupported {
                pullDiagnosticsUnsupported = true
            }
        }

        let version = documents[path]?.version
        let asked = Date()
        let deadline = asked.addingTimeInterval(timeout)
        while Date() < deadline {
            if let published = events.published(path: path) {
                let current = published.version.map { $0 == version } ?? (published.received > asked)
                // Servers often publish twice — a quick syntactic pass, then the semantic one — so
                // take a set only once it has stood for a moment.
                if current, Date().timeIntervalSince(published.received) >= 1 {
                    return published.items
                }
            }
            guard isAlive else {
                throw LanguageServerError.request(server: server, .unavailable(connection.terminationReason ?? "\(server) exited."))
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LanguageServerError.request(server: server, .timedOut(method: "textDocument/publishDiagnostics", seconds: Int(timeout)))
    }

    // MARK: - Server-initiated traffic

    static func answerServerRequest(method: String, params: Any?, root: String, events: SessionEvents) -> Result<Any, LSPConnection.ServerRequestError> {
        switch method {
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
             "workspace/semanticTokens/refresh", "workspace/inlayHint/refresh", "workspace/codeLens/refresh",
             "workspace/diagnostic/refresh", "workspace/inlineValue/refresh":
            return .success(NSNull())
        case "window/showMessageRequest":
            // No action chosen. That includes declining sourcekit-lsp's workspace-trust prompt,
            // which is right: an agent's workspace may be a repository nobody has vetted.
            return .success(NSNull())
        case "workspace/configuration":
            let items = ((params as? [String: Any])?["items"] as? [Any]) ?? []
            return .success(Array(repeating: NSNull(), count: items.count))
        case "workspace/workspaceFolders":
            let uri = URL(fileURLWithPath: root, isDirectory: true).absoluteString
            return .success([["uri": uri, "name": (root as NSString).lastPathComponent]])
        case "workspace/applyEdit":
            // Edits go through the app's own tools, which record checkpoints and show diffs.
            return .success(["applied": false, "failureReason": "This client applies edits itself."])
        case "window/showDocument":
            return .success(["success": false])
        default:
            return .failure(.methodNotFound(method))
        }
    }

    static func handleNotification(method: String, params: [String: Any]?, events: SessionEvents) {
        switch method {
        case "$/progress":
            guard let token = params?["token"].map({ "\($0)" }),
                  let value = params?["value"] as? [String: Any],
                  let kind = value["kind"] as? String else { return }
            events.progress(token: token, kind: kind, title: value["title"] as? String,
                            message: value["message"] as? String, percentage: value["percentage"] as? Int)
        case "textDocument/publishDiagnostics":
            guard let uri = params?["uri"] as? String, let url = URL(string: uri), url.isFileURL else { return }
            events.publish(
                path: LanguageServerCatalog.standardized(url.path),
                version: params?["version"] as? Int,
                items: (params?["diagnostics"] as? [[String: Any]]) ?? []
            )
        case "window/logMessage":
            // sourcekit-lsp logs indexing work here as well as reporting progress.
            if let name = params?["logName"] as? String, name.contains("Index") {
                events.activity()
            }
        default:
            break
        }
    }
}
