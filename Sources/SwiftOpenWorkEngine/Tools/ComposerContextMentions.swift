import Foundation

/// Resolves `@path`, `@path:line` and `@path:first-last` tokens in the composer into workspace context the agent can read.
public enum ComposerContextMentions {

    public struct Suggestion: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public var path: String
        public var isDirectory: Bool
    }

    public struct ParsedMention: Equatable, Sendable {
        public var pathToken: String
        public var line: Int?
        /// Last line of a `first-last` range; nil for a single line.
        public var endLine: Int?

        public init(pathToken: String, line: Int?, endLine: Int? = nil) {
            self.pathToken = pathToken
            self.line = line
            self.endLine = endLine
        }
    }

    /// `@Sources/Foo.swift`, `@Sources/Foo.swift:42` or `@Sources/Foo.swift:42-60`
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/])@([A-Za-z0-9_./\-]+)(?::(\d+)(?:-(\d+))?)?"#
    )

    /// Lines a range mention attaches at most; longer ranges are cut and say so.
    public static let maxRangeLines = 400

    public static func parseMentionToken(_ token: String) -> ParsedMention {
        if let colon = token.lastIndex(of: ":") {
            let suffix = token[token.index(after: colon)...]
            let parts = suffix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if let line = parts.first.flatMap({ Int($0) }), line > 0 {
                let path = String(token[..<colon])
                if parts.count == 1 { return ParsedMention(pathToken: path, line: line) }
                if let end = Int(parts[1]), end >= line {
                    return ParsedMention(pathToken: path, line: line, endLine: end == line ? nil : end)
                }
            }
        }
        return ParsedMention(pathToken: token, line: nil)
    }

    public static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let after = text[text.index(after: at)...]
        if after.contains(where: { $0.isWhitespace || $0 == "\n" }) { return nil }
        // Suggestions are path-only; strip a trailing :line or :first-last while typing.
        let raw = String(after)
        if let colon = raw.lastIndex(of: ":"),
           raw[raw.index(after: colon)...].allSatisfy({ $0.isNumber || $0 == "-" }) {
            return String(raw[..<colon])
        }
        return raw
    }

    public static func suggestions(query: String, workspacePath: String, limit: Int = 12) -> [Suggestion] {
        guard !workspacePath.isEmpty else { return [] }
        let root = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().path
        let q = query.lowercased()
        let paths = CodeSearch.glob(pattern: "**", root: root, limit: 4_000).paths
        var scored: [(Int, Suggestion)] = []
        for relative in paths {
            let name = (relative as NSString).lastPathComponent.lowercased()
            let fullLower = relative.lowercased()
            guard q.isEmpty || name.hasPrefix(q) || fullLower.contains(q) else { continue }
            let full = (root as NSString).appendingPathComponent(relative)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            let rank = name.hasPrefix(q) ? 0 : 1
            scored.append((rank, Suggestion(path: relative, isDirectory: isDir.boolValue)))
            if scored.count >= limit * 3 { break }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.path.count < rhs.1.path.count
            }
            .prefix(limit)
            .map(\.1)
    }

    /// Expand mentions into an optional context block appended for the model.
    public static func enrich(
        text: String,
        workspacePath: String,
        maxFiles: Int = 6,
        maxCharsPerFile: Int = 4_000,
        contextRadius: Int = 18
    ) -> (userVisible: String, modelText: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !workspacePath.isEmpty else {
            return (trimmed, trimmed)
        }

        let root = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().path
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = mentionPattern.matches(in: trimmed, range: range)

        var blocks: [String] = []
        var seen = Set<String>()
        for match in matches.prefix(maxFiles) {
            guard let pathRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let pathToken = String(trimmed[pathRange])
            let line: Int? = {
                guard match.numberOfRanges > 2,
                      match.range(at: 2).location != NSNotFound,
                      let lineRange = Range(match.range(at: 2), in: trimmed) else { return nil }
                return Int(trimmed[lineRange])
            }()
            let endLine: Int? = {
                guard let line, match.numberOfRanges > 3,
                      match.range(at: 3).location != NSNotFound,
                      let endRange = Range(match.range(at: 3), in: trimmed),
                      let end = Int(trimmed[endRange]), end > line else { return nil }
                return end
            }()
            let seenKey = line.map { l in endLine.map { "\(pathToken):\(l)-\($0)" } ?? "\(pathToken):\(l)" } ?? pathToken
            guard let resolved = resolve(token: pathToken, root: root),
                  seen.insert(seenKey).inserted else {
                continue
            }
            if resolved.isDirectory {
                let listing = (try? FileManager.default.contentsOfDirectory(atPath: resolved.absolute)) ?? []
                let shown = listing.filter { !$0.hasPrefix(".") }.sorted().prefix(40).joined(separator: "\n")
                blocks.append("#### Directory `\(resolved.relative)`\n```\n\(shown)\n```")
            } else if let content = try? String(contentsOfFile: resolved.absolute, encoding: .utf8) {
                if let line, let endLine {
                    blocks.append(rangeExcerpt(
                        relative: resolved.relative,
                        content: content,
                        first: line,
                        last: endLine
                    ))
                } else if let line {
                    blocks.append(focusedExcerpt(
                        relative: resolved.relative,
                        content: content,
                        line: line,
                        radius: contextRadius
                    ))
                } else {
                    let clipped = content.count > maxCharsPerFile
                        ? String(content.prefix(maxCharsPerFile)) + "\n… [clipped]"
                        : content
                    blocks.append("#### File `\(resolved.relative)`\n```\n\(clipped)\n```")
                }
            }
        }

        guard !blocks.isEmpty else { return (trimmed, trimmed) }
        let modelText = trimmed + "\n\n### Attached context\n" + blocks.joined(separator: "\n\n")
        return (trimmed, modelText)
    }

    /// Numbered window around `line` (1-based) so the model lands on the diagnostic target.
    public static func focusedExcerpt(
        relative: String,
        content: String,
        line: Int,
        radius: Int = 18
    ) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else {
            return "#### File `\(relative)` (line \(line))\n```\n```"
        }
        let target = min(max(line, 1), lines.count)
        let start = max(1, target - radius)
        let end = min(lines.count, target + radius)
        var body: [String] = []
        for n in start...end {
            let mark = n == target ? ">>>" : "   "
            body.append("\(mark) \(n)| \(lines[n - 1])")
        }
        var header = "#### File `\(relative)` — focus line \(target)"
        if start > 1 || end < lines.count {
            header += " (showing \(start)–\(end) of \(lines.count))"
        }
        return header + "\n```\n" + body.joined(separator: "\n") + "\n```"
    }

    /// Numbered lines `first...last` (1-based), each marked, so the model sees exactly what was
    /// selected. Ranges past `maxRangeLines` are cut and the header says where.
    public static func rangeExcerpt(
        relative: String,
        content: String,
        first: Int,
        last: Int
    ) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else {
            return "#### File `\(relative)` (lines \(first)–\(last))\n```\n```"
        }
        let start = min(max(first, 1), lines.count)
        let requestedEnd = min(max(last, start), lines.count)
        let end = min(requestedEnd, start + maxRangeLines - 1)
        let body = (start...end).map { ">>> \($0)| \(lines[$0 - 1])" }
        var header = "#### File `\(relative)` — selected lines \(start)–\(requestedEnd) of \(lines.count)"
        if end < requestedEnd {
            header += " (showing the first \(maxRangeLines))"
        }
        return header + "\n```\n" + body.joined(separator: "\n") + "\n```"
    }

    private static func resolve(token: String, root: String) -> (relative: String, absolute: String, isDirectory: Bool)? {
        let pathToken = parseMentionToken(token).pathToken
        let candidates: [String] = {
            if pathToken.hasPrefix("/") {
                return [pathToken]
            }
            let direct = (root as NSString).appendingPathComponent(pathToken)
            if FileManager.default.fileExists(atPath: direct) { return [direct] }
            let paths = CodeSearch.glob(pattern: "**/\(pathToken)", root: root, limit: 20).paths
            if !paths.isEmpty {
                return paths.map { (root as NSString).appendingPathComponent($0) }
            }
            let byName = CodeSearch.glob(pattern: "**", root: root, limit: 3_000).paths
                .filter { ($0 as NSString).lastPathComponent.compare(pathToken, options: .caseInsensitive) == .orderedSame }
            return byName.map { (root as NSString).appendingPathComponent($0) }
        }()

        guard let absolute = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir)
        let relative: String = {
            if absolute.hasPrefix(root) {
                let drop = root.hasSuffix("/") ? root.count : root.count + 1
                return String(absolute.dropFirst(min(drop, absolute.count)))
            }
            return (absolute as NSString).lastPathComponent
        }()
        return (relative, absolute, isDir.boolValue)
    }
}
