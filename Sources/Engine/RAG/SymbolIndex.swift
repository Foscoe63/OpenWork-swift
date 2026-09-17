import Foundation

/// "Where is `X` defined?" in one hop.
///
/// `grep` answers it in two or three: search the name, get every call site as well as the
/// declaration, then read to work out which is which. On a name used fifty times that is fifty
/// lines of context spent to find one. This indexes declarations only, so the answer is the
/// handful of places something is *introduced*.
///
/// It is a regex scan, not a compiler. It reads what a declaration line looks like in each
/// language and nothing more: no macro expansion, no conditional compilation, no generated code.
/// Line and block comments are skipped, but a declaration written unusually can still be missed.
/// That is acceptable for navigation and not acceptable as proof of absence — `find_symbol`
/// finding nothing means "not found by this scan", which is why the tool says so and points at
/// `grep`.
public actor SymbolIndex {
    public static let shared = SymbolIndex()

    public enum Kind: String, Sendable, Equatable, Hashable {
        case type        // class, struct, enum, protocol, actor, interface, trait
        case function
        case property
        case alias
        case exten       // extension / impl block
    }

    public struct Symbol: Sendable, Equatable {
        public var name: String
        public var kind: Kind
        public var path: String
        public var line: Int
        /// The declaration line itself, trimmed — usually the most useful single line.
        public var text: String

        public var display: String { "\(path):\(line): \(text)" }
    }

    private struct Indexed {
        var symbols: [Symbol]
        var byLowercasedName: [String: [Int]]
        var stamps: [String: Date]
    }

    private var cache: [String: Indexed] = [:]

    // MARK: - Patterns

    /// Declaration shapes, by file extension. Capture group 1 is the name.
    ///
    /// Anchored at the start of the line (after indentation) on purpose: an unanchored `func (\w+)`
    /// matches a closure parameter's type signature and a string in a comment.
    private static let patternsByExtension: [String: [(Kind, String)]] = {
        let swift: [(Kind, String)] = [
            (.type, #"^\s*(?:public |internal |private |fileprivate |package |open |final |@objc |@MainActor |indirect )*(?:class|struct|enum|protocol|actor)\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.function, #"^\s*(?:public |internal |private |fileprivate |package |open |final |static |class |mutating |nonisolated |override |@objc |@MainActor |@discardableResult |convenience |required )*func\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.property, #"^\s*(?:public |internal |private |fileprivate |package |open |final |static |class |lazy |weak |unowned |@Published |@State |@StateObject |@ObservedObject |@EnvironmentObject )*(?:var|let)\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.alias, #"^\s*(?:public |internal |private |fileprivate |package )*typealias\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.exten, #"^\s*(?:public |internal |private |fileprivate |package )*extension\s+([A-Za-z_][A-Za-z_0-9.]*)"#),
        ]
        let python: [(Kind, String)] = [
            (.type, #"^\s*class\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.function, #"^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z_0-9]*)"#),
        ]
        let javascript: [(Kind, String)] = [
            (.type, #"^\s*(?:export\s+)?(?:abstract\s+)?(?:class|interface|enum)\s+([A-Za-z_$][A-Za-z_0-9$]*)"#),
            (.function, #"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z_0-9$]*)"#),
            (.property, #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z_0-9$]*)"#),
            (.alias, #"^\s*(?:export\s+)?type\s+([A-Za-z_$][A-Za-z_0-9$]*)"#),
        ]
        let go: [(Kind, String)] = [
            (.function, #"^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z_0-9]*)"#),
            (.type, #"^\s*type\s+([A-Za-z_][A-Za-z_0-9]*)"#),
        ]
        let rust: [(Kind, String)] = [
            (.function, #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.type, #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|union)\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.alias, #"^\s*(?:pub(?:\([^)]*\))?\s+)?type\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.exten, #"^\s*impl(?:<[^>]*>)?\s+(?:[A-Za-z_][A-Za-z_0-9:<>, ]*\s+for\s+)?([A-Za-z_][A-Za-z_0-9]*)"#),
        ]
        let ruby: [(Kind, String)] = [
            (.type, #"^\s*(?:class|module)\s+([A-Za-z_][A-Za-z_0-9:]*)"#),
            (.function, #"^\s*def\s+(?:self\.)?([A-Za-z_][A-Za-z_0-9!?]*)"#),
        ]
        let jvm: [(Kind, String)] = [
            (.type, #"^\s*(?:public |private |protected |internal |abstract |final |open |sealed |data |static )*(?:class|interface|enum|object)\s+([A-Za-z_][A-Za-z_0-9]*)"#),
            (.function, #"^\s*(?:public |private |protected |internal |static |final |override |suspend |open )*fun\s+([A-Za-z_][A-Za-z_0-9]*)"#),
        ]

        var map: [String: [(Kind, String)]] = [:]
        map["swift"] = swift
        map["py"] = python
        for ext in ["js", "jsx", "ts", "tsx", "mjs", "cjs"] { map[ext] = javascript }
        map["go"] = go
        map["rs"] = rust
        map["rb"] = ruby
        for ext in ["java", "kt", "kts"] { map[ext] = jvm }
        return map
    }()

    private static var compiled: [String: [(Kind, NSRegularExpression)]] = [:]

    private static func regexes(for ext: String) -> [(Kind, NSRegularExpression)]? {
        if let cached = compiled[ext] { return cached }
        guard let patterns = patternsByExtension[ext] else { return nil }
        let built = patterns.compactMap { kind, pattern -> (Kind, NSRegularExpression)? in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (kind, regex)
        }
        compiled[ext] = built
        return built
    }

    /// Whether this index knows anything about a file type at all.
    public nonisolated static func handles(extension ext: String) -> Bool {
        patternsByExtension[ext.lowercased()] != nil
    }

    // MARK: - Building

    @discardableResult
    public func build(root: String) -> Int {
        let paths = CodeSearch.glob(pattern: "**", root: root, limit: 20_000).paths
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        var stamps: [String: Date] = [:]
        var symbols: [Symbol] = []
        let existing = cache[root]

        for relative in paths {
            let ext = (relative as NSString).pathExtension.lowercased()
            guard Self.regexes(for: ext) != nil else { continue }

            let full = rootPrefix + relative
            let attributes = try? FileManager.default.attributesOfItem(atPath: full)
            if let size = attributes?[.size] as? Int, size > CodeIndex.maxFileBytes { continue }
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            stamps[relative] = modified

            if let existing, existing.stamps[relative] == modified {
                symbols.append(contentsOf: existing.symbols.filter { $0.path == relative })
                continue
            }
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            symbols.append(contentsOf: Self.scan(path: relative, content: content, ext: ext))
        }

        var byName: [String: [Int]] = [:]
        for (index, symbol) in symbols.enumerated() {
            byName[symbol.name.lowercased(), default: []].append(index)
        }
        cache[root] = Indexed(symbols: symbols, byLowercasedName: byName, stamps: stamps)
        return symbols.count
    }

    static func scan(path: String, content: String, ext: String) -> [Symbol] {
        guard let regexes = regexes(for: ext) else { return [] }
        var out: [Symbol] = []
        // Tracks `/* … */`, so a declaration commented out in a block is not reported as real.
        // Nesting is counted because Swift allows it; languages that do not are unaffected, since
        // an unnested close still returns the depth to zero.
        var blockCommentDepth = 0

        for (offset, rawLine) in content.components(separatedBy: "\n").enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let wasInBlockComment = blockCommentDepth > 0
            blockCommentDepth = Self.blockCommentDepth(after: line, startingAt: blockCommentDepth, ext: ext)
            if wasInBlockComment { continue }

            // Cheap line-comment rejection.
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") { continue }

            let range = NSRange(line.startIndex..., in: line)
            for (kind, regex) in regexes {
                guard let match = regex.firstMatch(in: line, range: range),
                      match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: line) else { continue }
                out.append(Symbol(
                    name: String(line[nameRange]),
                    kind: kind,
                    path: path,
                    line: offset + 1,
                    text: trimmed
                ))
                // One declaration per line: the first pattern that matches wins, so a
                // `public struct Foo` is not also reported as a property.
                break
            }
        }
        return out
    }

    /// Block-comment depth after reading `line`, given the depth before it.
    ///
    /// Scans character by character rather than counting occurrences, so a `/*` appearing after a
    /// `//` on the same line, or either marker inside a string literal, does not open a comment
    /// that never closes and silently blank the rest of the file.
    static func blockCommentDepth(after line: String, startingAt depth: Int, ext: String) -> Int {
        guard Self.hasBlockComments(ext) else { return 0 }
        var depth = depth
        var inString = false
        var previous: Character? = nil
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            let following = next < line.endIndex ? line[next] : nil

            if depth == 0 && inString {
                if character == "\"" && previous != "\\" { inString = false }
            } else if depth == 0 {
                if character == "\"" {
                    inString = true
                } else if character == "/" && following == "/" {
                    return depth  // Rest of the line is a line comment.
                } else if character == "/" && following == "*" {
                    depth += 1
                    index = next
                }
            } else {
                if character == "*" && following == "/" {
                    depth -= 1
                    index = next
                } else if character == "/" && following == "*" {
                    depth += 1
                    index = next
                }
            }

            previous = character
            index = line.index(after: index)
        }
        return depth
    }

    /// Languages whose `/* … */` this understands. Python and Ruby have no block comment form,
    /// and treating `#` runs as one would be wrong.
    private static func hasBlockComments(_ ext: String) -> Bool {
        !["py", "rb"].contains(ext)
    }

    // MARK: - Lookup

    /// Declarations of `name`, exact matches first.
    ///
    /// Falls back to substring matching only when nothing matches exactly, so searching for a name
    /// that exists does not bury it under longer names that contain it.
    public func lookup(name: String, root: String, limit: Int = 20) -> [Symbol] {
        if cache[root] == nil { build(root: root) }
        guard let index = cache[root] else { return [] }

        let needle = name.lowercased()
        if let exact = index.byLowercasedName[needle], !exact.isEmpty {
            return Array(exact.map { index.symbols[$0] }.sorted(by: Self.declarationOrder).prefix(limit))
        }
        let partial = index.symbols.filter { $0.name.lowercased().contains(needle) }
        return Array(partial.sorted(by: Self.declarationOrder).prefix(limit))
    }

    /// Types and functions before properties and extensions: "where is X defined" almost always
    /// means the type or the function, and a property of the same name is noise above it.
    private static func declarationOrder(_ a: Symbol, _ b: Symbol) -> Bool {
        func rank(_ kind: Kind) -> Int {
            switch kind {
            case .type: return 0
            case .function: return 1
            case .alias: return 2
            case .exten: return 3
            case .property: return 4
            }
        }
        if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
        if a.path != b.path { return a.path < b.path }
        return a.line < b.line
    }

    /// Every declared name in `root`, types and functions first, for editor completion.
    ///
    /// Builds the index if it has not been, and refreshes files whose modification date moved —
    /// `build` reuses unchanged files, so calling this after edits is cheap.
    public func declaredNames(root: String, limit: Int = 5_000) -> [String] {
        build(root: root)
        guard let index = cache[root] else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for symbol in index.symbols.sorted(by: Self.declarationOrder) where seen.insert(symbol.name).inserted {
            names.append(symbol.name)
            if names.count >= limit { break }
        }
        return names
    }

    public func invalidate(root: String) {
        cache.removeValue(forKey: root)
    }

    public func indexedSymbolCount(root: String) -> Int {
        cache[root]?.symbols.count ?? 0
    }

    /// Render for a tool result.
    public nonisolated static func format(_ symbols: [Symbol], name: String) -> String {
        guard !symbols.isEmpty else {
            return "No declaration of \"\(name)\" was found by the symbol scan. "
                + "It indexes declaration lines only and is not exhaustive — use grep to search all text."
        }
        var lines = ["\(symbols.count) declaration(s) matching \"\(name)\":"]
        for symbol in symbols {
            lines.append("  [\(symbol.kind.rawValue)] \(symbol.display)")
        }
        return lines.joined(separator: "\n")
    }
}
