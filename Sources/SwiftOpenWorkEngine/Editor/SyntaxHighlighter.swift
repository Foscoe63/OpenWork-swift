import Foundation

/// A language the editor knows how to colour.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, javascript, typescript, python, json, go, rust, java, kotlin, c, cpp, csharp
    case ruby, shell, yaml, toml, css, scss, html, xml, markdown, sql, makefile, dockerfile
    case plain

    /// The name shown in the editor's status bar.
    public var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .json: return "JSON"
        case .go: return "Go"
        case .rust: return "Rust"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .c: return "C"
        case .cpp: return "C++"
        case .csharp: return "C#"
        case .ruby: return "Ruby"
        case .shell: return "Shell"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .css: return "CSS"
        case .scss: return "SCSS"
        case .html: return "HTML"
        case .xml: return "XML"
        case .markdown: return "Markdown"
        case .sql: return "SQL"
        case .makefile: return "Makefile"
        case .dockerfile: return "Dockerfile"
        case .plain: return "Plain Text"
        }
    }

    /// What a line comment starts with, for Toggle Comment. nil where the language has none.
    public var lineCommentPrefix: String? {
        switch self {
        case .swift, .javascript, .typescript, .go, .rust, .java, .kotlin, .c, .cpp, .csharp, .scss:
            return "//"
        case .python, .ruby, .shell, .yaml, .toml, .makefile, .dockerfile:
            return "#"
        case .sql:
            return "--"
        case .json, .css, .html, .xml, .markdown, .plain:
            return nil
        }
    }

    public static func detect(path: String) -> SyntaxLanguage {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        switch lower {
        case "makefile", "gnumakefile": return .makefile
        case "dockerfile", "containerfile": return .dockerfile
        case "gemfile", "rakefile", "podfile", "fastfile": return .ruby
        case "package.resolved": return .json
        case ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile": return .shell
        default: break
        }
        if lower.hasPrefix("dockerfile.") { return .dockerfile }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyw": return .python
        case "json", "jsonc", "json5", "webmanifest": return .json
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm": return .cpp
        case "cs": return .csharp
        case "rb", "gemspec", "podspec": return .ruby
        case "sh", "bash", "zsh", "fish", "command": return .shell
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "css": return .css
        case "scss", "sass", "less": return .scss
        case "html", "htm", "vue", "svelte", "astro": return .html
        case "xml", "plist", "svg", "xib", "storyboard", "entitlements", "xcscheme": return .xml
        case "md", "markdown", "mdx": return .markdown
        case "sql": return .sql
        case "mk": return .makefile
        default: return .plain
        }
    }
}

/// What a highlighted range is.
public enum SyntaxTokenKind: String, Sendable, CaseIterable {
    case keyword, type, string, number, comment, attribute, function, property
    case tag, attributeName, heading, link, emphasis
}

public struct SyntaxToken: Equatable, Sendable {
    /// UTF-16 range, so it maps directly onto `NSTextStorage`.
    public var range: NSRange
    public var kind: SyntaxTokenKind

    public init(_ location: Int, _ length: Int, _ kind: SyntaxTokenKind) {
        self.range = NSRange(location: location, length: length)
        self.kind = kind
    }
}

/// A small, fast lexer for colouring code — not a parser.
///
/// It exists so the editor can say "this is a string, this is a comment" correctly, which is what
/// makes code readable: a keyword inside a string or a comment must not light up, and a string that
/// contains `//` is still a string. Regex-per-token highlighters get those wrong, and wrong colours
/// are worse than none because they mislead. A single left-to-right scan gets them right and costs
/// a few milliseconds for a large source file.
public enum SyntaxHighlighter {

    /// Beyond this, colouring is skipped. The editor stays usable on a large generated file, and
    /// nobody reads a 3MB minified bundle by its colours.
    public static let maxHighlightedUTF16 = 1_500_000

