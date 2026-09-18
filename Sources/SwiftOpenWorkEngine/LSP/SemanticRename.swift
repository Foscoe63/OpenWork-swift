import Foundation

/// A rename a language server resolves.
///
/// `SymbolRename`'s text mode replaces every whole-word occurrence, so renaming `Alpha.value()`
/// also renames `Beta.value()`, a local called `value`, and the word in a comment. The server's
/// index knows which occurrences are *that* declaration. This asks for them.
///
/// A rename that silently does less than it claims is the failure this exists to prevent, so each
/// step refuses rather than guesses:
/// - **Only with a project root** (`LanguageServerCatalog`). sourcekit-lsp on a bare `.xcodeproj`
///   answers with the declaring file alone, which looks like a successful rename.
/// - **Only once indexing has finished.** Earlier, the edits cover only files indexed so far.
/// - **Only at a position the server agrees is renameable** (`prepareRename`).
/// - **Only edits that land on the old name.** An edit whose range holds other text means the
///   index is stale for that file, and writing it would corrupt the file.
public enum SemanticRename {

    public struct TextEdit: Equatable, Hashable, Sendable {
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

    /// What the server proposed: edits keyed by absolute path, and which server proposed them.
    public struct Plan: Sendable {
        public var edits: [String: [TextEdit]]
        public var server: String
        public var notes: [String]
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// No server can answer for this file, or it could not be reached. The string says why.
        case unavailable(String)
        case indexTimeout(String)
        case server(String)
        case notRenameable(String)
        case declarationNotInEdits(String)
        case positionNotFound(String)
        /// An Xcode project whose index predates edits, or that was never built.
        case staleIndex(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason), .indexTimeout(let reason), .server(let reason), .positionNotFound(let reason):
                return reason
            case .staleIndex(let reason):
                return reason
            case .notRenameable(let where_):
                return "The language server says there is nothing to rename at \(where_)."
            case .declarationNotInEdits(let server):
                return "\(server) returned edits that do not include the declaration itself, so its index does not know this symbol."
            }
        }
    }

    /// Apply LSP edits to a file's text. Pure, so the position arithmetic is testable.
    ///
    /// Edits are applied last-to-first so an earlier edit never shifts a later one's offsets.
    /// Returns nil if any edit points outside the text or overlaps another, or — when `expected`
    /// is given — if an edit that changes text does not currently cover `expected`. Each is a sign
    /// the edits were computed against different text, and writing them would corrupt the file.
    public static func apply(_ edits: [TextEdit], to text: String, expected: String? = nil) -> String? {
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

        var resolved: [(start: Int, end: Int, text: [UInt16])] = []
        for edit in edits {
            guard let start = offset(line: edit.startLine, character: edit.startCharacter),
                  let end = offset(line: edit.endLine, character: edit.endCharacter),
                  start <= end else { return nil }
            let current = Array(utf16[start..<end])
            let replacement = Array(edit.newText.utf16)
            // Servers restate unchanged parts, such as argument labels, as edits to themselves.
            if current == replacement { continue }
            if let expected, current != Array(expected.utf16) { return nil }
            resolved.append((start, end, replacement))
        }
        resolved.sort { $0.start > $1.start }
        for pair in zip(resolved, resolved.dropFirst()) where pair.1.end > pair.0.start {
            return nil
        }
        for edit in resolved {
            utf16.replaceSubrange(edit.start..<edit.end, with: edit.text)
        }
        return String(decoding: utf16, as: UTF16.self)
    }

    /// Ask the language server for every edit renaming the symbol declared at `line` (1-based).
    public static func plan(
        workspaceRoot: String,
        file: String,
        line: Int,
        name: String,
        newName: String,
        pool: LanguageServerPool = .shared,
        indexTimeout: TimeInterval = CodeIntelligence.indexTimeout,
        onProgress: CodeIntelligence.ProgressHandler? = nil
    ) async throws -> Plan {
        do {
            return try await makePlan(workspaceRoot: workspaceRoot, file: file, line: line, name: name,
                                      newName: newName, pool: pool, indexTimeout: indexTimeout, onProgress: onProgress)
        } catch let failure as Failure {
            throw failure
        } catch let error as LanguageServerError {
            switch error {
            case .indexTimeout:
                throw Failure.indexTimeout(error.localizedDescription)
            case .unavailable, .outsideWorkspace, .crashLooping, .unsupported:
                throw Failure.unavailable(error.localizedDescription)
            case .fileUnreadable, .request:
                throw Failure.server(error.localizedDescription)
            }
        } catch let error as SymbolPosition.Failure {
            throw Failure.positionNotFound(error.localizedDescription)
        } catch {
            throw Failure.server(error.localizedDescription)
        }
    }

    private static func makePlan(
        workspaceRoot: String, file: String, line: Int, name: String, newName: String,
        pool: LanguageServerPool, indexTimeout: TimeInterval, onProgress: CodeIntelligence.ProgressHandler?
    ) async throws -> Plan {
        let path = LanguageServerCatalog.standardized(file)
        let lease = try await pool.session(for: path, workspaceRoot: workspaceRoot)
        let session = lease.session
        // An Xcode project's index is only as new as its last build, and a rename from a stale
        // one misses the uses written since. Refuse rather than rename part of them.
        if let configuration = XcodeBuildServer.configuration(at: session.root) {
            let freshness = XcodeBuildServer.freshness(root: session.root, configuration: configuration)
            if freshness.isStale {
                throw Failure.staleIndex(XcodeBuildServer.note(for: freshness) + " A rename from this index could miss uses, so it was not attempted.")
            }
        }
        try await session.waitUntilIndexed(timeout: indexTimeout, onProgress: onProgress)
        let (uri, text) = try await session.open(path)
        // The declaration line usually names the symbol once; `func value(value: Int)` names it
        // twice, and the keyword says which is the declaration.
        let position = try SymbolPosition.resolve(in: text, line: line, symbol: name, column: nil, preferDeclaration: true)
        let positionParams: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character],
        ]
        let place = "\(CodeIntelligence.relativePath(path, workspaceRoot: workspaceRoot)):\(line)"

        do {
            let prepared = try await session.send("textDocument/prepareRename", positionParams)
            if prepared == nil { throw Failure.notRenameable(place) }
        } catch LanguageServerError.unsupported {
            // Optional in the protocol; the declaration check below still applies.
        }

        var params = positionParams
        params["newName"] = newName
        let response = try await session.send("textDocument/rename", params, timeout: indexTimeout)
        let edits = mergeByResolvedPath(parseWorkspaceEdit(response))
        guard edits.keys.contains(path) else {
            throw Failure.declarationNotInEdits(session.server)
        }
        return Plan(edits: edits, server: session.server, notes: lease.notes)
    }

    /// The server can name one file by two paths — the URI it was opened with and the path its
    /// index recorded, e.g. /var/… and /private/var/…. Applied separately, the second copy
    /// rewrites a file the first already rewrote. Merge on the resolved path.
    public static func mergeByResolvedPath(_ edits: [String: [TextEdit]]) -> [String: [TextEdit]] {
        var merged: [String: [TextEdit]] = [:]
        for (path, fileEdits) in edits {
            let resolved = LanguageServerCatalog.standardized(path)
            for edit in fileEdits where !(merged[resolved]?.contains(edit) ?? false) {
                merged[resolved, default: []].append(edit)
            }
        }
        return merged
    }

    /// Both shapes a server may answer with: `changes` keyed by URI, or `documentChanges`.
    public static func parseWorkspaceEdit(_ value: Any?) -> [String: [TextEdit]] {
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
