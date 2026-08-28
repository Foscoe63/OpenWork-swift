import Foundation

public struct LLMStreamChunk: Sendable {
    public var deltaText: String
    public var deltaReasoning: String?
    public var isFinished: Bool
    public var finishReason: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var toolCalls: [ToolCallInfo]

    public init(
        deltaText: String = "",
        deltaReasoning: String? = nil,
        isFinished: Bool = false,
        finishReason: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        toolCalls: [ToolCallInfo] = []
    ) {
        self.deltaText = deltaText
        self.deltaReasoning = deltaReasoning
        self.isFinished = isFinished
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.toolCalls = toolCalls
    }
}

public protocol LLMProviderClient: Sendable {
    func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws
    
    func listModels(provider: ModelProvider) async throws -> [ModelInfo]
    func testConnection(provider: ModelProvider) async throws -> Bool
}

public extension LLMProviderClient {
    func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        try await streamChat(
            provider: provider,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            tools: [],
            onChunk: onChunk
        )
    }
}
