import Foundation

/// What one tool call did to one file, small enough to sit inside a chat card.
///
/// The transcript already said `edit_file` had succeeded and named the path. What it never said was
/// *what changed* — which is the only part a reviewer actually reads. Reviewing meant opening the
/// turn review sheet, which covers the whole turn, or opening the file in an editor and guessing.
///
/// This is deliberately a rendered diff rather than both sides of the file: it is stored in the
/// session transcript, so a twenty-turn refactor of a large file must not carry forty copies of it.
/// The full contents are still on disk, and the turn checkpoint still holds the real "before".
public struct InlineFileDiff: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case created
        case modified
        case deleted
    }

    public struct Line: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case added
            case removed
            case context
            /// Stands in for lines skipped between hunks.
            case gap
        }

        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?

        public var id: String { "\(kind.rawValue)-\(oldNumber ?? -1)-\(newNumber ?? -1)-\(text.hashValue)" }
    }

    public var path: String
    public var kind: Kind
    public var added: Int
    public var removed: Int
    public var lines: [Line]
    /// True when the file changed more than the card is willing to show.
    public var truncated: Bool

    public var isEmpty: Bool { added == 0 && removed == 0 }

    /// Past this a file is being generated, not edited, and a line-by-line diff is noise.
    static let maxRenderedLines = 60
    /// The LCS table is O(old × new); beyond this the counts are reported without the body.
    static let maxComparableLines = 4_000
    static let contextLines = 2

    public init(
        path: String,
        kind: Kind,
        added: Int,
        removed: Int,
        lines: [Line],
        truncated: Bool
    ) {
        self.path = path
        self.kind = kind
        self.added = added
        self.removed = removed
        self.lines = lines
        self.truncated = truncated
    }

    /// Bound a multi-file change for storage in the transcript.
    ///
    /// Every file keeps its path and counts, so the card can list the whole set — showing one of
    /// eleven files is worse than showing none. Bodies are kept only until the budget runs out;
    /// past that a file is marked truncated with no body, and the card says to open it.
    public static func boundedSet(
        _ diffs: [InlineFileDiff],
        maxFilesWithBodies: Int = 12,
        maxTotalLines: Int = 240
    ) -> [InlineFileDiff] {
        var used = 0
        var withBodies = 0
        return diffs.map { diff in
            var diff = diff
            if withBodies < maxFilesWithBodies, used + diff.lines.count <= maxTotalLines {
                used += diff.lines.count
                if !diff.lines.isEmpty { withBodies += 1 }
            } else if !diff.lines.isEmpty {
                diff.lines = []
                diff.truncated = true
            }
            return diff
        }
    }

    /// Build a diff, or nil when nothing actually changed.
    ///
    /// A tool reporting success having changed nothing is common and worth not drawing: `file_write`
    /// with identical contents, an edit whose replacement equals the original.
    public static func between(before: String?, after: String?, path: String) -> InlineFileDiff? {
        guard before != after else { return nil }

        let kind: Kind
        switch (before, after) {
        case (nil, .some): kind = .created
        case (.some, nil): kind = .deleted
        default: kind = .modified
        }

        let oldLines = splitLines(before)
        let newLines = splitLines(after)

        guard oldLines.count <= maxComparableLines, newLines.count <= maxComparableLines else {
            return InlineFileDiff(
                path: path,
                kind: kind,
                added: newLines.count,
                removed: oldLines.count,
                lines: [],
                truncated: true
            )
        }

        let script = diff(old: oldLines, new: newLines)
        let added = script.filter { $0.kind == .added }.count
        let removed = script.filter { $0.kind == .removed }.count
        guard added > 0 || removed > 0 else { return nil }

        let (body, truncated) = condense(script)
        return InlineFileDiff(
            path: path,
            kind: kind,
            added: added,
            removed: removed,
            lines: body,
            truncated: truncated
        )
    }

    private static func splitLines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        // A trailing newline is a line terminator, not an empty final line.
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Diff

    /// Longest common subsequence, walked back into an edit script.
    ///
    /// Heuristic diffs (advance whichever side matches next) mislabel a moved block as a wholesale
    /// rewrite, which is exactly the case a reviewer needs read correctly.
    static func diff(old: [String], new: [String]) -> [Line] {
        let n = old.count
        let m = new.count
        if n == 0 {
            return new.enumerated().map { Line(kind: .added, text: $1, oldNumber: nil, newNumber: $0 + 1) }
        }
        if m == 0 {
            return old.enumerated().map { Line(kind: .removed, text: $1, oldNumber: $0 + 1, newNumber: nil) }
        }

        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var lines: [Line] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                lines.append(Line(kind: .context, text: old[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                lines.append(Line(kind: .removed, text: old[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            } else {
                lines.append(Line(kind: .added, text: new[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            }
        }
        while i < n {
            lines.append(Line(kind: .removed, text: old[i], oldNumber: i + 1, newNumber: nil))
            i += 1
        }
        while j < m {
            lines.append(Line(kind: .added, text: new[j], oldNumber: nil, newNumber: j + 1))
            j += 1
        }
        return lines
    }

    /// Keep changed lines plus a little context, drop the untouched middle of the file.
    static func condense(_ script: [Line]) -> ([Line], Bool) {
        let changedIndices = script.indices.filter { script[$0].kind != .context }
        guard !changedIndices.isEmpty else { return ([], false) }

        var keep = Set<Int>()
        for index in changedIndices {
            for offset in -contextLines...contextLines {
                let candidate = index + offset
                if script.indices.contains(candidate) { keep.insert(candidate) }
            }
        }

        var out: [Line] = []
        var previous: Int?
        var truncated = false
        for index in keep.sorted() {
            if let previous, index > previous + 1 {
                out.append(Line(kind: .gap, text: "⋯", oldNumber: nil, newNumber: nil))
            }
            if out.count >= maxRenderedLines {
                truncated = true
                break
            }
            out.append(script[index])
            previous = index
        }
        return (out, truncated)
    }
}
