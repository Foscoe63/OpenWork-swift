import Foundation

/// Decides whether a cached MLX chat session can be continued, or must be rebuilt.
///
/// Rebuilding a `ChatSession` every turn makes MLX re-prefill the whole conversation, so
/// time-to-first-token grows with the transcript: measured on a 48B model, 1.5s at three
/// messages and 3.5s at eleven, climbing from there, versus a flat 0.9s when the session is
/// reused. In an agent loop the same cost is paid again on every tool-call iteration, not just
/// once per user turn.
///
/// The cache is only safe while the new message list *extends* what the session has already
/// consumed. If earlier messages changed — compaction rewriting history is the common case — the
/// cached KV entries describe text that is no longer in the conversation, and continuing would
/// let deleted context keep steering the model with nothing visible to explain it. That is worse
/// than being slow, so divergence rebuilds.
public enum MLXSessionReuse {

    /// Identity of a session. Anything here changing means a different conversation.
    public struct Key: Equatable, Sendable {
        public var modelId: String
        public var instructions: String
        /// Tool names, sorted. A changed tool list changes the prompt the template renders.
        public var toolNames: [String]

        public init(modelId: String, instructions: String, toolNames: [String]) {
            self.modelId = modelId
            self.instructions = instructions
            self.toolNames = toolNames.sorted()
        }
    }

    /// A message reduced to what actually affects the cache.
    public struct Fingerprint: Equatable, Sendable {
        public var role: String
        public var content: String
        /// Attachments are not compared; a message carrying any blocks reuse outright.
        public var hasAttachments: Bool
        /// Set on a reply this session generated itself.
        ///
        /// The session's copy is authoritative, but the caller sends back a *rendering* of the
        /// same generation — reasoning split out, tool-call syntax stripped — which never matches
        /// the raw text byte for byte. Comparing them strictly rebuilt the cache on every
        /// iteration, so this position matches any assistant message instead. The position and
        /// role are still checked; only the text is taken on trust, and only for text this
        /// session produced.
        public var isGeneratedReply: Bool

        public init(
            role: String,
            content: String,
            hasAttachments: Bool = false,
            isGeneratedReply: Bool = false
        ) {
            self.role = role
            self.content = content
            self.hasAttachments = hasAttachments
            self.isGeneratedReply = isGeneratedReply
        }

        /// Whether `incoming` can stand in for this consumed message.
        func matches(_ incoming: Fingerprint) -> Bool {
            if isGeneratedReply {
                return incoming.role == role
            }
            return incoming.role == role
                && incoming.content == content
                && incoming.hasAttachments == hasAttachments
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Continue the cached session, feeding only these messages.
        case advance(newMessages: ArraySlice<Fingerprint>)
        /// Discard and build from scratch, for the stated reason.
        case rebuild(reason: String)
    }

    /// Whether `incoming` can continue a session that has already consumed `consumed`.
    public static func decide(
        cachedKey: Key?,
        cachedConsumed: [Fingerprint],
        incomingKey: Key,
        incoming: [Fingerprint]
    ) -> Decision {
        guard let cachedKey else {
            return .rebuild(reason: "no cached session")
        }
        guard cachedKey == incomingKey else {
            return .rebuild(reason: "model, instructions or tool set changed")
        }
        guard !cachedConsumed.isEmpty else {
            return .rebuild(reason: "cached session has consumed nothing")
        }
        guard incoming.count >= cachedConsumed.count else {
            // Fewer messages than before means history was rewritten, not appended.
            return .rebuild(reason: "history shrank — prefix was rewritten")
        }
        // Every consumed message must still be present, unchanged, in the same position.
        for (index, previous) in cachedConsumed.enumerated() where !previous.matches(incoming[index]) {
            return .rebuild(reason: "history diverged at message \(index + 1)")
        }
        if incoming.contains(where: \.hasAttachments) {
            return .rebuild(reason: "attachments are not compared, so reuse is unsafe")
        }
        let new = incoming[cachedConsumed.count...]
        guard !new.isEmpty else {
            // Nothing new to say. Re-sending the last message would duplicate it in the cache.
            return .rebuild(reason: "no new messages to append")
        }
        return .advance(newMessages: new)
    }
}
