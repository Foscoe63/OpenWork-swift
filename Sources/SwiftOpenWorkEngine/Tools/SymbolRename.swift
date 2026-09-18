import Foundation
import SwiftOpenWorkCore

/// Rename a symbol across the workspace.
///
/// Two ways, and the output always says which one ran:
/// - **compiler** — `SemanticRename` asks the file's language server for the occurrences of *that*
///   declaration. Needs a server and a project root (`LanguageServerCatalog`).
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
        /// The language server behind a "compiler" result.
        public var server: String?
        /// What each written file looked like before and after, for the tool card. Empty on a dry run.
        public var diffs: [InlineFileDiff] = []

        public var summary: String {
            var lines: [String] = []
            if dryRun {
                lines.append("Dry run — nothing was written.")
            }
            lines.append(method == "compiler"
                ? "Method: compiler index (\(server ?? "language server")) — only references to this declaration."
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
        /// The compiler rename was planned and writing it failed. Never falls back to text: the
        /// workspace was touched, and a second, different rename on top would compound it.
        case writeFailed(String)

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
            case .writeFailed(let reason):
                return "The rename could not be written: \(reason)"
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

    public static let matchLimit = 20_000

    public static func rename(
        oldName: String,
        newName: String,
        root: String,
        pathHint: String? = nil,
        dryRun: Bool = false,
        mode: Mode = .text,
        declarationLine: Int? = nil,
        fileManager: FileManager = .default,
        onProgress: CodeIntelligence.ProgressHandler? = nil
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
                    pathHint: pathHint, declarationLine: declarationLine, dryRun: dryRun,
                    onProgress: onProgress
                )
            } catch let failure as SemanticRename.Failure {
                guard mode == .auto else {
                    throw Failure.compilerRenameUnavailable(failure.localizedDescription)
                }
                fallbackNote = "Compiler rename not used: \(failure.localizedDescription)"
            } catch let failure as Failure {
                if case .writeFailed = failure { throw failure }
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
        dryRun: Bool,
        onProgress: CodeIntelligence.ProgressHandler?
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
                throw SemanticRename.Failure.positionNotFound("No declaration of '\(old)' matches the given path and line.")
            }
            throw Failure.ambiguous(candidates.map { "\($0.path):\($0.line)" })
        }
        let file = rootPrefix + declaration.path
        let plan = try await SemanticRename.plan(
            workspaceRoot: root, file: file, line: declaration.line, name: old, newName: new,
            onProgress: onProgress
        )

        let standardRoot = LanguageServerCatalog.standardized(root)
        var planned: [(absolute: String, relative: String, before: String, after: String, count: Int)] = []
        var notes: [String] = plan.notes
        for (path, fileEdits) in plan.edits.sorted(by: { $0.key < $1.key }) {
            guard path.hasPrefix(standardRoot + "/") else {
                notes.append("Not edited, outside the workspace: \(path)")
                continue
            }
            let relative = String(path.dropFirst(standardRoot.count + 1))
            guard let before = try? String(contentsOfFile: path, encoding: .utf8),
                  let after = SemanticRename.apply(fileEdits, to: before, expected: old) else {
                // A stale edit position would corrupt the file. Refuse the whole rename rather
                // than write the files that did apply — half a rename does not compile either.
                throw Failure.compilerRenameUnavailable("the index is out of date for \(relative): its edits do not line up with '\(old)' in the file.")
            }
            planned.append((path, relative, before, after, fileEdits.count))
        }

        let total = planned.reduce(0) { $0 + $1.count }
        if dryRun {
            return Outcome(filesChanged: planned.map(\.relative), occurrenceCount: total, dryRun: true, notes: notes, method: "compiler", server: plan.server)
        }

        var written: [(absolute: String, relative: String, before: String, after: String, count: Int)] = []
        for file in planned where file.before != file.after {
            await FileCheckpointStore.shared.record(path: file.absolute)
            do {
                try file.after.write(toFile: file.absolute, atomically: true, encoding: .utf8)
                written.append(file)
            } catch {
                // All or nothing: put back what was already written, so the workspace is left as
                // it was rather than half renamed.
                var unrestored: [String] = []
                for done in written {
                    if (try? done.before.write(toFile: done.absolute, atomically: true, encoding: .utf8)) == nil {
                        unrestored.append(done.relative)
                    }
                }
                await LanguageServerPool.shared.filesChanged(written.map(\.absolute))
                let restoredNote = unrestored.isEmpty
                    ? "Files already written were restored."
                    : "These files could not be restored and are renamed: \(unrestored.joined(separator: ", ")). revert_changes can undo them."
                throw Failure.writeFailed("writing \(file.relative) failed (\(error.localizedDescription)). \(restoredNote)")
            }
        }
        await LanguageServerPool.shared.filesChanged(written.map(\.absolute))
        let diffs = written.compactMap { InlineFileDiff.between(before: $0.before, after: $0.after, path: $0.absolute) }
        if !written.isEmpty {
            await SymbolIndex.shared.invalidate(root: root)
        }
        return Outcome(filesChanged: written.map(\.relative), occurrenceCount: total, dryRun: false, notes: notes, method: "compiler", server: plan.server, diffs: diffs)
    }
}
