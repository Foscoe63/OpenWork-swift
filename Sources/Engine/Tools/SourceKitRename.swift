import Foundation

/// A rename the compiler resolves, through `sourcekit-lsp`.
///
/// `SymbolRename`'s text mode replaces every whole-word occurrence, so renaming `Alpha.value()`
/// also renames `Beta.value()`, a local called `value`, and the word in a comment. The compiler's
/// index knows which occurrences are *that* declaration. This asks for them.
///
/// Scope, stated plainly because a rename that silently does less than it claims is the failure
/// this exists to prevent:
/// - **Swift packages only** (a `Package.swift` at the workspace root). `sourcekit-lsp` cannot
///   get build settings for a bare `.xcodeproj` without a build server, and would answer with the
///   declaring file alone — which looks like a successful rename.
/// - **The index must finish first.** Before background indexing completes, a rename comes back
///   covering only the files already indexed. So this waits for indexing to go quiet, and a
///   timeout is a failure, never a partial result.
public enum SourceKitRename {

    public struct TextEdit: Equatable, Sendable {
        /// Zero-based line, and a UTF-16 offset within it, as LSP defines them.
        public var startLine: Int
        public var startCharacter: Int
        public var endLine: Int
        public var endCharacter: Int
        public var newText: String

        public init(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int, newText: String) {
            self.startLine = startLine
            self.startCharacter = startCharacter
            self.endLine = endLine
            self.endCharacter = endCharacter
            self.newText = newText
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notASwiftPackage
        case serverUnavailable(String)
        case indexTimeout(Int)
        case server(String)
        case declarationNotInEdits
        case positionNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .notASwiftPackage:
                return "Compiler rename needs a Swift package (Package.swift at the workspace root) and a .swift declaration."
            case .serverUnavailable(let reason):
                return "sourcekit-lsp could not be started: \(reason)"
            case .indexTimeout(let seconds):
                return "The compiler index was still building after \(seconds)s, so a rename now would miss files."
            case .server(let message):
                return "sourcekit-lsp refused the rename: \(message)"
            case .declarationNotInEdits:
                return "sourcekit-lsp returned edits that do not include the declaration itself, so the index does not know this symbol."
            case .positionNotFound(let name):
                return "'\(name)' does not appear on the declaration line."
            }
        }
    }

    /// Whether the compiler path can be taken at all.
    public static func isCandidate(root: String, declarationPath: String) -> Bool {
        guard declarationPath.hasSuffix(".swift") else { return false }
        return FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Package.swift"))
    }

    /// The UTF-16 column of `name` as a whole word on `lineText`, or nil.
    static func column(of name: String, in lineText: String) -> Int? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(lineText.startIndex..., in: lineText)
        return regex.firstMatch(in: lineText, range: range)?.range.location
    }

    /// Apply LSP edits to a file's text. Pure, so the position arithmetic is testable.
    ///
    /// Edits are applied last-to-first so an earlier edit never shifts a later one's offsets.
    /// Returns nil if any edit points outside the text — a stale index, most likely, and writing
    /// a guessed position would corrupt the file.
    public static func apply(_ edits: [TextEdit], to text: String) -> String? {
        var utf16 = Array(text.utf16)
        var lineStarts = [0]
        for (index, unit) in utf16.enumerated() where unit == 0x0A {
            lineStarts.append(index + 1)
        }

        func offset(line: Int, character: Int) -> Int? {
            guard line >= 0, line < lineStarts.count, character >= 0 else { return nil }
            let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : utf16.count
            let value = lineStarts[line] + character
            return value <= lineEnd ? value : nil
        }

        var resolved: [(start: Int, end: Int, text: String)] = []
        for edit in edits {
            guard let start = offset(line: edit.startLine, character: edit.startCharacter),
                  let end = offset(line: edit.endLine, character: edit.endCharacter),
                  start <= end else { return nil }
            resolved.append((start, end, edit.newText))
        }
        resolved.sort { $0.start > $1.start }
        // Overlapping edits have no defined result.
        for pair in zip(resolved, resolved.dropFirst()) where pair.1.end > pair.0.start {
            return nil
        }
        for edit in resolved {
            utf16.replaceSubrange(edit.start..<edit.end, with: Array(edit.text.utf16))
        }
        return String(decoding: utf16, as: UTF16.self)
    }

    /// Ask the compiler for every edit renaming the symbol declared at `line` (1-based) of `file`.
    ///
    /// Keys of the result are absolute file paths.
    public static func edits(
        root: String,
        file: String,
        line: Int,
        name: String,
        newName: String,
        indexTimeout: TimeInterval = 240
    ) async throws -> [String: [TextEdit]] {
        guard isCandidate(root: root, declarationPath: file) else { throw Failure.notASwiftPackage }
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw Failure.server("could not read \(file)")
        }
        let lines = content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count, let column = column(of: name, in: lines[line - 1]) else {
            throw Failure.positionNotFound(name)
        }

        let connection = try LSPConnection.start(root: root)
        defer { connection.shutdown() }

        let rootURI = URL(fileURLWithPath: root).absoluteString
        _ = try await connection.request("initialize", [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": (root as NSString).lastPathComponent]],
            "capabilities": [
                "window": ["workDoneProgress": true],
                "workspace": ["workspaceEdit": ["documentChanges": true]],
            ],
        ])
        connection.notify("initialized", [:])
        let fileURI = URL(fileURLWithPath: file).absoluteString
        connection.notify("textDocument/didOpen", [
            "textDocument": ["uri": fileURI, "languageId": "swift", "version": 1, "text": content],
        ])

        guard await connection.waitForIndexToSettle(timeout: indexTimeout) else {
            throw Failure.indexTimeout(Int(indexTimeout))
        }

        let response = try await connection.request("textDocument/rename", [
            "textDocument": ["uri": fileURI],
            "position": ["line": line - 1, "character": column],
            "newName": newName,
        ])
        let edits = parseWorkspaceEdit(response)
        let declaration = URL(fileURLWithPath: file).standardizedFileURL.path
        guard edits.keys.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == declaration }) else {
            throw Failure.declarationNotInEdits
        }
        return edits
    }

    /// Both shapes a server may answer with: `changes` keyed by URI, or `documentChanges`.
    static func parseWorkspaceEdit(_ value: Any?) -> [String: [TextEdit]] {
        guard let object = value as? [String: Any] else { return [:] }
        var result: [String: [TextEdit]] = [:]

        func add(uri: String, edits: [[String: Any]]) {
            guard let url = URL(string: uri), url.isFileURL else { return }
            for edit in edits {
                guard let range = edit["range"] as? [String: Any],
                      let start = range["start"] as? [String: Any],
                      let end = range["end"] as? [String: Any],
                      let sl = start["line"] as? Int, let sc = start["character"] as? Int,
                      let el = end["line"] as? Int, let ec = end["character"] as? Int,
                      let text = edit["newText"] as? String else { continue }
                result[url.path, default: []].append(
                    TextEdit(startLine: sl, startCharacter: sc, endLine: el, endCharacter: ec, newText: text)
                )
            }
        }

        if let changes = object["changes"] as? [String: Any] {
            for (uri, edits) in changes {
                add(uri: uri, edits: (edits as? [[String: Any]]) ?? [])
            }
        }
        if let documentChanges = object["documentChanges"] as? [[String: Any]] {
            for change in documentChanges {
                guard let document = change["textDocument"] as? [String: Any],
                      let uri = document["uri"] as? String else { continue }
                add(uri: uri, edits: (change["edits"] as? [[String: Any]]) ?? [])
            }
        }
        return result
    }
}

