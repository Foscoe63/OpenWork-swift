import Foundation
import SwiftOpenWorkCore

/// Compiler-grade answers about code, for agents: where a symbol is defined, who uses it, what
/// type it has, what is wrong with a file.
///
/// Every answer comes from a language server (see `LanguageServerCatalog`) and says which one.
/// Paths in the output are `path:line:column:` relative to the workspace, so they read like
/// compiler output and the chat can link them.
public enum CodeIntelligence {

    /// Where to ask about: a file, a 1-based line, and the name on that line (or a column).
    public struct Target: Sendable {
        public var path: String
        public var line: Int
        public var symbol: String?
        public var column: Int?

        public init(path: String, line: Int, symbol: String?, column: Int?) {
            self.path = path
            self.line = line
            self.symbol = symbol
            self.column = column
        }
    }

    public enum DefinitionKind: String, Sendable, CaseIterable {
        case definition
        case declaration
        case typeDefinition = "type_definition"
        case implementation

        public var method: String {
            switch self {
            case .definition: return "textDocument/definition"
            case .declaration: return "textDocument/declaration"
            case .typeDefinition: return "textDocument/typeDefinition"
            case .implementation: return "textDocument/implementation"
            }
        }
    }

    public enum CallDirection: String, Sendable {
        case incoming
        case outgoing
    }

    /// How long to wait for a server's index before refusing. The first request in a large
    /// package pays for the whole index; later requests return immediately.
    public static let indexTimeout: TimeInterval = 240

    /// Receives a line whenever the server reports indexing progress.
    public typealias ProgressHandler = @Sendable (String) -> Void

    // MARK: - Operations

    public static func definition(
        _ target: Target, kind: DefinitionKind = .definition,
        workspaceRoot: String, pool: LanguageServerPool = .shared, onProgress: ProgressHandler? = nil
    ) async throws -> String {
        let context = try await prepare(target, workspaceRoot: workspaceRoot, pool: pool, onProgress: onProgress)
        let result = try await context.session.send(kind.method, context.positionParams)
        let locations = parseLocations(result)
        let label = kind.rawValue.replacingOccurrences(of: "_", with: " ")
        guard !locations.isEmpty else {
            return context.header + "No \(label) found for \(context.subject)."
        }
        let lines = formatLocations(locations, workspaceRoot: workspaceRoot)
        return context.header + "\(locations.count == 1 ? "1 \(label)" : "\(locations.count) \(label)s") of \(context.subject):\n" + lines.joined(separator: "\n")
    }

    public static func references(
        _ target: Target, includeDeclaration: Bool = true, limit: Int = 200,
        workspaceRoot: String, pool: LanguageServerPool = .shared, onProgress: ProgressHandler? = nil
    ) async throws -> String {
        let context = try await prepare(target, workspaceRoot: workspaceRoot, pool: pool, onProgress: onProgress)
        var params = context.positionParams
        params["context"] = ["includeDeclaration": includeDeclaration]
        let result = try await context.session.send("textDocument/references", params, timeout: indexTimeout)
        let locations = parseLocations(result).sorted()
        guard !locations.isEmpty else {
            return context.header + "No references to \(context.subject) found."
        }
        let files = Set(locations.map(\.path)).count
        let shown = Array(locations.prefix(max(1, limit)))
        var text = context.header
            + "\(locations.count) reference\(locations.count == 1 ? "" : "s") to \(context.subject) in \(files) file\(files == 1 ? "" : "s")\(includeDeclaration ? ", including the declaration" : ""):\n"
            + formatLocations(shown, workspaceRoot: workspaceRoot).joined(separator: "\n")
        if locations.count > shown.count {
            text += "\n… \(locations.count - shown.count) more not shown. Raise `limit` to see them."
        }
        return text
    }

    /// Hover: the declaration's signature and documentation, plus where it is declared.
    public static func symbolInfo(
        _ target: Target, workspaceRoot: String, pool: LanguageServerPool = .shared, onProgress: ProgressHandler? = nil
    ) async throws -> String {
        let context = try await prepare(target, workspaceRoot: workspaceRoot, pool: pool, onProgress: onProgress)
        let hover = try await context.session.send("textDocument/hover", context.positionParams)
        let contents = hoverText(hover)
        let declared = (try? await context.session.send("textDocument/definition", context.positionParams))
            .map(parseLocations) ?? []
        guard !contents.isEmpty || !declared.isEmpty else {
            return context.header + "The server has no information about \(context.subject)."
        }
        var text = context.header + (contents.isEmpty ? "No signature or documentation for \(context.subject)." : contents)
        if !declared.isEmpty {
            text += "\n\nDeclared at:\n" + formatLocations(declared, workspaceRoot: workspaceRoot).joined(separator: "\n")
        }
        return text
    }

