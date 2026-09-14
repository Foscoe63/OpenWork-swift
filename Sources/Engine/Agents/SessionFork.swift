import Foundation

/// Branch a session at a chosen message.
///
/// The real failure this addresses: a long session that went 80% right and then took one bad turn.
/// Today the only recoveries are to argue with the model inside the same transcript — which keeps
/// the bad turn in context, steering everything after it — or to start over and lose the 80%.
///
/// What a fork can and cannot do is worth stating exactly, because the tempting version is a lie.
/// A fork branches **conversation state**. It does not roll back the **working tree**:
/// `FileCheckpointStore` is deliberately turn-scoped (`beginTurn` discards the previous window,
/// because an agent that can silently revert ten turns of your work is worse than one that cannot
/// revert at all), and nothing else records file contents from ten turns ago.
///
/// So a fork that quietly restored files would be restoring them from nowhere, and a fork that
/// said nothing would leave the user with a transcript claiming turn 4 while their files are at
/// turn 9. Instead the fork carries a note naming every file the discarded turns touched. The user
/// keeps their edits and knows exactly where the two disagree — which git can then settle.
public enum SessionFork {

    public struct Outcome: Sendable {
        public var session: Session
        /// Files the discarded turns wrote, edited or deleted. Still on disk.
        public var divergedFiles: [String]
    }

    /// Fork `session` so it ends at `messageId` inclusive.
    ///
    /// Returns nil when the message is not in the session, or when it is already the last one —
    /// forking at the end would produce a copy, not a branch.
    public static func fork(_ session: Session, at messageId: String) -> Outcome? {
        guard let cut = session.messages.firstIndex(where: { $0.id == messageId }) else { return nil }
        guard cut < session.messages.count - 1 else { return nil }

        let kept = Array(session.messages[0...cut])
        let discarded = Array(session.messages[(cut + 1)...])

        var forked = session
        forked.id = UUID().uuidString
        forked.title = forkTitle(from: session.title)
        forked.createdAt = Date()
        forked.updatedAt = Date()
        forked.isPinned = false
        forked.isArchived = false
        forked.forkedFromSessionId = session.id
        forked.forkedAtMessageId = messageId
        // Sub-agent tasks and inter-agent traffic belong to turns that no longer exist here.
        forked.activeSubAgentTasks = []
        forked.interAgentMessages = []
        // Token totals describe the original run; carrying them forward would double-count.
        forked.totalPromptTokens = 0
        forked.totalCompletionTokens = 0
        forked.estimatedCost = 0

        // Rebind messages to the new session so the two transcripts cannot alias each other.
        forked.messages = kept.map { message in
            var copy = message
            copy.sessionId = forked.id
            return copy
        }

        let facts = ContextCompactor.digest(of: discarded)
        let divergedFiles = orderedUnique(facts.filesEdited + facts.filesWritten + facts.filesDeleted)

        if let note = divergenceNote(discardedTurns: discarded.count, files: divergedFiles, sessionId: forked.id) {
            forked.messages.append(note)
        }

        return Outcome(session: forked, divergedFiles: divergedFiles)
    }

    /// The message that tells the next turn — and the user — where the transcript and the disk
    /// disagree. Omitted when the discarded turns touched no files, since then they do not.
    private static func divergenceNote(discardedTurns: Int, files: [String], sessionId: String) -> ChatMessage? {
        guard !files.isEmpty else { return nil }
        let content = """
        [Forked here] The \(discardedTurns) message(s) after this point were left behind, but their \
        file changes were not undone — they are still on disk: \(files.joined(separator: ", ")).

        Re-read any of those files before relying on what this conversation says about them.
        """
        return ChatMessage(sessionId: sessionId, role: .user, content: content)
    }

    private static func forkTitle(from title: String) -> String {
        // "Fix the parser (fork 2)" rather than "Fix the parser (fork) (fork)".
        let pattern = #"^(.*) \(fork( \d+)?\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let baseRange = Range(match.range(at: 1), in: title) else {
            return "\(title) (fork)"
        }
        let base = String(title[baseRange])
        var number = 2
        if let numRange = Range(match.range(at: 2), in: title),
           let parsed = Int(title[numRange].trimmingCharacters(in: .whitespaces)) {
            number = parsed + 1
        }
        return "\(base) (fork \(number))"
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