// MARK: - JSON-RPC over stdio

/// The smallest LSP client that can run one rename: Content-Length framing, request/response
/// matching, and enough progress tracking to know when background indexing has finished.
final class LSPConnection: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    /// Separate from `lock`: frames written from the reader thread and a caller must not interleave.
    private let writeLock = NSLock()
    private var buffer = Data()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var activeIndexTokens = Set<String>()
    private var lastIndexActivity = Date()
    private var terminated = false
    private let started = Date()

    /// The newest Xcode's toolchain, because the Command Line Tools copy of SwiftPM can crash
    /// compiling manifests on this project (see HANDOFF, Environment gotchas).
    static func serverExecutable() -> (URL, [String: String])? {
        var environment = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let xcodes = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .sorted()
            .reversed()
        for xcode in xcodes {
            let developer = "/Applications/\(xcode)/Contents/Developer"
            let binary = developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
            if fm.isExecutableFile(atPath: binary) {
                environment["DEVELOPER_DIR"] = developer
                return (URL(fileURLWithPath: binary), environment)
            }
        }
        let fallback = "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp"
        if fm.isExecutableFile(atPath: fallback) {
            return (URL(fileURLWithPath: fallback), environment)
        }
        return nil
    }

    static func start(root: String) throws -> LSPConnection {
        guard let (executable, environment) = serverExecutable() else {
            throw SourceKitRename.Failure.serverUnavailable("no sourcekit-lsp found in Xcode or the Command Line Tools")
        }
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let connection = LSPConnection(process: process, input: stdin.fileHandleForWriting)
        stdout.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let chunk = handle.availableData
            guard let connection else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                connection.failAll("sourcekit-lsp exited")
            } else {
                connection.receive(chunk)
            }
        }
        do {
            try process.run()
        } catch {
            throw SourceKitRename.Failure.serverUnavailable(error.localizedDescription)
        }
        return connection
    }

    private init(process: Process, input: FileHandle) {
        self.process = process
        self.input = input
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 60) async throws -> Any? {
        let id: Int = lock.withLock {
            nextId += 1
            return nextId
        }
        return try await withCheckedThrowingContinuation { continuation in
            let alreadyDead: Bool = lock.withLock {
                if terminated { return true }
                pending[id] = continuation
                return false
            }
            if alreadyDead {
                continuation.resume(throwing: SourceKitRename.Failure.serverUnavailable("sourcekit-lsp exited"))
                return
            }
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let waiting = self.lock.withLock { self.pending.removeValue(forKey: id) }
                waiting?.resume(throwing: SourceKitRename.Failure.server("\(method) timed out after \(Int(timeout))s"))
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// True once indexing has been quiet long enough to trust.
    ///
    /// Quiet means no open indexing progress and no indexing log line for a few seconds. The grace
    /// period covers a server that is still resolving the package and has not announced anything.
    func waitForIndexToSettle(timeout: TimeInterval, quiet: TimeInterval = 3, grace: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (active, last, dead) = lock.withLock { (activeIndexTokens.count, lastIndexActivity, terminated) }
            if dead { return false }
            let now = Date()
            if active == 0, now.timeIntervalSince(started) >= grace, now.timeIntervalSince(last) >= quiet {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func shutdown() {
        let running = process.isRunning
        guard running else { return }
        write(["jsonrpc": "2.0", "id": Int.max, "method": "shutdown", "params": NSNull()])
        write(["jsonrpc": "2.0", "method": "exit", "params": NSNull()])
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }

    private func write(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        do {
            try writeLock.withLock { try input.write(contentsOf: frame) }
        } catch {
            failAll("could not write to sourcekit-lsp: \(error.localizedDescription)")
        }
    }

    private func receive(_ chunk: Data) {
        var messages: [[String: Any]] = []
        lock.withLock {
            buffer.append(chunk)
            let separator = Data("\r\n\r\n".utf8)
            while let headerEnd = buffer.range(of: separator) {
                let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                guard let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                    buffer.removeAll()
                    return
                }
                let bodyStart = headerEnd.upperBound
                guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
                let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                if let object = try? JSONSerialization.jsonObject(with: buffer[bodyStart..<bodyEnd]) as? [String: Any] {
                    messages.append(object)
                }
                buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            }
        }
        messages.forEach(handle)
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            // A request from the server (e.g. creating a progress token) must be answered or it
            // may wait on us.
            if let id = message["id"] {
                write(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            }
            let params = message["params"] as? [String: Any]
            switch method {
            case "$/progress":
                guard let token = params?["token"].map({ "\($0)" }),
                      let value = params?["value"] as? [String: Any],
                      let kind = value["kind"] as? String else { return }
                let isIndexing = token.lowercased().contains("index")
                    || ((value["title"] as? String)?.lowercased().contains("index") ?? false)
                lock.withLock {
                    switch kind {
                    case "begin" where isIndexing: activeIndexTokens.insert(token)
                    case "end": activeIndexTokens.remove(token)
                    default: break
                    }
                    if isIndexing || activeIndexTokens.contains(token) { lastIndexActivity = Date() }
                }
            case "window/logMessage":
                if let name = params?["logName"] as? String, name.contains("Indexing") {
                    lock.withLock { lastIndexActivity = Date() }
                }
            default:
                break
            }
            return
        }

        guard let id = message["id"] as? Int else { return }
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        if let error = message["error"] as? [String: Any] {
            continuation?.resume(throwing: SourceKitRename.Failure.server((error["message"] as? String) ?? "unknown error"))
        } else {
            continuation?.resume(returning: message["result"])
        }
    }

    private func failAll(_ reason: String) {
        let waiting: [CheckedContinuation<Any?, Error>] = lock.withLock {
            terminated = true
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        waiting.forEach { $0.resume(throwing: SourceKitRename.Failure.serverUnavailable(reason)) }
    }
}
