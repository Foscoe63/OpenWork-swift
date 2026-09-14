import Foundation

/// Turns build and test output into something an agent can act on.
///
/// A failing `swift build` prints thousands of lines, of which perhaps three matter. Handing the
/// raw tail to the model wastes context and buries the actual errors — it can see that something
/// failed but not reliably what or where. This extracts the diagnostics and reports them as
/// `file:line: message`, the same shape `grep` returns, so the next step is to open that line.
public enum BuildDiagnostics {

    public enum Severity: String, Sendable, Comparable {
        case error
        case warning
        case note

        /// Errors sort first — they are what blocks the build.
        private var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .note: return 2
            }
        }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public struct Diagnostic: Sendable, Equatable {
        public var file: String
        public var line: Int
        public var column: Int?
        public var severity: Severity
        public var message: String

        public init(file: String, line: Int, column: Int? = nil, severity: Severity, message: String) {
            self.file = file
            self.line = line
            self.column = column
            self.severity = severity
            self.message = message
        }

        public var display: String {
            let where_ = column.map { "\(file):\(line):\($0)" } ?? "\(file):\(line)"
            return "\(where_): \(severity.rawValue): \(message)"
        }
    }

    /// `/path/File.swift:12:5: error: message` — Swift, clang, and xcodebuild all emit this.
    private static let compilerPattern = try? NSRegularExpression(
        pattern: #"^(.+?):(\d+):(?:(\d+):)?\s*(error|warning|note):\s*(.+)$"#
    )

    /// XCTest failures: `/path/FileTests.swift:42: error: -[Suite test] : XCTAssertEqual failed…`
    /// The column is absent, and the message carries the test identity.
    private static let xctestPattern = try? NSRegularExpression(
        pattern: #"^(.+?):(\d+):\s*error:\s*(-\[.+?\].*)$"#
    )

    /// swift-testing: `✘ Test "name" recorded an issue at File.swift:10:5: message`
    private static let swiftTestingPattern = try? NSRegularExpression(
        pattern: #"recorded an issue at (.+?):(\d+):(?:(\d+):)?\s*(.+)$"#
    )

    /// Parse diagnostics out of combined stdout/stderr, de-duplicated and ordered by severity.
    public static func parse(_ output: String, relativeTo root: String = "") -> [Diagnostic] {
        var found: [Diagnostic] = []
        var seen = Set<String>()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let diagnostic = parseLine(line, relativeTo: root) else { continue }
            // The same error is reported once per target that pulls the file in.
            let key = "\(diagnostic.file):\(diagnostic.line):\(diagnostic.severity.rawValue):\(diagnostic.message)"
            guard seen.insert(key).inserted else { continue }
            found.append(diagnostic)
        }

        return found.sorted {
            $0.severity == $1.severity
                ? ($0.file == $1.file ? $0.line < $1.line : $0.file < $1.file)
                : $0.severity < $1.severity
        }
    }

    static func parseLine(_ line: String, relativeTo root: String = "") -> Diagnostic? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        // swift-testing first: its line also contains a colon-separated location that the
        // compiler pattern would misread as a message.
        if let regex = swiftTestingPattern, let m = regex.firstMatch(in: line, range: range) {
            guard let file = group(m, 1, in: line), let lineNo = group(m, 2, in: line).flatMap(Int.init) else { return nil }
            return Diagnostic(
                file: relativise(file, root: root),
                line: lineNo,
                column: group(m, 3, in: line).flatMap(Int.init),
                severity: .error,
                message: (group(m, 4, in: line) ?? "test failed").trimmingCharacters(in: .whitespaces)
            )
        }

        if let regex = xctestPattern, let m = regex.firstMatch(in: line, range: range) {
            guard let file = group(m, 1, in: line), let lineNo = group(m, 2, in: line).flatMap(Int.init) else { return nil }
            return Diagnostic(
                file: relativise(file, root: root),
                line: lineNo,
                severity: .error,
                message: (group(m, 3, in: line) ?? "").trimmingCharacters(in: .whitespaces)
            )
        }

        if let regex = compilerPattern, let m = regex.firstMatch(in: line, range: range) {
            guard let file = group(m, 1, in: line),
                  let lineNo = group(m, 2, in: line).flatMap(Int.init),
                  let severityText = group(m, 4, in: line),
                  let severity = Severity(rawValue: severityText) else { return nil }
            // Ignore lines where the "file" is obviously prose rather than a path.
            guard file.contains("/") || file.contains(".") else { return nil }
            return Diagnostic(
                file: relativise(file, root: root),
                line: lineNo,
                column: group(m, 3, in: line).flatMap(Int.init),
                severity: severity,
                message: (group(m, 5, in: line) ?? "").trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    private static func relativise(_ path: String, root: String) -> String {
        guard !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: - Reporting

    /// Render a result the model can act on: verdict first, then errors, then a bounded tail.
    public static func summarize(
        command: String,
        exitCode: Int32,
        output: String,
        root: String = "",
        maxDiagnostics: Int = 25,
        tailLines: Int = 20
    ) -> String {
        let diagnostics = parse(output, relativeTo: root)
        let errors = diagnostics.filter { $0.severity == .error }
        let warnings = diagnostics.filter { $0.severity == .warning }

        var lines: [String] = []
        if exitCode == 0 {
            lines.append("`\(command)` succeeded." + (warnings.isEmpty ? "" : " \(warnings.count) warning(s)."))
        } else {
            lines.append("`\(command)` failed (exit \(exitCode)) with \(errors.count) error(s).")
        }

        if !errors.isEmpty {
            lines.append("")
            for diagnostic in errors.prefix(maxDiagnostics) {
                lines.append("  " + diagnostic.display)
            }
            if errors.count > maxDiagnostics {
                lines.append("  … \(errors.count - maxDiagnostics) more error(s).")
            }
        }

        // Some failures produce no parseable diagnostic at all — a linker error, a crashed
        // process, a missing tool. The tail is the only thing that explains those.
        if errors.isEmpty && exitCode != 0 {
            let tail = output.split(separator: "\n").suffix(tailLines).joined(separator: "\n")
            lines.append("")
            lines.append("No file-level diagnostics were parsed. Last \(tailLines) lines:")
            lines.append(tail)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Command selection

    public enum Action: String, Sendable { case build, test }

    /// The command to run for a project, chosen from the markers `WorkspaceContext` detects.
    ///
    /// Returns nil rather than guessing when the project type is unknown — a wrong build command
    /// produces a confusing failure that looks like a code problem.
    public static func command(forProjectKinds kinds: [String], action: Action) -> String? {
        func has(_ needle: String) -> Bool { kinds.contains { $0.localizedCaseInsensitiveContains(needle) } }

        if has("Swift package") {
            return action == .build ? "swift build" : "swift test"
        }
        if has("Cargo") || has("Rust") {
            return action == .build ? "cargo build" : "cargo test"
        }
        if has("Go module") {
            return action == .build ? "go build ./..." : "go test ./..."
        }
        if has("Node") {
            return action == .build ? "npm run build" : "npm test"
        }
        if has("Python") {
            return action == .build ? nil : "python3 -m pytest"
        }
        if has("Gradle") {
            return action == .build ? "./gradlew build" : "./gradlew test"
        }
        if has("Maven") {
            return action == .build ? "mvn -q compile" : "mvn -q test"
        }
        if has("Make") {
            return action == .build ? "make" : "make test"
        }
        return nil
    }
}
