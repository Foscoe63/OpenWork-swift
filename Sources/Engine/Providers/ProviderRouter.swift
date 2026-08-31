import Foundation

public final class ProviderRouter: @unchecked Sendable {
    public static let shared = ProviderRouter()

    private init() {}

    public func client(for provider: ModelProvider) -> LLMProviderClient {
        switch provider.kind {
        case .omlx, .vmlx:
            return OpenAIService.shared
        case .ollama:
            return OllamaService.shared
        case .anthropic:
            return AnthropicService.shared
        case .openai, .groq, .openrouter, .deepseek, .lmstudio, .llamacpp, .mistral, .gemini, .custom:
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
        var activeProvider = provider

        // Built-in Apple Silicon Engine (matches Osaurus / GrizzyClaw on-device architecture)
        if provider.kind == .omlx || provider.kind == .vmlx || activeProvider.type == .local {
            let res = await LocalMLXEngine.shared.ensureServerRunning(modelId: model.id)
            if !res.success {
                let msg = res.message.isEmpty ? "Local backend failed to start." : res.message
                onChunk(LLMStreamChunk(
                    deltaText: "\n\n⚠️ **Local Model Error:** \(msg)",
                    isFinished: true
                ))
                throw NSError(
                    domain: "ProviderRouter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
            activeProvider.baseUrl = "http://127.0.0.1:\(res.activePort)/v1"

            let selectedClient = client(for: activeProvider)
            do {
                try await selectedClient.streamChat(
                    provider: activeProvider,
                    model: model,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    reasoningEffort: reasoningEffort,
                    tools: tools,
                    onChunk: onChunk
                )
                return
            } catch {
                onChunk(LLMStreamChunk(
                    deltaText: "\n\n⚠️ **Local Model Error:** \(error.localizedDescription)",
                    isFinished: true
                ))
                throw error
            }
        }


        // Remote / Cloud Providers (OpenAI, Anthropic, Groq, etc.)
        let selectedClient = client(for: activeProvider)
        do {
            try await selectedClient.streamChat(
                provider: activeProvider,
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
            onChunk(LLMStreamChunk(
                deltaText: "\n\n⚠️ **Provider Error (\(activeProvider.name)):**\n`\(error.localizedDescription)`\n\nPlease check your API key and network connection in Settings > Providers.",
                isFinished: true
            ))
            throw error
        }
    }
}
