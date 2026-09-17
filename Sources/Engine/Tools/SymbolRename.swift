import Foundation

/// Rename a symbol across the workspace.
///
/// Two ways, and the output always says which one ran:
/// - **compiler** — `SourceKitRename` asks `sourcekit-lsp` for the occurrences of *that*
///   declaration. Swift packages only.
/// - **text** — declaration lookup plus whole-word replacement. It cannot tell `Alpha.value` from
///   `Beta.value`, and it renames the word in comments and strings too.
///
/// `auto` tries the compiler where it applies and falls back to text *with the reason stated*.
/// Prefer `dry_run` first on large renames.
public enum SymbolRename {

    public enum Mode: String, Sendable {
        case auto
        case semantic
        case text
    }

    public struct Outcome: Sendable {
        public var filesChanged: [String]
        public var occurrenceCount: Int
        public var dryRun: Bool
        public var notes: [String]
        /// Which strategy produced this result: "compiler" or "text".
        public var method: String = "text"
        /// What each written file looked like before and after, for the tool card. Empty on a dry run.
        public var diffs: [InlineFileDiff] = []

        public var summary: String {
            var lines: [String] = []
            if dryRun {
                lines.append("Dry run — nothing was written.")
            }
            lines.append(method == "compiler"
                ? "Method: compiler index (sourcekit-lsp) — only references to this declaration."
                : "Method: whole-word text replacement — also renames same-named symbols, comments and strings. Review the diff.")
            lines.append("\(occurrenceCount) occurrence\(occurrenceCount == 1 ? "" : "s") across \(filesChanged.count) file\(filesChanged.count == 1 ? "" : "s").")
            if !filesChanged.isEmpty {
                lines.append("Files:")
                lines.append(contentsOf: filesChanged.prefix(40).map { "  - \($0)" })
            }
            lines.append(contentsOf: notes)
            return lines.joined(separator: "\n")
        }
    }

