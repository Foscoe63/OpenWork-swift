import Foundation

public final class AgentCommunicationHub: @unchecked Sendable {
    public static let shared = AgentCommunicationHub()

    private var messageLog: [AgentMessage] = []
    private let queue = DispatchQueue(label: "ai.openwork.agentcomm", attributes: .concurrent)

    private init() {}

    /// The newest messages kept in memory.
    ///
    /// This log had no readers at all — `allMessages()` and `messages(for:)` are called from
    /// nowhere, and the Agent Messages inspector reads `AppState.interAgentMessages`, which is a
    /// different store written from a different place. So this was an unbounded array that four
    /// call sites appended to for the life of the process and nothing ever drained. Capped rather
    /// than deleted because it is the only record that survives a session switch, and a cap is
    /// the cheaper half of the fix to be wrong about.
    static let retainedMessageLimit = 2000

    public func postMessage(_ message: AgentMessage) {
        queue.async(flags: .barrier) {
            self.messageLog.append(message)
            if self.messageLog.count > Self.retainedMessageLimit {
                self.messageLog.removeFirst(self.messageLog.count - Self.retainedMessageLimit)
            }
        }
    }

    public func messages(for agentId: String) -> [AgentMessage] {
        queue.sync {
            messageLog.filter { $0.fromAgentId == agentId || $0.toAgentId == agentId || $0.messageType == .broadcast }
        }
    }

    public func allMessages() -> [AgentMessage] {
        queue.sync { messageLog }
    }

    public func clear() {
        queue.async(flags: .barrier) {
            self.messageLog.removeAll()
        }
    }
}
