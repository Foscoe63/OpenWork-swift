import Foundation

public enum AgentMessageType: String, Codable, CaseIterable, Sendable {
    case taskDelegation = "task_delegation"
    case taskResponse = "task_response"
    case consultation = "consultation"
    case clarification = "clarification"
    case statusReport = "status_report"
    case broadcast = "broadcast"
    case errorReport = "error_report"

    public var displayName: String {
        switch self {
        case .taskDelegation: return "Task Delegation"
        case .taskResponse: return "Task Output"
        case .consultation: return "Consultation / Query"
        case .clarification: return "Clarification"
        case .statusReport: return "Status Report"
        case .broadcast: return "Team Broadcast"
        case .errorReport: return "Error Report"
        }
    }

    public var icon: String {
        switch self {
        case .taskDelegation: return "arrow.turn.down.right"
        case .taskResponse: return "arrow.turn.up.left"
        case .consultation: return "questionmark.bubble"
        case .clarification: return "bubble.left.and.bubble.right"
        case .statusReport: return "chart.bar.doc.horizontal"
        case .broadcast: return "antenna.radiowaves.left.and.right"
        case .errorReport: return "exclamationmark.triangle"
        }
    }
}

public struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var fromAgentId: String
    public var fromAgentName: String
    public var toAgentId: String
    public var toAgentName: String
    public var messageType: AgentMessageType
    public var content: String
    public var payloadJson: String?
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        fromAgentId: String,
        fromAgentName: String,
        toAgentId: String,
        toAgentName: String,
        messageType: AgentMessageType = .taskDelegation,
        content: String,
        payloadJson: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.fromAgentId = fromAgentId
        self.fromAgentName = fromAgentName
        self.toAgentId = toAgentId
        self.toAgentName = toAgentName
        self.messageType = messageType
        self.content = content
        self.payloadJson = payloadJson
        self.timestamp = timestamp
    }
}
