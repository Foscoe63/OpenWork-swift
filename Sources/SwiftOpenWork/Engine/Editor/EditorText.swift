import Foundation

/// Text rules the editor applies, kept free of AppKit so they can be tested as plain values.
public enum EditorText {

    // MARK: - Line endings

    public enum LineEnding: String, Sendable {
        case lf = "LF"
        case crlf = "CRLF"

        public var sequence: String { self == .lf ? "\n" : "\r\n" }
    }

    /// The file's line ending, by majority. A file the editor opens and saves must come back with
    /// the endings it had — silently converting a CRLF file to LF turns a one-line edit into a diff
    /// of every line, which is exactly the noise a review needs not to have.
    public static func detectLineEnding(_ text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var previousWasCR = false
        for unit in text.utf16 {
            if unit == 10 {
                if previousWasCR { crlf += 1 } else { lf += 1 }
            }
            previousWasCR = unit == 13
        }
        return crlf > lf ? .crlf : .lf
    }

    /// Editing works in `\n`; the file's own endings are restored on save.
    public static func normalizeNewlines(_ text: String) -> String {
        // Checked on UTF-16: to `String`, "\r\n" is one Character, so `contains("\r")` is false
        // for exactly the files this exists to handle.
        guard text.utf16.contains(13) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func restoreLineEndings(_ text: String, to ending: LineEnding) -> String {
        ending == .lf ? text : text.replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: - Indentation

    public enum Indentation: Equatable, Sendable {
        case tabs
        case spaces(Int)

        public var unit: String {
            switch self {
            case .tabs: return "\t"
            case .spaces(let width): return String(repeating: " ", count: width)
            }
        }

        public var label: String {
            switch self {
            case .tabs: return "Tabs"
            case .spaces(let width): return "Spaces: \(width)"
            }
        }
    }

    /// How the file is already indented, so new lines match it instead of the editor's taste.
    ///
    /// Counts lines that start with a tab against lines that start with spaces, and for spaces
    /// takes the most common step between consecutive indentation levels. A file with no
    /// indentation yet gets `fallback`.
    public static func detectIndentation(_ text: String, fallback: Indentation = .spaces(4)) -> Indentation {
        var tabLines = 0
        var spaceLines = 0
        var steps: [Int: Int] = [:]
        var previousSpaces = 0
        var examined = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            examined += 1
            if examined > 5_000 { break }
            guard let first = line.first else { continue }
            if first == "\t" {
                tabLines += 1
                continue
            }
            let spaces = line.prefix(while: { $0 == " " }).count
            guard spaces < line.count else { continue } // blank line
            if spaces > 0 { spaceLines += 1 }
            let step = abs(spaces - previousSpaces)
            if step >= 2, step <= 8 { steps[step, default: 0] += 1 }
            previousSpaces = spaces
        }
        if tabLines > spaceLines, tabLines > 0 { return .tabs }
        guard spaceLines > 0, let best = steps.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else {
            return fallback
        }
        return .spaces(best.key)
    }

    /// The leading whitespace of the line containing `location` (a UTF-16 offset).
    public static func leadingWhitespace(ofLineAt location: Int, in text: NSString) -> String {
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        var end = lineRange.location
        while end < NSMaxRange(lineRange) {
            let c = text.character(at: end)
            guard c == 32 || c == 9 else { break }
            end += 1
        }
        return text.substring(with: NSRange(location: lineRange.location, length: end - lineRange.location))
    }

    /// What pressing Return inserts at `location`.
    ///
    /// Keeps the current line's indentation; after an opening bracket (or a Python `:`) indents
    /// one more level; and between a bracket pair (`{|}`) opens the pair onto its own lines with
    /// the cursor inside. Returns the text to insert and where the cursor goes, relative to the
    /// start of the insertion.
    public static func newlineInsertion(
        at location: Int,
        in text: NSString,
        indentation: Indentation,
        language: SyntaxLanguage
    ) -> (text: String, cursorOffset: Int) {
        let base = leadingWhitespace(ofLineAt: location, in: text)
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))

        var before: unichar = 0
        var scan = location - 1
        while scan >= lineRange.location {
            let c = text.character(at: scan)
            if c != 32, c != 9 { before = c; break }
            scan -= 1
        }
        let after: unichar = location < text.length ? text.character(at: location) : 0

        let opens: Set<unichar> = [123, 40, 91] // { ( [
        let closes: [unichar: unichar] = [123: 125, 40: 41, 91: 93]
        let pythonBlock = language == .python && before == 58 // :