    public static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= maxHighlightedUTF16 else { return [] }
        switch language {
        case .plain:
            return []
        case .html, .xml:
            return MarkupScanner(units: units, language: language).scan()
        case .markdown:
            return MarkdownScanner(units: units).scan()
        default:
            return CodeScanner(units: units, rules: LanguageRules.rules(for: language)).scan()
        }
    }
}

// MARK: - Rules

public struct LanguageRules {
    public var lineComments: [String] = []
    public var blockComment: (open: String, close: String)?
    public var nestedBlockComments = false
    /// Longest first. A delimiter here opens a string that ends at the same delimiter.
    public var stringDelimiters: [String] = []
    /// Delimiters whose strings may span lines.
    public var multilineDelimiters: Set<String> = []
    public var keywords: Set<String> = []
    public var caseInsensitiveKeywords = false
    public var constants: Set<String> = []
    /// `@name` is an attribute / decorator / annotation.
    public var atAttributes = false
    /// `#name` at a line start (C preprocessor) or anywhere (Swift `#if`) is an attribute.
    public var hashDirectives = false
    /// `#` starts a comment only at a line start or after whitespace, as in shell and YAML.
    public var hashCommentNeedsBoundary = false
    /// `$name` / `${name}` is a variable.
    public var dollarVariables = false
    /// A string immediately followed by `:` is a key (JSON).
    public var stringKeys = false
    /// `name:` at the start of a line is a key (YAML).
    public var lineKeys = false
    /// `[section]` at the start of a line is a heading (TOML).
    public var bracketSections = false
    public var identifierExtraChars: Set<UInt16> = []

