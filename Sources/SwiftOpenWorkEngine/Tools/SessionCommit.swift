import Foundation

/// Commit what a session changed, when the *user* asks to.
///
/// The agent cannot commit on your checkout — `git_commit` is confined to agent worktrees — and
/// that stays true: nothing here is reachable from a tool. This is the button in the session
/// review, so saving a version that works no longer means leaving the app for a terminal.
///
/// Only the session's files are committed. `git commit -- <paths>` takes those paths as they are
/// in the working tree and leaves anything else you had staged out of the commit and still staged.
public enum SessionCommit {

    public enum CommitError: LocalizedError, Equatable {
        case nothingToCommit
        case emptyMessage
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .nothingToCommit: return "None of the selected files have uncommitted changes."
            case .emptyMessage: return "Write a commit message first."
            case .failed(let output): return output
            }
        }
    }

    /// The subset of `paths` (relative to `root`) that git sees as changed or untracked.
    /// Paths outside the repository, ignored files and unchanged files are dropped. Blocking.
    public static func pendingPaths(_ paths: [String], in root: String) -> [String] {
        guard GitTools.isRepository(root) else { return [] }
        return paths.filter { path in
            guard !path.hasPrefix("/") else { return false }
            let output = GitTools.run(["status", "--porcelain", "--untracked-files=all", "--", path], in: root)
            return !(output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A first line to start the message from: the session title when it says something, else a
    /// count. The user edits it before anything is committed.
    public static func suggestedMessage(sessionTitle: String?, paths: [String]) -> String {
        let title = (sessionTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["", "new chat", "new session", "untitled"]
        if !generic.contains(title.lowercased()) { return title }
        if paths.count == 1, let only = paths.first {
            return "Update \((only as NSString).lastPathComponent)"
        }
        return "Update \(paths.count) files"
    }

    /// Stage and commit exactly `paths`. Returns the new commit's short hash.
    public static func commit(paths: [String], message: String, in root: String) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommitError.emptyMessage }
        guard !paths.isEmpty else { throw CommitError.nothingToCommit }
        let dir = URL(fileURLWithPath: root)
        do {
            // -A so deletions are staged too; `--` so a path can never be read as a flag.
            try await AgentWorktree.git(["add", "-A", "--"] + paths, in: dir)
            try await AgentWorktree.git(["commit", "--quiet", "-m", trimmed, "--"] + paths, in: dir)
            return try await AgentWorktree.git(["rev-parse", "--short", "HEAD"], in: dir)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as AgentWorktree.WorktreeError {
            throw CommitError.failed(error.localizedDescription)
        }
    }
}
