import Foundation

public struct Session: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var title: String
    public var agentId: String
    public var providerId: String
    public var modelId: String
    public var isArchived: Bool
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var activeSubAgentTasks: [SubAgentTask]
    public var interAgentMessages: [AgentMessage]
    public var totalPromptTokens: Int
    public var totalCompletionTokens: Int
    public var estimatedCost: Double

    public init(
        id: String = UUID().uuidString,
        workspaceId: String = "default-workspace",
        title: String = "New Session",
        agentId: String = "lead-assistant",
        providerId: String = "",
        modelId: String = "",
        isArchived: Bool = false,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        activeSubAgentTasks: [SubAgentTask] = [],
        interAgentMessages: [AgentMessage] = [],
        totalPromptTokens: Int = 0,
        totalCompletionTokens: Int = 0,
        estimatedCost: Double = 0.0
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.agentId = agentId
        self.providerId = providerId
        self.modelId = modelId
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.activeSubAgentTasks = activeSubAgentTasks
        self.interAgentMessages = interAgentMessages
        self.totalPromptTokens = totalPromptTokens
        self.totalCompletionTokens = totalCompletionTokens
        self.estimatedCost = estimatedCost
    }
}
