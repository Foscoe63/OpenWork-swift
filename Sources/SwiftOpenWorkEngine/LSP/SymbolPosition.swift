import Foundation

/// Turns "the symbol `value` on line 12" into the LSP position of that symbol.
///
/// Agents address code by line and name; LSP wants a zero-based line and a UTF-16 offset. The
/// conversion is where a request silently goes to the wrong place — `let value = value` has two
/// candidates, and the first is not always the one meant — so an ambiguous line is an error that
/// lists the columns, never a guess.
public enum SymbolPosition {

    public struct Resolved: Equatable, Sendable {
        /// Zero-based.
        public var line: Int
        /// Zero-based UTF-16 offset, as LSP defines `character`.
        public var character: Int
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case needsSymbolOrColumn
        case lineOutOfRange(line: Int, lineCount: Int)
        case columnOutOfRange(column: Int, line: Int, length: Int)
        case symbolNotOnLine(symbol: String, line: Int, text: String)
        case ambiguous(symbol: String, line: Int, columns: [Int])
        case symbolNotAtColumn(symbol: String, column: Int, columns: [Int])

        public var errorDescription: String? {
            switch self {
            case .needsSymbolOrColumn:
                return "Pass `symbol` (the name on that line) or `column`."
            case .lineOutOfRange(let line, let count):
                return "Line \(line) is outside the file, which has \(count) lines."
            case .columnOutOfRange(let column, let line, let length):
                return "Column \(column) is past the end of line \(line), which is \(length) characters long."
            case .symbolNotOnLine(let symbol, let line, let text):
                return "'\(symbol)' does not appear as a whole word on line \(line): \(text.trimmingCharacters(in: .whitespaces))"
            case .ambiguous(let symbol, let line, let columns):
                return "'\(symbol)' appears \(columns.count) times on line \(line) (columns \(columns.map(String.init).joined(separator: ", "))). Pass `column` to pick one."
            case .symbolNotAtColumn(let symbol, let column, let columns):
                return "'\(symbol)' is not at column \(column); it is at column\(columns.count == 1 ? "" : "s") \(columns.map(String.init).joined(separator: ", "))."
            }
        }
    }

    /// Words that introduce a declaration in the languages the catalog covers. Used only to break
    /// a tie when the caller says the line is a declaration.
    public static let declarationKeywords: Set<String> = [
        "func", "var", "let", "class", "struct", "enum", "protocol", "typealias", "actor", "case",
        "associatedtype", "macro", "extension",
        "def", "fn", "type", "interface", "const", "function", "trait", "mod",
    ]

    /// - Parameters:
    ///   - line: 1-based.
    ///   - column: 1-based, counted in characters as an editor shows them. With `symbol`, any
    ///     column inside the name selects it.
    ///   - preferDeclaration: on a line where the name appears more than once, choose the
    ///     occurrence directly after a declaration keyword if there is exactly one.
    public static func resolve(
        in text: String,
        line: Int,
        symbol: String?,
        column: Int?,
        preferDeclaration: Bool = false
    ) throws -> Resolved {
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else {
            throw Failure.lineOutOfRange(line: line, lineCount: lines.count)
        }
        var lineText = lines[line - 1]
        if lineText.hasSuffix("\r") { lineText.removeLast() }

        let name = symbol?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard let name else {
            guard let column else { throw Failure.needsSymbolOrColumn }
            guard column >= 1, column <= lineText.count + 1 else {
                throw Failure.columnOutOfRange(column: column, line: line, length: lineText.count)
            }
            let index = lineText.index(lineText.startIndex, offsetBy: column - 1)
            return Resolved(line: line - 1, character: lineText.utf16.distance(from: lineText.utf16.startIndex, to: index))
        }

        let occurrences = self.occurrences(of: name, in: lineText)
        guard !occurrences.isEmpty else {
            throw Failure.symbolNotOnLine(symbol: name, line: line, text: lineText)
        }
        let columns = occurrences.map { $0.column }

        let chosen: Occurrence
        if let column {
            guard let match = occurrences.first(where: { column >= $0.column && column < $0.column + name.count }) else {
                throw Failure.symbolNotAtColumn(symbol: name, column: column, columns: columns)
            }
            chosen = match
        } else if occurrences.count == 1 {
            chosen = occurrences[0]
        } else if preferDeclaration,
                  case let declared = occurrences.filter({ isAfterDeclarationKeyword($0, in: lineText) }),
                  declared.count == 1 {
            chosen = declared[0]
        } else {
            throw Failure.ambiguous(symbol: name, line: line, columns: columns)
        }
        return Resolved(line: line - 1, character: chosen.utf16Offset)
    }

    public struct Occurrence: Equatable {
        /// 1-based character column.
        public var column: Int
        public var utf16Offset: Int
    }

    /// Whole-identifier matches. `\b` is not enough: it treats `$` as a boundary, so `$value`
    /// would match `value`.
    public static func occurrences(of name: String, in lineText: String) -> [Occurrence] {
        let identifier = "[A-Za-z0-9_$]"
        let pattern = "(?<!\(identifier))" + NSRegularExpression.escapedPattern(for: name) + "(?!\(identifier))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(lineText.startIndex..., in: lineText)
        return regex.matches(in: lineText, range: range).compactMap { match in
            guard let start = Range(match.range, in: lineText)?.lowerBound else { return nil }
            let column = lineText.distance(from: lineText.startIndex, to: start) + 1
            return Occurrence(column: column, utf16Offset: match.range.location)
        }
    }

    private static func isAfterDeclarationKeyword(_ occurrence: Occurrence, in lineText: String) -> Bool {
        let prefix = lineText.prefix(occurrence.column - 1).trimmingCharacters(in: .whitespaces)
        guard let word = prefix.split(whereSeparator: { !$0.isLetter }).last else { return false }
        return prefix.hasSuffix(word) && declarationKeywords.contains(String(word))
    }

    /// The 1-based character column of a UTF-16 offset on a line, for output a person reads.
    public static func characterColumn(utf16Offset: Int, in lineText: String) -> Int {
        let units = Array(lineText.utf16.prefix(max(0, utf16Offset)))
        return String(decoding: units, as: UTF16.self).count + 1
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