    public static func rules(for language: SyntaxLanguage) -> LanguageRules {
        var r = LanguageRules()
        switch language {
        case .swift:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.nestedBlockComments = true
            r.stringDelimiters = ["\"\"\"", "\""]
            r.multilineDelimiters = ["\"\"\""]
            r.atAttributes = true
            r.hashDirectives = true
            r.keywords = [
                "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
                "import", "init", "inout", "internal", "let", "open", "operator", "private",
                "precedencegroup", "protocol", "public", "rethrows", "static", "struct",
                "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
                "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
                "return", "throw", "switch", "where", "while", "as", "is", "try", "throws",
                "async", "await", "actor", "nonisolated", "isolated", "some", "any", "self",
                "Self", "super", "mutating", "nonmutating", "override", "final", "lazy", "weak",
                "unowned", "required", "convenience", "dynamic", "optional", "indirect",
                "package", "consuming", "borrowing", "sending", "get", "set", "willSet", "didSet",
                "macro", "each", "discard", "then",
            ]
            r.constants = ["true", "false", "nil"]
        case .javascript, .typescript:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.stringDelimiters = ["\"", "'", "`"]
            r.multilineDelimiters = ["`"]
            r.atAttributes = true
            r.identifierExtraChars = [UInt16(UInt8(ascii: "$"))]
            r.keywords = [
                "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                "delete", "do", "else", "export", "extends", "finally", "for", "function", "if",
                "import", "in", "instanceof", "let", "new", "return", "super", "switch", "this",
                "throw", "try", "typeof", "var", "void", "while", "with", "yield", "async",
                "await", "of", "static", "get", "set", "from", "as",
            ]
            if language == .typescript {
                r.keywords.formUnion([
                    "interface", "type", "enum", "implements", "private", "public", "protected",
                    "readonly", "abstract", "declare", "namespace", "module", "keyof", "infer",
                    "is", "satisfies", "unique", "override", "asserts",
                    "string", "number", "boolean", "unknown", "never", "any", "object", "symbol",
                    "bigint",
                ])
            }
            r.constants = ["true", "false", "null", "undefined", "NaN", "Infinity"]
        case .python:
            r.lineComments = ["#"]
            r.stringDelimiters = ["\"\"\"", "'''", "\"", "'"]
            r.multilineDelimiters = ["\"\"\"", "'''"]
            r.atAttributes = true
            r.keywords = [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
                "return", "try", "while", "with", "yield", "match", "case", "self", "cls",
            ]
            r.constants = ["True", "False", "None"]
        case .json:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.stringDelimiters = ["\""]
            r.stringKeys = true
            r.constants = ["true", "false", "null"]
        case .go:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.stringDelimiters = ["\"", "'", "`"]
            r.multilineDelimiters = ["`"]
            r.keywords = [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
                "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                "uint32", "uint64", "float32", "float64", "bool", "byte", "rune", "error", "any",
            ]
            r.constants = ["true", "false", "nil", "iota"]
        case .rust:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.nestedBlockComments = true
            r.stringDelimiters = ["\""]
            r.multilineDelimiters = ["\""]
            r.hashDirectives = true
            r.keywords = [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
                "trait", "type", "unsafe", "use", "where", "while", "i8", "i16", "i32", "i64",
                "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool",
                "char", "str",
            ]
            r.constants = ["true", "false", "None", "Some", "Ok", "Err"]
        case .java, .kotlin, .csharp:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.stringDelimiters = ["\"\"\"", "\"", "'"]
            r.multilineDelimiters = ["\"\"\""]
            r.atAttributes = true
            r.hashDirectives = language == .csharp
            r.keywords = [
                "abstract", "break", "case", "catch", "class", "const", "continue", "default",
                "do", "else", "enum", "extends", "final", "finally", "for", "if", "implements",
                "import", "instanceof", "interface", "new", "package", "private", "protected",
                "public", "return", "static", "super", "switch", "this", "throw", "throws", "try",
                "void", "while", "var", "val", "fun", "object", "when", "is", "in", "out",
                "override", "open", "data", "sealed", "suspend", "companion", "internal", "lateinit",
                "using", "namespace", "struct", "readonly", "async", "await", "record", "boolean",
                "int", "long", "double", "float", "char", "byte", "short", "string", "bool",
            ]
            r.constants = ["true", "false", "null"]
        case .c, .cpp:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.stringDelimiters = ["\"", "'"]
            r.atAttributes = true
            r.hashDirectives = true
            r.keywords = [
                "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
                "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
                "register", "return", "short", "signed", "sizeof", "static", "struct", "switch",
                "typedef", "union", "unsigned", "void", "volatile", "while", "class", "namespace",
                "template", "typename", "public", "private", "protected", "virtual", "override",
                "new", "delete", "this", "using", "constexpr", "nullptr", "try", "catch", "throw",
                "bool", "self", "id", "interface", "implementation", "end", "property",
            ]
            r.constants = ["true", "false", "NULL", "nil", "YES", "NO"]
        case .ruby:
            r.lineComments = ["#"]
            r.stringDelimiters = ["\"", "'"]
            r.keywords = [
                "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
                "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not",
                "or", "redo", "rescue", "retry", "return", "self", "super", "then", "undef",
                "unless", "until", "when", "while", "yield", "require", "attr_accessor",
            ]
            r.constants = ["true", "false", "nil"]
        case .shell, .makefile, .dockerfile:
            r.lineComments = ["#"]
            r.hashCommentNeedsBoundary = true
            r.stringDelimiters = ["\"", "'"]
            r.multilineDelimiters = ["\"", "'"]
            r.dollarVariables = true
            r.keywords = [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
                "esac", "in", "function", "return", "export", "local", "readonly", "set", "unset",
                "source", "exit", "echo", "cd",
            ]
            if language == .dockerfile {
                r.caseInsensitiveKeywords = true
                r.keywords.formUnion([
                    "from", "run", "cmd", "label", "expose", "env", "add", "copy", "entrypoint",
                    "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck",
                    "shell",
                ])
            }
        case .yaml, .toml:
            r.lineComments = ["#"]
            r.hashCommentNeedsBoundary = true
            r.stringDelimiters = ["\"", "'"]
            r.lineKeys = true
            r.bracketSections = language == .toml
            r.constants = ["true", "false", "null", "yes", "no", "on", "off", "~"]
        case .css, .scss:
            r.lineComments = language == .scss ? ["//"] : []
            r.blockComment = ("/*", "*/")
            r.stringDelimiters = ["\"", "'"]
            r.atAttributes = true
            r.dollarVariables = language == .scss
            r.identifierExtraChars = [UInt16(UInt8(ascii: "-"))]
            r.keywords = ["important", "inherit", "initial", "unset", "none", "auto"]
        case .sql:
            r.lineComments = ["--"]
            r.blockComment = ("/*", "*/")
            r.stringDelimiters = ["'", "\""]
            r.caseInsensitiveKeywords = true
            r.keywords = [
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                "create", "table", "drop", "alter", "add", "index", "primary", "key", "foreign",
                "references", "join", "left", "right", "inner", "outer", "on", "group", "by",
                "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is",
                "in", "like", "between", "distinct", "union", "all", "case", "when", "then",
                "else", "end", "with", "returning", "default", "unique", "exists", "view",
            ]
        case .html, .xml, .markdown, .plain:
            break
        }
        return r
    }
}

