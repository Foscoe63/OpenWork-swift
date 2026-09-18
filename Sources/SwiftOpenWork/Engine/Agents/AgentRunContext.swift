import Foundation
import SwiftOpenWorkCore

/// What a tool call needs to know about the agent run it belongs to, without every signature in
/// between carrying it.
///
/// `agent_spawn` runs inside `ToolExecutionEngine`, which only receives the calling agent. That
/// left it two blind spots, both real:
///
/// - **Depth.** Every spawn called itself depth 1, so a sub-agent that could spawn gave its own
///   sub-agents `agent_spawn` too, and the depth budget never stopped anything.
/// - **Which model is actually running.** A sub-agent used its own configured provider and model.
///   The seeded team is configured for Ollama models (`qwen2.5-coder:7b`, `llama3`), so on a
///   machine where Ollama is switched off every delegation failed to load a model, while the lead
///   was answering happily on the built-in engine.
///
/// A task-local value reaches the tool call through every `await` in between and cannot leak into
/// an unrelated run.
public enum AgentRunContext {

    public struct Frame: Sendable {
        public var provider: ModelProvider
        public var model: ModelInfo
        /// 0 for the turn the user started; a sub-agent spawned from it runs at 1.
        public var depth: Int

        public init(provider: ModelProvider, model: ModelInfo, depth: Int) {
            self.provider = provider
            self.model = model
            self.depth = depth
        }
    }

    @TaskLocal public static var current: Frame?

    public struct SubAgentModel: Sendable {
        public var provider: ModelProvider
        public var model: ModelInfo
        /// Set when the agent's own configuration could not be used, saying why.
        public var note: String?
    }

    /// The provider and model a sub-agent should run on.
    ///
    /// Its own configuration wins when it is actually usable: the provider exists and is switched
    /// on, and — for a local provider — the model is one that provider lists. Otherwise it runs on
    /// what the parent is running on, which is known to work, and the note says so. Pure, for tests.
    ///
    /// Inheriting is also the right call for the in-process engine specifically: a second local
    /// checkpoint loaded beside the parent's can exhaust unified memory.
    public static func subAgentModel(
        for subAgent: Agent,
        parent: Frame?,
        providers: [ModelProvider],
        settings: AppSettings
    ) -> SubAgentModel? {
        if !subAgent.providerId.isEmpty, !subAgent.modelId.isEmpty,
           let configured = providers.first(where: { $0.id == subAgent.providerId }) {
            let listed = configured.models.contains { $0.id == subAgent.modelId }
            if configured.isEnabled, configured.type == .cloud || listed {
                let model = configured.models.first { $0.id == subAgent.modelId }
                    ?? ModelInfo(id: subAgent.modelId, name: subAgent.modelId, providerId: configured.id)
                return SubAgentModel(provider: configured, model: model, note: nil)
            }
            if let parent {
                let why = configured.isEnabled
                    ? "\(configured.name) does not list \(subAgent.modelId)"
                    : "\(configured.name) is switched off"
                return SubAgentModel(
                    provider: parent.provider,
                    model: parent.model,
                    note: "\(subAgent.name) is configured for \(subAgent.modelId), but \(why); it ran on \(parent.model.name) instead."
                )
            }
        }

        if let parent {
            return SubAgentModel(provider: parent.provider, model: parent.model, note: nil)
        }

        // No run to inherit from (a tool called outside an agent run): the app's defaults.
        guard let resolution = ProviderSelection.resolve(providers: providers, selectedId: settings.defaultProviderId),
              !resolution.mustRefuse else { return nil }
        let modelId = subAgent.modelId.isEmpty ? settings.defaultModelId : subAgent.modelId
        let model = resolution.provider.models.first { $0.id == modelId }
            ?? ModelInfo(id: modelId, name: modelId, providerId: resolution.provider.id)
        return SubAgentModel(provider: resolution.provider, model: model, note: nil)
    }

    /// The deepest level a spawn by `agent` may reach: the global budget, narrowed by the agent's
    /// own "Max Sub-Agent Nesting Depth", which was a stepper in the agent editor that nothing read.
    public static func depthLimit(for agent: Agent, settings: AppSettings) -> Int {
        min(max(0, settings.maxGlobalSubAgentDepth), max(0, agent.maxSubAgentDepth))
    }
}
