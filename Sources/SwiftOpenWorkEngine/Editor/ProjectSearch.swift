import Foundation

/// Find (and replace) across the workspace, for the editor's search panel.
///
/// `grep` serves the agent: line numbers, a result cap, text it can quote. A person searching needs
/// more — where on the line each match is, so clicking selects it; the unsaved text of files open in
/// the editor rather than the stale copy on disk; and a search that stops the moment the query
/// changes. This is that search. Pure apart from reading files, for tests.
public enum ProjectSearch {

    public struct Options: Equatable, Sendable {
        public var query: String
        public var isRegex = false
        public var caseSensitive = false
        public var wholeWord = false
        /// Glob patterns separated by commas, e.g. `*.swift, Sources/**`. Empty means everything.
        public var include = ""
        public var exclude = ""

        public init(query: String, isRegex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false, include: String = "", exclude: String = "") {
            self.query = query
            self.isRegex = isRegex
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
            self.include = include
            self.exclude = exclude
        }
    }

    public struct LineMatch: Equatable, Sendable, Identifiable {
        public var line: Int
        /// UTF-16 offset of the match within its line.
        public var column: Int
        public var length: Int
        /// The line, trimmed and shortened around the match for display.
        public var preview: String
        /// The match's range within `preview`.
        public var previewRange: NSRange
        public var id: String { "\(line):\(column)" }
    }

    public struct FileResult: Equatable, Sendable, Identifiable {
        /// Relative to the workspace root.
        public var path: String
        public var matches: [LineMatch]
        /// Searched from the editor's unsaved text rather than the file on disk.
        public var fromOpenEditor: Bool
        public var id: String { path }
    }

    public struct Result: Equatable, Sendable {
        public var files: [FileResult]
        public var totalMatches: Int
        public var filesSearched: Int
        /// Stopped at `matchLimit`; some matches are not shown.
        public var truncated: Bool

        public static let empty = Result(files: [], totalMatches: 0, filesSearched: 0, truncated: false)
    }

    public enum SearchError: LocalizedError, Equatable {
        case invalidPattern(String)
        public var errorDescription: String? {
            switch self {
            case .invalidPattern(let why): return "Invalid regular expression: \(why)"
            }
        }
    }

    public static let matchLimit = 5_000
    public static let maxFileBytes = 2 * 1024 * 1024

    /// The expression `options` searches with.
    public static func regex(for options: Options) throws -> NSRegularExpression {
        var pattern = options.isRegex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        do {
            return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw SearchError.invalidPattern((error as NSError).localizedDescription)
        }
    }

    /// Whether a relative path passes the include and exclude globs.
    public static func accepts(path: String, include: String, exclude: String) -> Bool {
        func patterns(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let includes = patterns(include)
        func underFolder(_ pattern: String) -> Bool {
            // `Sources`, `Sources/` and `Sources/**` all mean "inside Sources".
            let folder = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/*"))
            return !folder.isEmpty && !folder.contains("*") && path.hasPrefix(folder + "/")
        }
        if !includes.isEmpty, !includes.contains(where: { CodeSearch.matches(path: path, pattern: $0) || underFolder($0) }) {
            return false
        }
        return !patterns(exclude).contains { CodeSearch.matches(path: path, pattern: $0) }
    }

    /// Matches in one text. Pure.
    public static func matches(in text: String, regex: NSRegularExpression, limit: Int = matchLimit) -> [LineMatch] {
        var found: [LineMatch] = []
        let ns = text as NSString
        var lineNumber = 1
        var lineStart = 0
        var searchFrom = 0
        let length = ns.length
        for match in regex.matches(in: text, range: NSRange(location: 0, length: length)) {
            guard match.range.length > 0 else { continue }
            // Advance the line counter to the match.
            while searchFrom < match.range.location {
                if ns.character(at: searchFrom) == 10 {
                    lineNumber += 1
                    lineStart = searchFrom + 1
                }
                searchFrom += 1
            }
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            var lineEnd = NSMaxRange(lineRange)
            if lineEnd > lineRange.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
            let column = match.range.location - lineStart
            // A match that runs past the line end is shown up to it.
            let visibleLength = min(match.range.length, max(0, lineEnd - match.range.location))
            let lineText = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let (preview, previewRange) = makePreview(line: lineText, column: column, length: visibleLength)
            found.append(LineMatch(line: lineNumber, column: column, length: match.range.length, preview: preview, previewRange: previewRange))
            if found.count >= limit { break }
        }
        return found
    }

    /// The line around a match, leading whitespace dropped and long lines cut to a window.
    public static func makePreview(line: String, column: Int, length: Int) -> (String, NSRange) {
        let ns = line as NSString
        var firstText = 0
        while firstText < ns.length, firstText < column, ns.character(at: firstText) == 32 || ns.character(at: firstText) == 9 {
            firstText += 1
        }
        // Keep up to 40 characters of context before the match, and cut the rest with an ellipsis.
        let start = max(firstText, column - 40)
        let end = min(ns.length, max(column + length + 80, start + 140))
        let body = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
        let lead = start > firstText ? "…" : ""
        let trail = end < ns.length ? "…" : ""
        let location = (lead as NSString).length + (column - start)
        let clipped = max(0, min(length, (body as NSString).length - (column - start)))
        return (lead + body + trail, NSRange(location: location, length: clipped))
    }

    /// Search every file under `root`.
    ///
    /// `openDocuments` maps absolute paths to the editor's current text; those files are searched
    /// as the person sees them. Checks for cancellation between files.
    public static func search(
        _ options: Options,
        root: String,
        openDocuments: [String: String] = [:],
        fileManager: FileManager = .default
    ) throws -> Result {
        guard !options.query.isEmpty else { return .empty }
        let regex = try regex(for: options)
        let listing = CodeSearch.glob(pattern: "**", root: root, limit: 20_000, fileManager: fileManager)
        let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        var files: [FileResult] = []
        var total = 0
        var searched = 0
        var truncated = listing.truncated

        for relative in listing.paths where accepts(path: relative, include: options.include, exclude: options.exclude) {
            if Task.isCancelled { break }
            let full = prefix + relative
            let text: String
            let fromEditor: Bool
            if let open = openDocuments[full] {
                text = open
                fromEditor = true
            } else {
                guard let size = (try? fileManager.attributesOfItem(atPath: full)[.size]) as? Int, size <= maxFileBytes,
                      let data = fileManager.contents(atPath: full),
                      !data.prefix(8_000).contains(0),
                      let decoded = String(data: data, encoding: .utf8) else { continue }
                text = decoded.contains("\r") ? EditorText.normalizeNewlines(decoded) : decoded
                fromEditor = false
            }
            searched += 1
            let found = matches(in: text, regex: regex, limit: matchLimit - total)
            guard !found.isEmpty else { continue }
            files.append(FileResult(path: relative, matches: found, fromOpenEditor: fromEditor))
            total += found.count
            if total >= matchLimit {
                truncated = true
                break
            }
        }
        return Result(files: files, totalMatches: total, filesSearched: searched, truncated: truncated)
    }

    /// `text` with every match replaced, and how many were. Pure.
    ///
    /// In regex mode `$1`-style references work; in literal mode the replacement is inserted
    /// exactly as typed, so a `$` in it stays a `$`.
    public static func replacing(in text: String, options: Options, with replacement: String) throws -> (text: String, count: Int) {
        let regex = try regex(for: options)
        let range = NSRange(location: 0, length: (text as NSString).length)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        let template = options.isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return (regex.stringByReplacingMatches(in: text, range: range, withTemplate: template), count)
    }
}