// MARK: - Code scanner

private struct CodeScanner {
    let units: [UInt16]
    let rules: LanguageRules
    private let lineCommentUnits: [[UInt16]]
    private let blockOpen: [UInt16]
    private let blockClose: [UInt16]
    private let delimiterUnits: [(String, [UInt16])]
    private let lowercasedKeywords: Set<String>
    /// Longer identifiers cannot be keywords, so they skip the string allocation a lookup needs.
    private let longestWord: Int

    init(units: [UInt16], rules: LanguageRules) {
        self.units = units
        self.rules = rules
        lineCommentUnits = rules.lineComments.map { Array($0.utf16) }
        blockOpen = rules.blockComment.map { Array($0.open.utf16) } ?? []
        blockClose = rules.blockComment.map { Array($0.close.utf16) } ?? []
        delimiterUnits = rules.stringDelimiters.map { ($0, Array($0.utf16)) }
        lowercasedKeywords = rules.caseInsensitiveKeywords ? Set(rules.keywords.map { $0.lowercased() }) : []
        longestWord = rules.keywords.union(rules.constants).map { $0.utf16.count }.max() ?? 0
    }

    func scan() -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        tokens.reserveCapacity(units.count / 6)
        let n = units.count
        var i = 0
        var atLineStart = true

        while i < n {
            let c = units[i]

            if c == Ch.newline {
                atLineStart = true
                i += 1
                continue
            }
            if c == Ch.space || c == Ch.tab {
                i += 1
                continue
            }
            let lineStartHere = atLineStart
            atLineStart = false

            // YAML / TOML keys and sections, recognised at the first non-blank character.
            if lineStartHere, rules.bracketSections, c == Ch.openBracket {
                let end = endOfLine(from: i)
                tokens.append(SyntaxToken(i, end - i, .heading))
                i = end
                continue
            }
            if lineStartHere, rules.lineKeys, let keyEnd = lineKeyEnd(from: i) {
                tokens.append(SyntaxToken(i, keyEnd - i, .property))
                i = keyEnd
                continue
            }

            // Comments.
            if let lineComment = lineCommentUnits.first(where: { matches($0, at: i) }) {
                let isHash = lineComment == [Ch.hash]
                if !isHash || !rules.hashCommentNeedsBoundary || lineStartHere || isBoundary(before: i) {
                    let end = endOfLine(from: i)
                    tokens.append(SyntaxToken(i, end - i, .comment))
                    i = end
                    continue
                }
            }
            if !blockOpen.isEmpty, matches(blockOpen, at: i) {
                let end = endOfBlockComment(from: i)
                tokens.append(SyntaxToken(i, end - i, .comment))
                i = end
                continue
            }

            // Strings.
            if let (delimiter, delimiterUnits) = delimiterUnits.first(where: { matches($0.1, at: i) }) {
                let end = endOfString(from: i, delimiter: delimiterUnits,
                                      multiline: rules.multilineDelimiters.contains(delimiter))
                var kind: SyntaxTokenKind = .string
                if rules.stringKeys, nextNonBlank(from: end) == Ch.colon { kind = .property }
                tokens.append(SyntaxToken(i, end - i, kind))
                i = end
                continue
            }

            // Numbers — but not the digits inside an identifier like `utf8`.
            if isDigit(c) || (c == Ch.dot && i + 1 < n && isDigit(units[i + 1]) && !isIdentifierPart(before: i)) {
                let end = endOfNumber(from: i)
                tokens.append(SyntaxToken(i, end - i, .number))
                i = end
                continue
            }

            // Attributes, decorators, directives, variables.
            if rules.atAttributes, c == Ch.at, i + 1 < n, isIdentifierStart(units[i + 1]) {
                let end = endOfIdentifier(from: i + 1)
                tokens.append(SyntaxToken(i, end - i, .attribute))
                i = end
                continue
            }
            if rules.hashDirectives, c == Ch.hash, i + 1 < n, isIdentifierStart(units[i + 1]) {
                let end = endOfIdentifier(from: i + 1)
                tokens.append(SyntaxToken(i, end - i, .attribute))
                i = end
                continue
            }
            if rules.dollarVariables, c == Ch.dollar, i + 1 < n {
                if units[i + 1] == Ch.openBrace {
                    var j = i + 2
                    while j < n, units[j] != Ch.closeBrace, units[j] != Ch.newline { j += 1 }
                    let end = j < n && units[j] == Ch.closeBrace ? j + 1 : j
                    tokens.append(SyntaxToken(i, end - i, .property))
                    i = end
                    continue
                }
                if isIdentifierStart(units[i + 1]) || isDigit(units[i + 1]) {
                    let end = endOfIdentifier(from: i + 1)
                    tokens.append(SyntaxToken(i, end - i, .property))
                    i = end
                    continue
                }
            }

            // Identifiers.
            if isIdentifierStart(c) {
                let end = endOfIdentifier(from: i)
                if let kind = classify(start: i, end: end) {
                    tokens.append(SyntaxToken(i, end - i, kind))
                }
                i = end
                continue
            }

            i += 1
        }
        return tokens
    }

    private func classify(start: Int, end: Int) -> SyntaxTokenKind? {
        if end - start <= longestWord {
            let word = units.withUnsafeBufferPointer {
                String(utf16CodeUnits: $0.baseAddress! + start, count: end - start)
            }
            if rules.constants.contains(word) { return .keyword }
            if rules.caseInsensitiveKeywords {
                if lowercasedKeywords.contains(word.lowercased()) { return .keyword }
            } else if rules.keywords.contains(word) {
                // `.default`, `obj.class` — a member access is not the keyword.
                if start > 0, units[start - 1] == Ch.dot { return nil }
                return .keyword
            }
        }
        if nextNonBlankOnLine(from: end) == Ch.openParen { return .function }
        let first = units[start]
        if first >= 65, first <= 90 { return .type }
        return nil
    }

    // MARK: Helpers

    private func matches(_ pattern: [UInt16], at i: Int) -> Bool {
        guard i + pattern.count <= units.count else { return false }
        for k in 0..<pattern.count where units[i + k] != pattern[k] { return false }
        return true
    }

    private func endOfLine(from i: Int) -> Int {
        var j = i
        while j < units.count, units[j] != Ch.newline { j += 1 }
        return j
    }

    private func endOfBlockComment(from i: Int) -> Int {
        var depth = 1
        var j = i + blockOpen.count
        while j < units.count {
            if matches(blockClose, at: j) {
                depth -= 1
                j += blockClose.count
                if depth == 0 || !rules.nestedBlockComments { return j }
                continue
            }
            if rules.nestedBlockComments, matches(blockOpen, at: j) {
                depth += 1
                j += blockOpen.count
                continue
            }
            j += 1
        }
        return units.count
    }

    private func endOfString(from i: Int, delimiter: [UInt16], multiline: Bool) -> Int {
        var j = i + delimiter.count
        while j < units.count {
            let u = units[j]
            if u == Ch.backslash {
                j += 2
                continue
            }
            if u == Ch.newline, !multiline { return j }
            if matches(delimiter, at: j) { return j + delimiter.count }
            j += 1
        }
        return units.count
    }

    private func endOfNumber(from i: Int) -> Int {
        var j = i
        while j < units.count {
            let u = units[j]
            if isDigit(u) || isLetter(u) || u == Ch.underscore {
                j += 1
                continue
            }
            // A decimal point only when a digit follows: `0..<5` and `x.1.foo` stay intact.
            if u == Ch.dot, j + 1 < units.count, isDigit(units[j + 1]) {
                j += 1
                continue
            }
            // Exponent sign: `1e-9`.
            if (u == Ch.plus || u == Ch.minus), j > i, units[j - 1] == 101 || units[j - 1] == 69,
               j + 1 < units.count, isDigit(units[j + 1]) {
                j += 1
                continue
            }
            break
        }
        return max(j, i + 1)
    }

    private func endOfIdentifier(from i: Int) -> Int {
        var j = i
        while j < units.count, isIdentifierPart(units[j]) { j += 1 }
        return max(j, i + 1)
    }

    /// `key:` at the start of a YAML / TOML line (also `key =` for TOML). Returns the key's end.
    private func lineKeyEnd(from i: Int) -> Int? {
        var j = i
        if j < units.count, units[j] == Ch.minus, j + 1 < units.count, units[j + 1] == Ch.space {
            return nil
        }
        while j < units.count {
            let u = units[j]
            if isIdentifierPart(u) || u == Ch.minus || u == Ch.dot { j += 1; continue }
            break
        }
        guard j > i else { return nil }
        var k = j
        while k < units.count, units[k] == Ch.space { k += 1 }
        guard k < units.count else { return nil }
        if units[k] == Ch.colon || units[k] == Ch.equals { return j }
        return nil
    }

    private func nextNonBlank(from i: Int) -> UInt16? {
        var j = i
        while j < units.count, units[j] == Ch.space || units[j] == Ch.tab || units[j] == Ch.newline { j += 1 }
        return j < units.count ? units[j] : nil
    }

    private func nextNonBlankOnLine(from i: Int) -> UInt16? {
        var j = i
        while j < units.count, units[j] == Ch.space || units[j] == Ch.tab { j += 1 }
        return j < units.count ? units[j] : nil
    }

    private func isBoundary(before i: Int) -> Bool {
        guard i > 0 else { return true }
        let p = units[i - 1]
        return p == Ch.space || p == Ch.tab || p == Ch.newline
    }

    private func isIdentifierPart(before i: Int) -> Bool {
        i > 0 && isIdentifierPart(units[i - 1])
    }

    private func isIdentifierStart(_ u: UInt16) -> Bool {
        isLetter(u) || u == Ch.underscore || rules.identifierExtraChars.contains(u) || u > 127
    }

    private func isIdentifierPart(_ u: UInt16) -> Bool {
        isIdentifierStart(u) || isDigit(u)
    }
}

