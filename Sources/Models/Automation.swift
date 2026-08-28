import Foundation

public enum AutomationTriggerType: String, Codable, CaseIterable, Sendable {
    case manual = "manual"
    case scheduled = "scheduled"
    case onStartup = "onStartup"
    case onSessionCreated = "onSessionCreated"
    case fileWatch = "fileWatch"

    public var displayName: String {
        switch self {
        case .manual: return "Manual Trigger"
        case .scheduled: return "Scheduled (Interval / Cron)"
        case .onStartup: return "Run on App Launch"
        case .onSessionCreated: return "On Session Create"
        case .fileWatch: return "Watch Directory Changes"
        }
    }

    public var icon: String {
        switch self {
        case .manual: return "play.circle.fill"
        case .scheduled: return "clock.arrow.2.circlepath"
        case .onStartup: return "bolt.fill"
        case .onSessionCreated: return "plus.message.fill"
        case .fileWatch: return "eye.circle.fill"
        }
    }
}

public struct Automation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var description: String
    public var triggerType: AutomationTriggerType
    public var cronSchedule: String // e.g. "Every 30 mins", "Daily at 9am"
    public var targetAgentId: String
    public var promptTemplate: String
    public var isEnabled: Bool
    public var lastRunAt: Date?
    public var lastResultSummary: String?
    public var lastStatus: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        workspaceId: String = "default-workspace",
        name: String,
        description: String = "",
        triggerType: AutomationTriggerType = .manual,
        cronSchedule: String = "Hourly",
        targetAgentId: String = "",
        promptTemplate: String = "",
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastResultSummary: String? = nil,
        lastStatus: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.description = description
        self.triggerType = triggerType
        self.cronSchedule = cronSchedule
        self.targetAgentId = targetAgentId
        self.promptTemplate = promptTemplate
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastResultSummary = lastResultSummary
        self.lastStatus = lastStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
