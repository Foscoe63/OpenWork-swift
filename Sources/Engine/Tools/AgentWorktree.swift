import Foundation

/// Isolated git worktrees for agent work, and a commit that can only land inside one.
///
/// Git was read-only here on purpose — "committing stays yours" — and that is the right instinct
/// applied in the wrong place. The cost was that an agent had no way to checkpoint across turns,
/// and `FileCheckpointStore` is deliberately turn-scoped, so anything older than the current turn
/// was unrecoverable. Session-wide undo was rejected for a good reason: an agent that can
/// silently revert ten turns of your work is worse than one that cannot revert at all.
///
/// A worktree resolves that rather than trading it off. On a branch of its own, in a directory of
/// its own, commits are additive history rather than a rewrite: nothing the agent does can revert
/// or reword anything you wrote, because it is not writing where you are. `commit` refuses to run
/// anywhere else, which is what keeps the original promise intact.
public enum AgentWorktree {

    public struct Info: Sendable, Equatable {
        public var path: String
        public var branch: String
        public var head: String
    }

    public enum WorktreeError: LocalizedError {
        case notARepository(String)
        case gitFailed(String)
        case notAWorktree(String)
        case nothingToCommit

        public var errorDescription: String? {
            switch self {
            case .notARepository(let path):
                return "\(path) is not inside a git repository, so there is nothing to branch from."
            case .gitFailed(let message):
                return message
            case .notAWorktree(let path):
                return """
                \(path) is not an agent worktree, so committing there is refused.
                Commits are confined to worktrees created by worktree_create: on your own checkout, \
                committing stays yours. Create one first, or commit this yourself.
                """
            case .nothingToCommit:
                return "Nothing staged or changed in the worktree — no commit made."
            }
        }
    }

    /// Where agent worktrees live: beside the repo, never inside it, so they are never picked up
    /// by the parent's own status, build, or file search.
    public static func container(for repoRoot: URL) -> URL {
        repoRoot.deletingLastPathComponent()
            .appendingPathComponent(".openwork-worktrees/\(repoRoot.lastPathComponent)", isDirectory: true)
    }

    @discardableResult
    public static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw WorktreeError.gitFailed("git \(arguments.joined(separator: " ")) failed:\n\(output)")
        }
        return output
    }

    public static func repositoryRoot(containing path: String) throws -> URL {
        let directory = URL(fileURLWithPath: path)
        do {
            let out = try git(["rev-parse", "--show-toplevel"], in: directory)
            return URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw WorktreeError.notARepository(path)
        }
    }

    /// Create a worktree on a new branch. Returns the worktree directory.
    public static func create(workspacePath: String, name: String) throws -> Info {
        let root = try repositoryRoot(containing: workspacePath)
        let slug = sanitize(name)
        let branch = "openwork/\(slug)"
        let dir = container(for: root).appendingPathComponent(slug, isDirectory: true)

        try FileManager.default.createDirectory(
            at: dir.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: dir.path) {
            // Reuse rather than fail: re-running the same task should land in the same place.
            let head = (try? git(["rev-parse", "--short", "HEAD"], in: dir)) ?? ""
            return Info(path: dir.path, branch: branch, head: head.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // `-B` so an abandoned branch from a previous run is reset rather than colliding.
        try git(["worktree", "add", "-B", branch, dir.path], in: root)
        let head = try git(["rev-parse", "--short", "HEAD"], in: dir)
        return Info(path: dir.path, branch: branch, head: head.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func list(workspacePath: String) throws -> [Info] {
        let root = try repositoryRoot(containing: workspacePath)
        let output = try git(["worktree", "list", "--porcelain"], in: root)
        var result: [Info] = []
        var path = "", branch = "", head = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)).prefix(7).description }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if line.isEmpty, !path.isEmpty {
                if branch.hasPrefix("openwork/") { result.append(Info(path: path, branch: branch, head: head)) }
                path = ""; branch = ""; head = ""
            }
        }
        if !path.isEmpty, branch.hasPrefix("openwork/") {
            result.append(Info(path: path, branch: branch, head: head))
        }
        return result
    }

    public static func remove(workspacePath: String, name: String, force: Bool) throws -> String {
        let root = try repositoryRoot(containing: workspacePath)
        let slug = sanitize(name)
        let dir = container(for: root).appendingPathComponent(slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return "No worktree named '\(slug)'."
        }
        // Refuse to discard uncommitted work unless told twice: the worktree is where the agent's
        // output lives, and removing it is the one irreversible thing here.
        let dirty = try git(["status", "--porcelain"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        if !dirty.isEmpty && !force {
            throw WorktreeError.gitFailed("""
            '\(slug)' has uncommitted changes:
            \(dirty)
            Commit them, or pass force: true to discard them permanently.
            """)
        }
        try git(["worktree", "remove", force ? "--force" : "--", force ? dir.path : dir.path], in: root)
        return "Removed worktree '\(slug)'. Its branch openwork/\(slug) still exists — delete it with git if you do not want it."
    }

    /// Whether `path` is inside a worktree this type created.
    public static func isAgentWorktree(_ path: String) -> Bool {
        guard let root = try? repositoryRoot(containing: path) else { return false }
        guard let branch = try? git(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: path)) else {
            return false
        }
        // Both halves must hold: the branch is ours *and* this is not the primary checkout.
        let isOurBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("openwork/")
        let isLinkedWorktree = root.path != URL(fileURLWithPath: path).path
            || (try? git(["rev-parse", "--git-common-dir"], in: URL(fileURLWithPath: path)))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".git") && $0.contains("/") } ?? false
        return isOurBranch && isLinkedWorktree
    }

    /// Commit everything in an agent worktree. Refuses anywhere else.
    public static func commit(worktreePath: String, message: String) throws -> String {
        guard isAgentWorktree(worktreePath) else {
            throw WorktreeError.notAWorktree(worktreePath)
        }
        let dir = URL(fileURLWithPath: worktreePath)
        let dirty = try git(["status", "--porcelain"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dirty.isEmpty else { throw WorktreeError.nothingToCommit }

        try git(["add", "-A"], in: dir)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["commit", "-m", trimmed.isEmpty ? "Agent checkpoint" : trimmed], in: dir)
        let head = try git(["rev-parse", "--short", "HEAD"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        let stat = try git(["show", "--stat", "--format=%s", "HEAD"], in: dir)
        return "Committed \(head) on \(try branchName(in: dir)):\n\(stat)"
    }

    static func branchName(in directory: URL) throws -> String {
        try git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A branch- and path-safe slug. Git refuses a lot of characters in ref names, and a tool
    /// argument is whatever the model felt like typing.
    public static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = collapsed.isEmpty ? "task" : collapsed
        return String(trimmed.prefix(48))
    }
}