// MARK: - Markup (HTML / XML)

private struct MarkupScanner {
    let units: [UInt16]
    let language: SyntaxLanguage

    func scan() -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let n = units.count
        var i = 0
        let commentOpen = Array("<!--".utf16)
        let commentClose = Array("-->".utf16)
        let cdataOpen = Array("<![CDATA[".utf16)
        let cdataClose = Array("]]>".utf16)
        let scriptClose = Array("</script".utf16)
        let styleClose = Array("</style".utf16)

        while i < n {
            if matches(commentOpen, at: i) {
                let end = find(commentClose, from: i + commentOpen.count).map { $0 + commentClose.count } ?? n
                tokens.append(SyntaxToken(i, end - i, .comment))
                i = end
                continue
            }
            if matches(cdataOpen, at: i) {
                let end = find(cdataClose, from: i).map { $0 + cdataClose.count } ?? n
                tokens.append(SyntaxToken(i, end - i, .string))
                i = end
                continue
            }
            if units[i] == Ch.lessThan, i + 1 < n,
               isNameStart(units[i + 1]) || units[i + 1] == Ch.slash || units[i + 1] == Ch.bang || units[i + 1] == Ch.question {
                var j = i + 1
                if units[j] == Ch.slash || units[j] == Ch.bang || units[j] == Ch.question { j += 1 }
                let nameStart = j
                while j < n, isNamePart(units[j]) { j += 1 }
                let tagName = String(utf16CodeUnits: Array(units[nameStart..<j]), count: j - nameStart).lowercased()
                tokens.append(SyntaxToken(i, j - i, .tag))
                // Attributes until `>`.
                while j < n, units[j] != Ch.greaterThan {
                    let u = units[j]
                    if u == Ch.quote || u == Ch.apostrophe {
                        var k = j + 1
                        while k < n, units[k] != u { k += 1 }
                        let end = min(n, k + 1)
                        tokens.append(SyntaxToken(j, end - j, .string))
                        j = end
                        continue
                    }
                    if isNameStart(u) {
                        var k = j
                        while k < n, isNamePart(units[k]) { k += 1 }
                        tokens.append(SyntaxToken(j, k - j, .attributeName))
                        j = k
                        continue
                    }
                    j += 1
                }
                if j < n {
                    tokens.append(SyntaxToken(j, 1, .tag))
                    j += 1
                }
                i = j
                // Script and style bodies are left uncoloured rather than coloured as markup.
                if language == .html, units[nameStart - 1] != Ch.slash {
                    if tagName == "script", let close = find(scriptClose, from: i) { i = close }
                    else if tagName == "style", let close = find(styleClose, from: i) { i = close }
                }
                continue
            }
            if units[i] == Ch.ampersand {
                var j = i + 1
                while j < n, j - i < 12, isNamePart(units[j]) || units[j] == Ch.hash { j += 1 }
                if j < n, units[j] == Ch.semicolon {
                    tokens.append(SyntaxToken(i, j + 1 - i, .keyword))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return tokens
    }

    private func matches(_ pattern: [UInt16], at i: Int) -> Bool {
        guard i + pattern.count <= units.count else { return false }
        for k in 0..<pattern.count {
            var u = units[i + k]
            if u >= 65, u <= 90 { u += 32 }
            if u != pattern[k] { return false }
        }
        return true
    }

    private func find(_ pattern: [UInt16], from start: Int) -> Int? {
        var i = start
        while i + pattern.count <= units.count {
            if matches(pattern, at: i) { return i }
            i += 1
        }
        return nil
    }

    private func isNameStart(_ u: UInt16) -> Bool { isLetter(u) || u == Ch.underscore || u == Ch.colon }
    private func isNamePart(_ u: UInt16) -> Bool {
        isNameStart(u) || isDigit(u) || u == Ch.minus || u == Ch.dot
    }
}

// MARK: - Markdown

private struct MarkdownScanner {
    let units: [UInt16]

    func scan() -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let n = units.count
        var lineStart = 0
        var inFence = false
        var fenceStart = 0

        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n, units[lineEnd] != Ch.newline { lineEnd += 1 }
            var first = lineStart
            while first < lineEnd, units[first] == Ch.space { first += 1 }

            let isFence = first + 2 < lineEnd + 1
                && first + 2 < n
                && units[first] == Ch.backtick && units[first + 1] == Ch.backtick && units[first + 2] == Ch.backtick
            if isFence {
                if inFence {
                    tokens.append(SyntaxToken(fenceStart, lineEnd - fenceStart, .string))
                    inFence = false
                } else {
                    inFence = true
                    fenceStart = lineStart
                }
            } else if !inFence {
                if first < lineEnd, units[first] == Ch.hash {
                    tokens.append(SyntaxToken(lineStart, lineEnd - lineStart, .heading))
                } else {
                    if first < lineEnd, units[first] == Ch.greaterThan {
                        tokens.append(SyntaxToken(lineStart, lineEnd - lineStart, .comment))
                    } else if first + 1 < lineEnd,
                              (units[first] == Ch.minus || units[first] == Ch.star || units[first] == Ch.plus),
                              units[first + 1] == Ch.space {
                        tokens.append(SyntaxToken(first, 1, .keyword))
                    }
                    inline(from: first, to: lineEnd, into: &tokens)
                }
            }
            lineStart = lineEnd + 1
        }
        if inFence {
            tokens.append(SyntaxToken(fenceStart, n - fenceStart, .string))
        }
        return tokens
    }

