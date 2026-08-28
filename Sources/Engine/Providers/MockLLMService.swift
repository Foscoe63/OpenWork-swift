import Foundation

public final class MockLLMService: LLMProviderClient, @unchecked Sendable {
    public static let shared = MockLLMService()

    public func testConnection(provider: ModelProvider) async throws -> Bool {
        return true
    }

    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] {
        return provider.models
    }

    public func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        let lastUserMessage = messages.last(where: { $0.role == .user })?.content ?? ""
        
        if model.supportsReasoning || reasoningEffort != .off {
            let reasoningSteps = [
                "1. Analyzing user instruction and context constraints...\n",
                "2. Formulating systematic plan and identifying required sub-agent skills...\n",
                "3. Checking relevant knowledge base, tools, and file permissions...\n",
                "4. Synthesizing final structured response with high fidelity.\n"
            ]
            for step in reasoningSteps {
                try? await Task.sleep(nanoseconds: 120_000_000)
                onChunk(LLMStreamChunk(deltaReasoning: step))
            }
        }

        let responseText: String
        let lower = lastUserMessage.lowercased()
        
        if lower.contains("subagent") || lower.contains("sub-agent") || lower.contains("team") || lower.contains("delegate") {
            responseText = """
            I've initialized the autonomous agent workflow for your request:
            
            ```swift
            // Agent delegation pipeline active
            Task: "\(lastUserMessage)"
            Status: Orchestrating specialized sub-agents
            ```
            
            ### Sub-Agent Delegations:
            1. **Engineer Agent**: Synthesizing architecture and code modules.
            2. **Researcher Agent**: Validating requirements and technical constraints.
            3. **Reviewer Agent**: Verifying safety, performance, and style consistency.
            
            All child sub-agents have reported status and finalized tasks with zero errors.
            """
        } else if lower.contains("swift") || lower.contains("code") || lower.contains("function") {
            responseText = """
            Here is the requested implementation following modern Swift 6 paradigms:
            
            ```swift
            import Foundation
            import SwiftUI
            
            /// High performance asynchronous pipeline
            public struct AgentResponsePipeline: Sendable {
                public let id = UUID()
                public var status: String = "Active"
                
                public func process(query: String) async -> String {
                    // Autonomous processing
                    return "Completed execution for: \\(query)"
                }
            }
            ```
            
            ### Notes:
            - Fully type-safe and concurrency compliant with Swift 6 strict checking.
            - Integrated with the OpenWork-Swift multi-agent execution runtime.
            """
        } else {
            responseText = """
            I have processed your request: **"\(lastUserMessage)"**.
            
            OpenWork-Swift is running fully standalone on macOS. You can:
            - Switch between local (Ollama / LM Studio) and cloud model providers in the top bar.
            - Use the right-hand **Inspector** to watch real-time **Sub-Agent execution trees** and **Inter-Agent communications**.
            - Create custom agents and configure system prompts, tools, and sub-agent hierarchies in the **Agents** tab.
            """
        }

        let words = responseText.split(separator: " ", omittingEmptySubsequences: false)
        for (i, word) in words.enumerated() {
            try? await Task.sleep(nanoseconds: 25_000_000)
            let space = (i == words.count - 1) ? "" : " "
            onChunk(LLMStreamChunk(deltaText: String(word) + space))
        }

        onChunk(LLMStreamChunk(
            isFinished: true,
            promptTokens: 140,
            completionTokens: words.count
        ))
    }
}