    public static func diagnostics(
        path: String, workspaceRoot: String, pool: LanguageServerPool = .shared, onProgress: ProgressHandler? = nil
    ) async throws -> String {
        let absolute = absolutePath(path, workspaceRoot: workspaceRoot)
        let lease = try await pool.session(for: absolute, workspaceRoot: workspaceRoot)
        let session = lease.session
        try await session.waitUntilIndexed(timeout: indexTimeout, onProgress: onProgress)
        let items = try await session.diagnostics(for: LanguageServerCatalog.standardized(absolute), timeout: 60)
        let header = header(server: session.server, notes: lease.notes + XcodeBuildServer.notes(forRoot: session.root))
        let relative = relativePath(absolute, workspaceRoot: workspaceRoot)
        guard !items.isEmpty else {
            return header + "No problems reported in \(relative)."
        }
        let parsed = parseDiagnostics(items, absolute: absolute)
        let counts = ["error", "warning", "note"].compactMap { kind -> String? in
            let count = parsed.filter { $0.severity == kind }.count
            return count == 0 ? nil : "\(count) \(kind)\(count == 1 ? "" : "s")"
        }
        return header + "\(counts.joined(separator: ", ")) in \(relative):\n"
            + parsed.map { "\(relative):\($0.line):\($0.column): \($0.severity): \($0.message)" }.joined(separator: "\n")
    }

    /// What a server that is *already running* reports for `path` straight after an edit, as text to
    /// append to the edit's tool result — so a model that skips `code_diagnostics` still sees the
    /// error it just introduced. Nil when no server is up for the file, or it does not answer
    /// within `timeout`: this never starts a server or waits for an index, so an edit is never
    /// slowed by more than `timeout`. Errors only; warnings are not worth a turn.
    public static func errorsAfterEdit(
        path: String,
        workspaceRoot: String,
        pool: LanguageServerPool = .shared,
        timeout: TimeInterval = 4,
        limit: Int = 10
    ) async -> String? {
        let absolute = absolutePath(path, workspaceRoot: workspaceRoot)
        guard let session = await pool.runningSession(for: absolute) else { return nil }
        let file = LanguageServerCatalog.standardized(absolute)
        let items: [[String: Any]]
        do {
            items = try await session.diagnostics(for: file, timeout: timeout)
        } catch {
            return nil
        }
        let relative = relativePath(absolute, workspaceRoot: workspaceRoot)
        let errors = parseDiagnostics(items, absolute: absolute).filter { $0.severity == "error" }
        guard !errors.isEmpty else {
            return "\(session.server) reports no errors in \(relative)."
        }
        var lines = errors.prefix(limit).map { "\(relative):\($0.line):\($0.column): error: \($0.message)" }
        if errors.count > limit {
            lines.append("… and \(errors.count - limit) more; code_diagnostics lists them all.")
        }
        let count = "\(errors.count) error\(errors.count == 1 ? "" : "s")"
        return "\(session.server) reports \(count) in \(relative) after this change:\n" + lines.joined(separator: "\n")
    }

