import Foundation

public enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
    case tool = "tool"
}

public struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var sizeBytes: Int64
    public var mimeType: String
    public var previewText: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        sizeBytes: Int64 = 0,
        mimeType: String = "text/plain",
        previewText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.previewText = previewText
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sessionId: String
    public var role: MessageRole
    public var content: String
    public var reasoning: String?
    public var thinkingTimeMs: Double?
    public var agentId: String?
    public var agentName: String?
    public var agentAvatar: String?
    public var agentColor: String?
    public var modelId: String?
    public var providerId: String?
    public var timestamp: Date
    public var toolCalls: [ToolCallInfo]
    public var subAgentTasks: [SubAgentTask]
    public var attachments: [MessageAttachment]
    public var isStreaming: Bool
    public var isError: Bool
    public var promptTokens: Int
    public var completionTokens: Int

    public init(
        id: String = UUID().uuidString,
        sessionId: String = "",
        role: MessageRole,
        content: String,
        reasoning: String? = nil,
        thinkingTimeMs: Double? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        agentAvatar: String? = nil,
        agentColor: String? = nil,
        modelId: String? = nil,
        providerId: String? = nil,
        timestamp: Date = Date(),
        toolCalls: [ToolCallInfo] = [],
        subAgentTasks: [SubAgentTask] = [],
        attachments: [MessageAttachment] = [],
        isStreaming: Bool = false,
        isError: Bool = false,
        promptTokens: Int = 0,
        completionTokens: Int = 0
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.thinkingTimeMs = thinkingTimeMs
        self.agentId = agentId
        self.agentName = agentName
        self.agentAvatar = agentAvatar
        self.agentColor = agentColor
        self.modelId = modelId
        self.providerId = providerId
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.subAgentTasks = subAgentTasks
        self.attachments = attachments
        self.isStreaming = isStreaming
        self.isError = isError
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}