    private func inline(from start: Int, to end: Int, into tokens: inout [SyntaxToken]) {
        var i = start
        while i < end {
            let u = units[i]
            if u == Ch.backtick {
                var j = i + 1
                while j < end, units[j] != Ch.backtick { j += 1 }
                if j < end {
                    tokens.append(SyntaxToken(i, j + 1 - i, .string))
                    i = j + 1
                    continue
                }
            }
            if u == Ch.openBracket {
                var j = i + 1
                while j < end, units[j] != Ch.closeBracket { j += 1 }
                if j + 1 < end, units[j + 1] == Ch.openParen {
                    var k = j + 2
                    while k < end, units[k] != Ch.closeParen { k += 1 }
                    if k < end {
                        tokens.append(SyntaxToken(i, k + 1 - i, .link))
                        i = k + 1
                        continue
                    }
                }
            }
            if u == Ch.star || u == Ch.underscore, i + 1 < end, units[i + 1] == u {
                var j = i + 2
                while j + 1 < end, !(units[j] == u && units[j + 1] == u) { j += 1 }
                if j + 1 < end {
                    tokens.append(SyntaxToken(i, j + 2 - i, .emphasis))
                    i = j + 2
                    continue
                }
            }
            i += 1
        }
    }
}

// MARK: - Characters

private enum Ch {
    static let newline: UInt16 = 10
    static let tab: UInt16 = 9
    static let space: UInt16 = 32
    static let bang: UInt16 = 33
    static let quote: UInt16 = 34
    static let hash: UInt16 = 35
    static let dollar: UInt16 = 36
    static let ampersand: UInt16 = 38
    static let apostrophe: UInt16 = 39
    static let openParen: UInt16 = 40
    static let closeParen: UInt16 = 41
    static let star: UInt16 = 42
    static let plus: UInt16 = 43
    static let minus: UInt16 = 45
    static let dot: UInt16 = 46
    static let slash: UInt16 = 47
    static let colon: UInt16 = 58
    static let semicolon: UInt16 = 59
    static let lessThan: UInt16 = 60
    static let equals: UInt16 = 61
    static let greaterThan: UInt16 = 62
    static let question: UInt16 = 63
    static let at: UInt16 = 64
    static let openBracket: UInt16 = 91
    static let backslash: UInt16 = 92
    static let closeBracket: UInt16 = 93
    static let underscore: UInt16 = 95
    static let backtick: UInt16 = 96
    static let openBrace: UInt16 = 123
    static let closeBrace: UInt16 = 125
}

private func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }
private func isLetter(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) }
