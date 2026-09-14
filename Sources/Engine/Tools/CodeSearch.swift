import Foundation

/// Literal code search: find files by path pattern, and find lines by regex.
///
/// Semantic search answers "what is this about"; an agent editing code needs "where exactly is
/// this symbol". Those are different jobs, and only the second can be trusted to be exhaustive.
public enum CodeSearch {

    /// Directories never worth walking for source search. Skipping them at the directory level
    /// (rather than filtering results) is what keeps a repo-wide glob fast.
    public static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "node_modules", ".next", "dist",
        "Pods", "Carthage", ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache",
        ".gradle", "target", "vendor", ".idea", ".vscode", ".tox", "coverage",
    ]

    public static func isIgnored(directory name: String) -> Bool {
        ignoredDirectories.contains(name) || (name.hasPrefix(".") && name != "." && name != "..")
    }

    // MARK: - Glob matching

    /// Match a relative path against a glob pattern.
    ///
    /// Supports `*` (any run of characters within one path segment), `**` (any number of
    /// segments, including none), `?` (one character), and character classes `[abc]` / `[a-z]`.
    /// A pattern with no `/` matches against the basename, so `*.swift` finds files at any depth.
    public static func matches(path: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let subject = trimmed.contains("/") ? path : (path as NSString).lastPathComponent
        return matchSegments(
            subject: subject.split(separator: "/", omittingEmptySubsequences: false).map(String.init),
            pattern: trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        )
    }

    private static func matchSegments(subject: [String], pattern: [String]) -> Bool {
        // Both exhausted: a match. Pattern exhausted first: no.
        if pattern.isEmpty { return subject.isEmpty }

        if pattern[0] == "**" {
            let rest = Array(pattern.dropFirst())
            // `**` may consume zero or more leading segments.
            if rest.isEmpty { return true }
            for skip in 0...subject.count {
                if matchSegments(subject: Array(subject.dropFirst(skip)), pattern: rest) {
                    return true
                }
            }
            return false
        }

        guard let head = subject.first else { return false }
        guard matchSegment(head, pattern: pattern[0]) else { return false }
        return matchSegments(subject: Array(subject.dropFirst()), pattern: Array(pattern.dropFirst()))
    }

    /// Wildcard match within a single path segment.
    static func matchSegment(_ text: String, pattern: String) -> Bool {
        let t = Array(text)
        let p = Array(pattern)
        var ti = 0
        var pi = 0
        var starPattern = -1
        var starText = 0

        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                starPattern = pi
                starText = ti
                pi += 1
            } else if pi < p.count, p[pi] == "?" {
                ti += 1
                pi += 1
            } else if pi < p.count, p[pi] == "[" {
                guard let close = p[pi...].firstIndex(of: "]"), close > pi + 1 else { return false }
                let set = Array(p[(pi + 1)..<close])
                if matchClass(t[ti], set) {
                    ti += 1
                    pi = close + 1
                } else if starPattern >= 0 {
                    pi = starPattern + 1
                    starText += 1
                    ti = starText
                } else {
                    return false
                }
            } else if pi < p.count, p[pi] == t[ti] {
                ti += 1
                pi += 1
            } else if starPattern >= 0 {
                // Backtrack: let the last `*` swallow one more character.
                pi = starPattern + 1
                starText += 1
                ti = starText
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func matchClass(_ char: Character, _ set: [Character]) -> Bool {
        var negated = false
        var body = set
        if body.first == "!" || body.first == "^" {
            negated = true
            body = Array(body.dropFirst())
        }
        var hit = false
        var i = 0
        while i < body.count {
            if i + 2 < body.count, body[i + 1] == "-" {
                if char >= body[i], char <= body[i + 2] { hit = true }
                i += 3
            } else {
                if char == body[i] { hit = true }
                i += 1
            }
        }
        return negated ? !hit : hit
    }

    // MARK: - File enumeration

    public struct GlobResult: Sendable {
        public var paths: [String]
        public var truncated: Bool
        public var scanned: Int
    }

    /// Files under `root` whose path relative to `root` matches `pattern`, newest first.
    public static func glob(
        pattern: String,
        root: String,
        limit: Int = 200,
        fileManager: FileManager = .default
    ) -> GlobResult {
        var matched: [(path: String, modified: Date)] = []
        var scanned = 0

        // Resolve symlinks on both sides before comparing. On macOS the temp directory is
        // /var/... while the enumerator reports /private/var/..., so an unresolved prefix strip
        // silently yields absolute paths that match no relative pattern.
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return GlobResult(paths: [], truncated: false, scanned: 0)
        }

        let rootPath = rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if isIgnored(directory: url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            scanned += 1
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(rootPrefix) else { continue }
            let relative = String(full.dropFirst(rootPrefix.count))
            if matches(path: relative, pattern: pattern) {
                matched.append((relative, values?.contentModificationDate ?? .distantPast))
            }
        }

        matched.sort { $0.modified > $1.modified }
        let truncated = matched.count > limit
        return GlobResult(
            paths: matched.prefix(limit).map(\.path),
            truncated: truncated,
            scanned: scanned
        )
    }

    // MARK: - Content search

    public struct Match: Sendable {
        public var path: String
        public var line: Int
        public var text: String
    }

    public struct GrepResult: Sendable {
        public var matches: [Match]
        public var truncated: Bool
        public var filesSearched: Int
    }

    /// Lines matching `pattern` (an ICU regex) under `root`.
    ///
    /// Pure Swift rather than shelling out to ripgrep: the result is identical on every machine,
    /// needs no external binary, and cannot be defeated by a shell-approval prompt mid-turn.
    public static func grep(
        pattern: String,
        root: String,
        include: String? = nil,
        caseInsensitive: Bool = false,
        limit: Int = 100,
        maxLineLength: Int = 400,
        fileManager: FileManager = .default
    ) throws -> GrepResult {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        let regex = try NSRegularExpression(pattern: pattern, options: options)

        let candidates = include.map { glob(pattern: $0, root: root, limit: 5_000, fileManager: fileManager).paths }
            ?? glob(pattern: "**", root: root, limit: 5_000, fileManager: fileManager).paths

        var matches: [Match] = []
        var filesSearched = 0
        var truncated = false
        // Same symlink resolution as `glob`, so the paths it returns can be reopened here.
        let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for relative in candidates {
            if matches.count >= limit {
                truncated = true
                break
            }
            let full = rootPrefix + relative
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            filesSearched += 1
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                guard regex.firstMatch(in: text, range: range) != nil else { continue }
                if matches.count >= limit {
                    truncated = true
                    break
                }
                let shown = text.count > maxLineLength
                    ? String(text.prefix(maxLineLength)) + "…"
                    : text
                matches.append(Match(path: relative, line: index + 1, text: shown))
            }
        }

        return GrepResult(matches: matches, truncated: truncated, filesSearched: filesSearched)
    }

    /// Render matches the way a coding agent can act on: `path:line: text`.
    public static func format(_ result: GrepResult, pattern: String) -> String {
        guard !result.matches.isEmpty else {
            return "No matches for /\(pattern)/ in \(result.filesSearched) files."
        }
        var lines = result.matches.map { "\($0.path):\($0.line): \($0.text)" }
        if result.truncated {
            lines.append("… results truncated. Narrow the pattern or pass `include` to scope the search.")
        }
        return lines.joined(separator: "\n")
    }
}
