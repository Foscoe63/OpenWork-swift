import Foundation

public final class AgentCommunicationHub: @unchecked Sendable {
    public static let shared = AgentCommunicationHub()

    private var messageLog: [AgentMessage] = []
    private let queue = DispatchQueue(label: "ai.openwork.agentcomm", attributes: .concurrent)

    private init() {}

    public func postMessage(_ message: AgentMessage) {
        queue.async(flags: .barrier) {
            self.messageLog.append(message)
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
