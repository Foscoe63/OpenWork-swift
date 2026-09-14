import Foundation

/// Summarize older conversation turns when context grows past the configured threshold
/// (Radiant `compactSession` / `foldOldToolResults` parity).
public enum ContextCompactor {
    /// Fold oversized tool observations into short stubs; keep the last `keepLast` tool results intact.
    public static func foldOldToolResults(_ messages: [ChatMessage], keepLast: Int = 4) -> [ChatMessage] {
        var toolIndices: [Int] = []
        for (i, m) in messages.enumerated() where m.role == .tool {
            toolIndices.append(i)
        }
        guard toolIndices.count > keepLast else { return messages }

        let foldSet = Set(toolIndices.dropLast(keepLast))
        return messages.enumerated().map { i, m in
            guard foldSet.contains(i), m.role == .tool, m.content.count > 500 else { return m }
            var copy = m
            let preview = String(m.content.prefix(180)).replacingOccurrences(of: "\n", with: " ")
            copy.content = "[Earlier tool result compacted] \(preview)…"
            return copy
        }
    }

    /// Drop middle messages when over token estimate; keep system-ish head and recent tail.
    public static func compactIfNeeded(
        _ messages: [ChatMessage],
        thresholdTokens: Int,
        keepRecent: Int = 12
    ) -> (messages: [ChatMessage], didCompact: Bool) {
        let estimate = estimateTokens(messages)
        guard estimate > thresholdTokens, messages.count > keepRecent + 2 else {
            return (messages, false)
        }
        let head = Array(messages.prefix(1))
        let tail = Array(messages.suffix(keepRecent))
        let summary = ChatMessage(
            sessionId: messages.first?.sessionId ?? "",
            role: .user,
            content: "[System] Earlier conversation was compacted to free context (\(estimate)≈tokens → kept last \(keepRecent) messages). Continue from the recent turns."
        )
        return (head + [summary] + tail, true)
    }

    public static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        let chars = messages.reduce(0) { $0 + $1.content.count + ($1.reasoning?.count ?? 0) }
        return max(1, chars / 4)
    }
}
