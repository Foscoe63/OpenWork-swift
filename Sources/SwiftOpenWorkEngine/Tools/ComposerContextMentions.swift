import Foundation

/// Resolves `@path` / `@path:line` tokens in the composer into workspace context the agent can read.
public enum ComposerContextMentions {

    public struct Suggestion: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public var path: String
        public var isDirectory: Bool
    }

    public struct ParsedMention: Equatable, Sendable {
        public var pathToken: String
        public var line: Int?
    }

    /// `@Sources/Foo.swift` or `@Sources/Foo.swift:42`
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/])@([A-Za-z0-9_./\-]+)(?::(\d+))?"#
    )

    public static func parseMentionToken(_ token: String) -> ParsedMention {
        if let colon = token.lastIndex(of: ":"),
           colon < token.endIndex,
           let line = Int(token[token.index(after: colon)...]),
           line > 0 {
            return ParsedMention(pathToken: String(token[..<colon]), line: line)
        }
        return ParsedMention(pathToken: token, line: nil)
    }

    public static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let after = text[text.index(after: at)...]
        if after.contains(where: { $0.isWhitespace || $0 == "\n" }) { return nil }
        // Suggestions are path-only; strip a trailing :line while typing.
        let raw = String(after)
        if let colon = raw.lastIndex(of: ":"),
           raw[raw.index(after: colon)...].allSatisfy(\.isNumber) {
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
            let seenKey = line.map { "\(pathToken):\($0)" } ?? pathToken
            guard let resolved = resolve(token: pathToken, root: root),
                  seen.insert(seenKey).inserted else {
                continue
            }
            if resolved.isDirectory {
                let listing = (try? FileManager.default.contentsOfDirectory(atPath: resolved.absolute)) ?? []
                let shown = listing.filter { !$0.hasPrefix(".") }.sorted().prefix(40).joined(separator: "\n")
                blocks.append("#### Directory `\(resolved.relative)`\n```\n\(shown)\n```")
            } else if let content = try? String(contentsOfFile: resolved.absolute, encoding: .utf8) {
                if let line {
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
