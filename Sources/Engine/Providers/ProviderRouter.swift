import Foundation

public final class ProviderRouter: @unchecked Sendable {
    public static let shared = ProviderRouter()

    private init() {}

    public func client(for provider: ModelProvider) -> LLMProviderClient {
        switch provider.kind {
        case .ollama:
            return OllamaService.shared
        case .anthropic:
            return AnthropicService.shared
        case .openai, .groq, .openrouter, .deepseek, .lmstudio, .llamacpp, .omlx, .vmlx, .mistral, .gemini, .custom:
            return OpenAIService.shared
        }
    }

    public func stream(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [Tool] = [],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        let selectedClient = client(for: provider)
        
        do {
            try await selectedClient.streamChat(
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                onChunk: onChunk
            )
        } catch {
            print("[ProviderRouter] Provider \(provider.name) failed (\(error.localizedDescription)), falling back to standalone offline engine...")
            try await MockLLMService.shared.streamChat(
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                onChunk: onChunk
            )
        }
    }
}