    /// LSP diagnostics as 1-based line, character column, severity word and one-line message,
    /// in file order.
    static func parseDiagnostics(
        _ items: [[String: Any]], absolute: String
    ) -> [(line: Int, column: Int, severity: String, message: String)] {
        let lines = (try? String(contentsOfFile: absolute, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        return items.compactMap { item -> (line: Int, column: Int, severity: String, message: String)? in
            guard let start = (item["range"] as? [String: Any])?["start"] as? [String: Any],
                  let line = start["line"] as? Int, let character = start["character"] as? Int,
                  let message = item["message"] as? String else { return nil }
            let lineText = line < lines.count ? lines[line] : ""
            let severity: String
            switch item["severity"] as? Int {
            case 1: severity = "error"
            case 2: severity = "warning"
            default: severity = "note"
            }
            // One line per diagnostic, so the output stays one `path:line:` entry each.
            let flat = message.replacingOccurrences(of: "\n", with: " ")
            return (line + 1, SymbolPosition.characterColumn(utf16Offset: character, in: lineText), severity, flat)
        }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// An outline of the declarations in one file.
    public static func documentSymbols(
        path: String, workspaceRoot: String, pool: LanguageServerPool = .shared
    ) async throws -> String {
        let absolute = absolutePath(path, workspaceRoot: workspaceRoot)
        let lease = try await pool.session(for: absolute, workspaceRoot: workspaceRoot)
        let session = lease.session
        let (uri, _) = try await session.open(LanguageServerCatalog.standardized(absolute))
        let result = try await session.send("textDocument/documentSymbol", ["textDocument": ["uri": uri]])
        let relative = relativePath(absolute, workspaceRoot: workspaceRoot)
        let outline = formatOutline(result)
        let header = header(server: session.server, notes: lease.notes)
        guard !outline.isEmpty else { return header + "No symbols in \(relative)." }
        return header + "Symbols in \(relative) (line: kind name):\n" + outline.joined(separator: "\n")
    }

    public static func callHierarchy(
        _ target: Target, direction: CallDirection = .incoming, limit: Int = 100,
        workspaceRoot: String, pool: LanguageServerPool = .shared, onProgress: ProgressHandler? = nil
    ) async throws -> String {
        let context = try await prepare(target, workspaceRoot: workspaceRoot, pool: pool, onProgress: onProgress)
        let items = (try await context.session.send("textDocument/prepareCallHierarchy", context.positionParams) as? [[String: Any]]) ?? []
        guard !items.isEmpty else {
            return context.header + "\(context.subject) is not something that can be called."
        }
        var entries: [Location] = []
        for item in items {
            let method = direction == .incoming ? "callHierarchy/incomingCalls" : "callHierarchy/outgoingCalls"
            let calls = (try await context.session.send(method, ["item": JSONCopy.fresh(item)], timeout: indexTimeout) as? [[String: Any]]) ?? []
            for call in calls {
                guard let other = (call[direction == .incoming ? "from" : "to"]) as? [String: Any],
                      let name = other["name"] as? String else { continue }
                if direction == .incoming,
                   let uri = other["uri"] as? String,
                   let ranges = call["fromRanges"] as? [[String: Any]], !ranges.isEmpty {
                    // Each call site, not just the caller's declaration.
                    for range in ranges {
                        if var location = Location(uri: uri, range: range) {
                            location.label = name
                            entries.append(location)
                        }
                    }
                } else if let uri = other["uri"] as? String,
                          let range = (other["selectionRange"] ?? other["range"]) as? [String: Any],
                          var location = Location(uri: uri, range: range) {
                    location.label = name
                    entries.append(location)
                }
            }
        }
        entries = Array(Set(entries)).sorted()
        guard !entries.isEmpty else {
            return context.header + (direction == .incoming ? "Nothing calls \(context.subject)." : "\(context.subject) calls nothing the index knows.")
        }
        let shown = Array(entries.prefix(max(1, limit)))
        let title = direction == .incoming
            ? "\(entries.count) call site\(entries.count == 1 ? "" : "s") of \(context.subject) (path:line:column: calling function):"
            : "\(entries.count) function\(entries.count == 1 ? "" : "s") called by \(context.subject) (declared at):"
        var text = context.header + title + "\n"
            + shown.map { "\(relativePath($0.path, workspaceRoot: workspaceRoot)):\($0.line + 1):\($0.character + 1): \($0.label ?? "")" }.joined(separator: "\n")
        if entries.count > shown.count {
            text += "\n… \(entries.count - shown.count) more not shown."
        }
        return text
    }

    // MARK: - Shared preparation

    public struct Context: Sendable {
        public let session: LanguageServerSession
        public let uri: String
        public let position: SymbolPosition.Resolved
        public let subject: String
        public let header: String

        public var positionParams: [String: Any] {
            ["textDocument": ["uri": uri], "position": ["line": position.line, "character": position.character]]
        }
    }

    /// Start or reuse the server, wait for its index, sync the file and find the position.
    private static func prepare(_ target: Target, workspaceRoot: String, pool: LanguageServerPool, onProgress: ProgressHandler?) async throws -> Context {
        let absolute = absolutePath(target.path, workspaceRoot: workspaceRoot)
        let lease = try await pool.session(for: absolute, workspaceRoot: workspaceRoot)
        let session = lease.session
        let file = LanguageServerCatalog.standardized(absolute)
        // tsserver loads a project only once a file in it is open. Waiting first found it idle, and
        // the query then arrived mid-load and got the import line instead of the declaration.
        // Opening again after the wait picks up any edit made since.
        if session.loadsProjectOnOpen { _ = try await session.open(file) }
        try await session.waitUntilIndexed(timeout: indexTimeout, onProgress: onProgress)
        let (uri, text) = try await session.open(file)
        let position = try SymbolPosition.resolve(in: text, line: target.line, symbol: target.symbol, column: target.column)
        let relative = relativePath(absolute, workspaceRoot: workspaceRoot)
        let subject = target.symbol.map { "'\($0)' at \(relative):\(target.line)" } ?? "\(relative):\(target.line):\(target.column ?? 1)"
        return Context(session: session, uri: uri, position: position, subject: subject,
                       header: header(server: session.server, notes: lease.notes + XcodeBuildServer.notes(forRoot: session.root)))
    }

    private static func header(server: String, notes: [String]) -> String {
        (["[\(server)]"] + notes).joined(separator: "\n") + "\n"
    }

    public static func absolutePath(_ path: String, workspaceRoot: String) -> String {
        path.hasPrefix("/") ? path : (workspaceRoot as NSString).appendingPathComponent(path)
    }

    public static func relativePath(_ path: String, workspaceRoot: String) -> String {
        let root = LanguageServerCatalog.standardized(workspaceRoot)
        let full = LanguageServerCatalog.standardized(path)
        return full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : full
    }

    // MARK: - Parsing

    public struct Location: Hashable, Comparable {
        public var path: String
        /// Zero-based, as LSP sends them.
        public var line: Int
        public var character: Int
        public var label: String?

        public init?(uri: String, range: [String: Any]) {
            guard let url = URL(string: uri), url.isFileURL,
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int, let character = start["character"] as? Int else { return nil }
            self.path = LanguageServerCatalog.standardized(url.path)
            self.line = line
            self.character = character
        }

        public static func < (lhs: Location, rhs: Location) -> Bool {
            (lhs.path, lhs.line, lhs.character) < (rhs.path, rhs.line, rhs.character)
        }
    }

    /// `Location`, `[Location]` or `[LocationLink]` — servers use all three.
    public static func parseLocations(_ value: Any?) -> [Location] {
        let items: [[String: Any]]
        if let one = value as? [String: Any] {
            items = [one]
        } else {
            items = (value as? [[String: Any]]) ?? []
        }
        var seen = Set<Location>()
        return items.compactMap { item -> Location? in
            if let uri = item["uri"] as? String, let range = item["range"] as? [String: Any] {
                return Location(uri: uri, range: range)
            }
            if let uri = item["targetUri"] as? String,
               let range = (item["targetSelectionRange"] ?? item["targetRange"]) as? [String: Any] {
                return Location(uri: uri, range: range)
            }
            return nil
        }.filter { seen.insert($0).inserted }
    }

    /// `path:line:column: source line`, reading each file once.
    public static func formatLocations(_ locations: [Location], workspaceRoot: String) -> [String] {
        var files: [String: [String]] = [:]
        return locations.map { location in
            let lines = files[location.path] ?? {
                let loaded = (try? String(contentsOfFile: location.path, encoding: .utf8))?.components(separatedBy: "\n") ?? []
                files[location.path] = loaded
                return loaded
            }()
            let lineText = location.line < lines.count ? lines[location.line] : ""
            let column = SymbolPosition.characterColumn(utf16Offset: location.character, in: lineText)
            let source = lineText.trimmingCharacters(in: .whitespaces)
            let clipped = source.count > 160 ? String(source.prefix(160)) + "…" : source
            return "\(relativePath(location.path, workspaceRoot: workspaceRoot)):\(location.line + 1):\(column): \(clipped)"
        }
    }

    public static func hoverText(_ value: Any?) -> String {
        guard let hover = value as? [String: Any] else { return "" }
        func text(_ content: Any?) -> String {
            if let string = content as? String { return string }
            if let markup = content as? [String: Any] {
                if let value = markup["value"] as? String {
                    if let language = markup["language"] as? String { return "```\(language)\n\(value)\n```" }
                    return value
                }
            }
            if let array = content as? [Any] {
                return array.map(text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            return ""
        }
        return text(hover["contents"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let symbolKinds = [
        1: "file", 2: "module", 3: "namespace", 4: "package", 5: "class", 6: "method", 7: "property",
        8: "field", 9: "constructor", 10: "enum", 11: "interface", 12: "function", 13: "variable",
        14: "constant", 15: "string", 16: "number", 17: "boolean", 18: "array", 19: "object",
        20: "key", 21: "null", 22: "enum case", 23: "struct", 24: "event", 25: "operator", 26: "type parameter",
    ]

    /// `DocumentSymbol` trees are indented by depth; flat `SymbolInformation` lists show their container.
    public static func formatOutline(_ value: Any?) -> [String] {
        guard let items = value as? [[String: Any]] else { return [] }
        var lines: [String] = []
        func walk(_ symbols: [[String: Any]], depth: Int) {
            for symbol in symbols {
                guard let name = symbol["name"] as? String else { continue }
                let kind = symbolKinds[(symbol["kind"] as? Int) ?? 0] ?? "symbol"
                let range = (symbol["selectionRange"] ?? symbol["range"]) as? [String: Any]
                    ?? (symbol["location"] as? [String: Any])?["range"] as? [String: Any]
                let line = ((range?["start"] as? [String: Any])?["line"] as? Int).map { $0 + 1 }
                var entry = String(repeating: "  ", count: depth) + "\(line.map(String.init) ?? "?"): \(kind) \(name)"
                if let detail = symbol["detail"] as? String, !detail.isEmpty, detail != name {
                    entry += " — \(detail)"
                } else if let container = symbol["containerName"] as? String, !container.isEmpty {
                    entry += " (in \(container))"
                }
                lines.append(entry)
                if let children = symbol["children"] as? [[String: Any]] {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(items, depth: 0)
        return lines
    }
}
