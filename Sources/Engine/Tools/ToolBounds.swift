import Foundation

/// Radiant-style central tool result bound + time budget (tool-bounds.js parity).
public enum ToolBounds {
    public static let maxResultChars = 40_000
    public static let maxToolMs: UInt64 = 180_000_000_000 // 180s in nanoseconds

    public struct Bounded: Sendable {
        public let text: String
        public let truncatedChars: Int
        public let notice: String?
    }

    public static func boundResult(_ text: String, max: Int = maxResultChars) -> Bounded {
        let s = text
        guard s.count > max else {
            return Bounded(text: s, truncatedChars: 0, notice: nil)
        }
        let head = Int(Double(max) * 0.7)
        let tail = max - head
        let sliced = String(s.prefix(head)) + "\n\n…\n\n" + String(s.suffix(tail))
        let truncated = s.count - max
        return Bounded(
            text: sliced,
            truncatedChars: truncated,
            notice: "Tool result truncated (\(truncated) chars omitted). Head and tail retained."
        )
    }

    public static func withBudget<T: Sendable>(
        _ body: @Sendable @escaping () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: maxToolMs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }
}