        if opens.contains(before) || pythonBlock {
            let inner = base + indentation.unit
            if let close = closes[before], after == close {
                let inserted = "\n" + inner + "\n" + base
                return (inserted, 1 + (inner as NSString).length)
            }
            let inserted = "\n" + inner
            return (inserted, (inserted as NSString).length)
        }
        let inserted = "\n" + base
        return (inserted, (inserted as NSString).length)
    }

    /// Lines touched by `selection`, as a range covering whole lines.
    public static func wholeLines(for selection: NSRange, in text: NSString) -> NSRange {
        var range = text.lineRange(for: selection)
        // A selection ending exactly at the start of a line does not include that line.
        if selection.length > 0, NSMaxRange(selection) == range.location + range.length,
           NSMaxRange(selection) > 0, text.character(at: NSMaxRange(selection) - 1) == 10,
           range.length > 0 {
            let trimmed = text.lineRange(for: NSRange(location: NSMaxRange(selection) - 1, length: 0))
            range = NSUnionRange(text.lineRange(for: NSRange(location: selection.location, length: 0)), trimmed)
        }
        return range
    }

    /// Indent (or outdent) every line in `block` by one level.
    public static func shiftLines(_ block: String, by indentation: Indentation, outdent: Bool) -> String {
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        let shifted = lines.map { line -> String in
            if outdent {
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let width: Int
                switch indentation {
                case .tabs: width = 4
                case .spaces(let w): width = w
                }
                let spaces = line.prefix(while: { $0 == " " }).count
                return String(line.dropFirst(min(spaces, width)))
            }
            return line.isEmpty ? line : indentation.unit + line
        }
        return shifted.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
    }

    /// Comment every line in `block` out, or back in when every non-blank line already is.
    public static func toggleLineComments(_ block: String, prefix: String) -> String {
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !contentLines.isEmpty && contentLines.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }
        // Comment at the shallowest indentation, so a commented block stays aligned.
        let minIndent = contentLines.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0

        let result = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allCommented {
                guard let range = line.range(of: prefix) else { return line }
                var removeEnd = range.upperBound
                if removeEnd < line.endIndex, line[removeEnd] == " " { removeEnd = line.index(after: removeEnd) }
                return String(line[line.startIndex..<range.lowerBound]) + String(line[removeEnd...])
            }
            let index = line.index(line.startIndex, offsetBy: min(minIndent, line.count))
            return String(line[..<index]) + prefix + " " + String(line[index...])
        }
        return result.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
    }

    // MARK: - Positions

    /// 1-based line and column of a UTF-16 offset.
    public static func lineAndColumn(of location: Int, in text: NSString) -> (line: Int, column: Int) {
        let clamped = max(0, min(location, text.length))
        var line = 1
        var lineStart = 0
        var i = 0
        while i < clamped {
            if text.character(at: i) == 10 {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        return (line, clamped - lineStart + 1)
    }

    /// UTF-16 offset of the start of a 1-based line, clamped to the text.
    public static func location(ofLine line: Int, in text: NSString) -> Int {
        guard line > 1 else { return 0 }
        var current = 1
        var i = 0
        while i < text.length {
            if text.character(at: i) == 10 {
                current += 1
                if current == line { return i + 1 }
            }
            i += 1
        }
        return text.length
    }

    // MARK: - Completion

    /// Identifiers worth offering, most used first.
    public static func words(in text: String, minimumLength: Int = 3, limit: Int = 4_000) -> [String] {
        var counts: [String: Int] = [:]
        var current = ""
        func flush() {
            if current.count >= minimumLength, let first = current.unicodeScalars.first,
               !CharacterSet.decimalDigits.contains(first) {
                counts[current, default: 0] += 1
            }
            current = ""
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// Completion candidates for `prefix`.
    ///
    /// Order is what the file already uses, then what the workspace declares, then the language's
    /// keywords — the word you are most likely typing is one you have typed before. Exact-case
    /// prefix matches rank above case-insensitive ones, and the prefix itself is never offered,
    /// since completing a word to itself would make Tab do nothing visible.
    public static func completions(
        prefix: String,
        documentWords: [String],
        workspaceSymbols: [String],
        keywords: [String],
        limit: Int = 40
    ) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let lowerPrefix = prefix.lowercased()
        var seen = Set<String>([prefix])
        var exact: [String] = []
        var loose: [String] = []
        for source in [documentWords, workspaceSymbols, keywords] {
            for word in source where word.count > prefix.count && !seen.contains(word) {
                if word.hasPrefix(prefix) {
                    exact.append(word)
                    seen.insert(word)
                } else if word.lowercased().hasPrefix(lowerPrefix) {
                    loose.append(word)
                    seen.insert(word)
                }
            }
        }
        return Array((exact + loose).prefix(limit))
    }

    /// Keywords the highlighter knows for `language`, for completion.
    public static func keywords(for language: SyntaxLanguage) -> [String] {
        let rules = LanguageRules.rules(for: language)
        return (rules.keywords.union(rules.constants)).sorted()
    }
}
