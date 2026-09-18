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
    /// Set when this session was branched from another. Optional so sessions saved before forking
    /// existed still decode.
    public var forkedFromSessionId: String?
    /// The message in the parent that this session ends at.
    public var forkedAtMessageId: String?
    /// Sticky checklist from `todo_write` — survives across turns in this session.
    public var todos: [SessionTodoItem]

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
        estimatedCost: Double = 0.0,
        forkedFromSessionId: String? = nil,
        forkedAtMessageId: String? = nil,
        todos: [SessionTodoItem] = []
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
        self.forkedFromSessionId = forkedFromSessionId
        self.forkedAtMessageId = forkedAtMessageId
        self.todos = todos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        title = try c.decode(String.self, forKey: .title)
        agentId = try c.decode(String.self, forKey: .agentId)
        providerId = try c.decode(String.self, forKey: .providerId)
        modelId = try c.decode(String.self, forKey: .modelId)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        activeSubAgentTasks = try c.decodeIfPresent([SubAgentTask].self, forKey: .activeSubAgentTasks) ?? []
        interAgentMessages = try c.decodeIfPresent([AgentMessage].self, forKey: .interAgentMessages) ?? []
        totalPromptTokens = try c.decodeIfPresent(Int.self, forKey: .totalPromptTokens) ?? 0
        totalCompletionTokens = try c.decodeIfPresent(Int.self, forKey: .totalCompletionTokens) ?? 0
        estimatedCost = try c.decodeIfPresent(Double.self, forKey: .estimatedCost) ?? 0
        forkedFromSessionId = try c.decodeIfPresent(String.self, forKey: .forkedFromSessionId)
        forkedAtMessageId = try c.decodeIfPresent(String.self, forKey: .forkedAtMessageId)
        todos = try c.decodeIfPresent([SessionTodoItem].self, forKey: .todos) ?? []
    }
}