    public enum Failure: Error, LocalizedError {
        case emptyNames
        case sameNames
        case invalidIdentifier(String)
        case notFound(String)
        case ambiguous([String])
        case tooManyMatches(Int)
        case compilerRenameUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .emptyNames:
                return "rename_symbol requires `old_name` and `new_name`."
            case .sameNames:
                return "old_name and new_name are the same."
            case .invalidIdentifier(let name):
                return "'\(name)' is not a safe identifier for automated rename."
            case .notFound(let name):
                return "No declaration named '\(name)' was found. Use find_symbol or grep first."
            case .ambiguous(let paths):
                return "Multiple declarations found (\(paths.joined(separator: ", "))). Pass `path` to disambiguate."
            case .compilerRenameUnavailable(let reason):
                return "Compiler rename was requested and could not run: \(reason) Nothing was written. Use mode \"text\" to rename by whole-word replacement instead."
            case .tooManyMatches(let limit):
                return "More than \(limit) occurrences matched, so the file list is incomplete and a rename would miss some. Nothing was written. Pass `path` to narrow it."
            }
        }
    }

    private static let identifierPattern = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#)

    public static func isSafeIdentifier(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return identifierPattern.firstMatch(in: name, range: range) != nil
    }

    static let matchLimit = 20_000

    public static func rename(
        oldName: String,
        newName: String,
        root: String,
        pathHint: String? = nil,
        dryRun: Bool = false,
        mode: Mode = .text,
        declarationLine: Int? = nil,
        fileManager: FileManager = .default
    ) async throws -> Outcome {
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty else { throw Failure.emptyNames }
        guard old != new else { throw Failure.sameNames }
        guard isSafeIdentifier(old), isSafeIdentifier(new) else {
            throw Failure.invalidIdentifier(isSafeIdentifier(old) ? new : old)
        }

        let symbols = await SymbolIndex.shared.lookup(name: old, root: root, limit: 40)
        if symbols.isEmpty {
            throw Failure.notFound(old)
        }
        if pathHint == nil, Set(symbols.map(\.path)).count > 1 {
            throw Failure.ambiguous(Array(Set(symbols.map(\.path))).sorted())
        }

        var fallbackNote: String?
        if mode != .text {
            do {
                return try await renameWithCompiler(
                    symbols: symbols, old: old, new: new, root: root,
                    pathHint: pathHint, declarationLine: declarationLine, dryRun: dryRun
                )
            } catch let failure as SourceKitRename.Failure {
                guard mode == .auto else {
                    throw Failure.compilerRenameUnavailable(failure.localizedDescription)
                }
                fallbackNote = "Compiler rename not used: \(failure.localizedDescription)"
            } catch let failure as Failure {
                guard mode == .auto else { throw failure }
                fallbackNote = "Compiler rename not used: \(failure.localizedDescription)"
            }
        }

        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: old) + #"\b"#
        let regex = try NSRegularExpression(pattern: pattern)

        var include: String? = nil
        if let hint = pathHint, !hint.isEmpty {
            include = hint.contains("*") ? hint : "**/\(hint)"
        }

        let grep = try CodeSearch.grep(
            pattern: pattern,
            root: root,
            include: include,
            caseInsensitive: false,
            limit: matchLimit
        )
        // The match list is how files are discovered. A capped list is a partial rename that
        // reports itself as complete, so refuse before writing anything.
        guard !grep.truncated else { throw Failure.tooManyMatches(matchLimit) }

        var byFile: [String: Int] = [:]
        for match in grep.matches {
            byFile[match.path, default: 0] += 1
        }

        var changed: [String] = []
        var diffs: [InlineFileDiff] = []
        var total = 0
        var notes: [String] = fallbackNote.map { [$0] } ?? []
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        for (relative, _) in byFile.sorted(by: { $0.key < $1.key }) {
            let absolute = rootPrefix + relative
            guard let content = try? String(contentsOfFile: absolute, encoding: .utf8) else {
                notes.append("Skipped unreadable file: \(relative)")
                continue
            }
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.numberOfMatches(in: content, range: range)
            guard matches > 0 else { continue }
            total += matches
            if dryRun {
                changed.append(relative)
                continue
            }
            await FileCheckpointStore.shared.record(path: absolute)
            let updated = regex.stringByReplacingMatches(
                in: content,
                options: [],
                range: range,
                withTemplate: new
            )
            do {
                try updated.write(toFile: absolute, atomically: true, encoding: .utf8)
                changed.append(relative)
                if let diff = InlineFileDiff.between(before: content, after: updated, path: absolute) {
                    diffs.append(diff)
                }
            } catch {
                notes.append("Failed to write \(relative): \(error.localizedDescription)")
            }
        }

        if !dryRun, !changed.isEmpty {
            await SymbolIndex.shared.invalidate(root: root)
        }

        if changed.isEmpty && notes.isEmpty {
            notes.append("Pattern matched declarations but no editable text occurrences were found.")
        }

        return Outcome(filesChanged: changed, occurrenceCount: total, dryRun: dryRun, notes: notes, diffs: diffs)
    }

    // MARK: - Compiler

    private static func renameWithCompiler(
        symbols: [SymbolIndex.Symbol],
        old: String,
        new: String,
        root: String,
        pathHint: String?,
        declarationLine: Int?,
        dryRun: Bool
    ) async throws -> Outcome {
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        var candidates = symbols.filter { $0.name == old }
        if let hint = pathHint, !hint.isEmpty, !hint.contains("*") {
            candidates = candidates.filter { $0.path == hint || $0.path.hasSuffix("/" + hint) || rootPrefix + $0.path == hint }
        }
        if let declarationLine {
            candidates = candidates.filter { $0.line == declarationLine }
        }
        // The compiler renames exactly one declaration, so it has to be told which. Two
        // declarations in one file — `Alpha.value` and `Beta.value` — are the case this mode
        // exists for, and guessing the first would rename the wrong one precisely.
        guard candidates.count == 1, let declaration = candidates.first else {
            if candidates.isEmpty {
                throw SourceKitRename.Failure.positionNotFound(old)
            }
            throw Failure.ambiguous(candidates.map { "\($0.path):\($0.line)" })
        }
        let file = rootPrefix + declaration.path
        guard SourceKitRename.isCandidate(root: root, declarationPath: file) else {
            throw SourceKitRename.Failure.notASwiftPackage
        }

        let edits = try await SourceKitRename.edits(
            root: root, file: file, line: declaration.line, name: old, newName: new
        )

        let standardRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        // The server can name one file by two paths — the URI it was opened with and the path its
        // index recorded, e.g. /var/… and /private/var/…. Applied separately, the second copy
        // rewrites a file the first already rewrote. Merge on the resolved path.
        var merged: [String: [SourceKitRename.TextEdit]] = [:]
        for (path, fileEdits) in edits {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            for edit in fileEdits where !(merged[resolved]?.contains(edit) ?? false) {
                merged[resolved, default: []].append(edit)
            }
        }

        var planned: [(absolute: String, relative: String, before: String, after: String, count: Int)] = []
        var notes: [String] = []
        for (resolved, fileEdits) in merged.sorted(by: { $0.key < $1.key }) {
            let path = resolved
            guard resolved.hasPrefix(standardRoot + "/") else {
                notes.append("Not edited, outside the workspace: \(path)")
                continue
            }
            let relative = String(resolved.dropFirst(standardRoot.count + 1))
            guard let before = try? String(contentsOfFile: path, encoding: .utf8),
                  let after = SourceKitRename.apply(fileEdits, to: before) else {
                // A stale edit position would corrupt the file. Refuse the whole rename rather
                // than write the files that did apply — half a rename does not compile either.
                throw Failure.compilerRenameUnavailable("the index is out of date for \(relative).")
            }
            planned.append((path, relative, before, after, fileEdits.count))
        }

        let total = planned.reduce(0) { $0 + $1.count }
        if dryRun {
            return Outcome(filesChanged: planned.map(\.relative), occurrenceCount: total, dryRun: true, notes: notes, method: "compiler")
        }

        var changed: [String] = []
        var diffs: [InlineFileDiff] = []
        for plan in planned where plan.before != plan.after {
            await FileCheckpointStore.shared.record(path: plan.absolute)
            do {
                try plan.after.write(toFile: plan.absolute, atomically: true, encoding: .utf8)
                changed.append(plan.relative)
                if let diff = InlineFileDiff.between(before: plan.before, after: plan.after, path: plan.absolute) {
                    diffs.append(diff)
                }
            } catch {
                notes.append("Failed to write \(plan.relative): \(error.localizedDescription)")
            }
        }
        if !changed.isEmpty {
            await SymbolIndex.shared.invalidate(root: root)
        }
        return Outcome(filesChanged: changed, occurrenceCount: total, dryRun: false, notes: notes, method: "compiler", diffs: diffs)
    }
}
