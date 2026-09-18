import Foundation

public enum SubAgentStatus: String, Codable, CaseIterable, Sendable {
    case idle = "idle"
    case planning = "planning"
    case running = "running"
    case waiting = "waiting"
    case completed = "completed"
    case failed = "failed"
    case paused = "paused"

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .planning: return "Planning Strategy"
        case .running: return "Executing Task"
        case .waiting: return "Waiting for Sub-Agent"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .paused: return "Paused"
        }
    }

    public var icon: String {
        switch self {
        case .idle: return "circle"
        case .planning: return "brain.head.profile"
        case .running: return "arrow.triangle.2.circlepath"
        case .waiting: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    public var colorHex: String {
        switch self {
        case .idle: return "#9CA3AF"
        case .planning: return "#60A5FA"
        case .running: return "#F59E0B"
        case .waiting: return "#EC4899"
        case .completed: return "#10B981"
        case .failed: return "#EF4444"
        case .paused: return "#8B5CF6"
        }
    }
}

public struct SubAgentTask: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var parentAgentId: String
    public var parentAgentName: String
    public var subAgentId: String
    public var subAgentName: String
    public var subAgentAvatar: String
    public var taskTitle: String
    public var taskDescription: String
    public var status: SubAgentStatus
    public var progress: Double // 0.0 to 1.0
    public var resultSummary: String
    public var errorMessage: String?
    public var tokensUsed: Int
    public var durationMs: Double
    public var depth: Int
    public var childTaskIds: [String]
    public var startedAt: Date
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        parentAgentId: String,
        parentAgentName: String = "Lead Agent",
        subAgentId: String,
        subAgentName: String,
        subAgentAvatar: String = "person.2.circle.fill",
        taskTitle: String,
        taskDescription: String,
        status: SubAgentStatus = .running,
        progress: Double = 0.0,
        resultSummary: String = "",
        errorMessage: String? = nil,
        tokensUsed: Int = 0,
        durationMs: Double = 0,
        depth: Int = 1,
        childTaskIds: [String] = [],
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.parentAgentId = parentAgentId
        self.parentAgentName = parentAgentName
        self.subAgentId = subAgentId
        self.subAgentName = subAgentName
        self.subAgentAvatar = subAgentAvatar
        self.taskTitle = taskTitle
        self.taskDescription = taskDescription
        self.status = status
        self.progress = progress
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.tokensUsed = tokensUsed
        self.durationMs = durationMs
        self.depth = depth
        self.childTaskIds = childTaskIds
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
