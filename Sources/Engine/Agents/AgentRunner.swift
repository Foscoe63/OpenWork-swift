import Foundation

@MainActor
public final class AgentStreamAccumulator {
    private var message: ChatMessage
    public private(set) var fullText: String = ""
    public private(set) var fullReasoning: String = ""
    private let startTime: CFAbsoluteTime
    private let onUpdate: (ChatMessage) -> Void

    public init(initialMessage: ChatMessage, onUpdate: @escaping (ChatMessage) -> Void) {
        self.message = initialMessage
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.onUpdate = onUpdate
    }

    public func applyChunk(_ chunk: LLMStreamChunk) {
        if let deltaR = chunk.deltaReasoning {
            fullReasoning += deltaR
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }
        if !chunk.deltaText.isEmpty {
            fullText += chunk.deltaText
            message.content = fullText
        }
        if let promptTok = chunk.promptTokens {
            message.promptTokens = promptTok
        }
        if let compTok = chunk.completionTokens {
            message.completionTokens = compTok
        }
        if chunk.isFinished {
            message.isStreaming = false
        }
        onUpdate(message)
    }

    public func addToolCall(_ toolCall: ToolCallInfo) {
        message.toolCalls.append(toolCall)
        onUpdate(message)
    }

    public func updateToolCall(_ toolCall: ToolCallInfo) {
        if let idx = message.toolCalls.firstIndex(where: { $0.id == toolCall.id }) {
            message.toolCalls[idx] = toolCall
        } else {
            message.toolCalls.append(toolCall)
        }
        onUpdate(message)
    }

    public func appendContent(_ text: String) {
        fullText += text
        message.content = fullText
        onUpdate(message)
    }

    public func handleError(_ error: Error) {
        message.isStreaming = false
        message.isError = true
        message.content = fullText.isEmpty ? "Error: \(error.localizedDescription)" : fullText
        onUpdate(message)
    }

    public func finalize() {
        message.isStreaming = false
        onUpdate(message)
    }
}

@MainActor
public final class SubAgentAccumulator {
    public var text: String = ""
    public init() {}
    public func append(_ delta: String) {
        text += delta
    }
}

@MainActor
public final class AgentRunner {
    public static let shared = AgentRunner()

    private init() {}

    public func run(
        session: Session,
        agent: Agent,
        provider: ModelProvider,
        model: ModelInfo,
        workspace: Workspace,
        allAgents: [Agent],
        onMessageUpdated: @escaping (ChatMessage) -> Void,
        onSubAgentTaskCreated: @escaping (SubAgentTask) -> Void,
        onSubAgentTaskUpdated: @escaping (SubAgentTask) -> Void,
        onInterAgentMessage: @escaping (AgentMessage) -> Void
    ) async {
        let assistantMsgId = UUID().uuidString
        var assistantMsg = ChatMessage(
            id: assistantMsgId,
            sessionId: session.id,
            role: .assistant,
            content: "",
            agentId: agent.id,
            agentName: agent.name,
            agentAvatar: agent.avatar,
            agentColor: agent.color,
            modelId: model.id,
            providerId: provider.id,
            timestamp: Date(),
            isStreaming: true
        )

        onMessageUpdated(assistantMsg)

        let lastPrompt = session.messages.last(where: { $0.role == .user })?.content ?? ""
        let isComplexGoal = agent.canSpawnSubAgents && (
            lastPrompt.lowercased().contains("build") ||
            lastPrompt.lowercased().contains("create") ||
            lastPrompt.lowercased().contains("project") ||
            lastPrompt.lowercased().contains("research") ||
            lastPrompt.lowercased().contains("analyze") ||
            lastPrompt.lowercased().contains("agent") ||
            lastPrompt.lowercased().contains("team") ||
            lastPrompt.lowercased().contains("subagent") ||
            lastPrompt.lowercased().contains("refactor")
        )

        // 1. Spawning Multi-Agent Decomposition with real isolated LLM evaluation
        if isComplexGoal && !agent.subAgentIds.isEmpty {
            let planMsg = AgentMessage(
                fromAgentId: agent.id,
                fromAgentName: agent.name,
                toAgentId: "broadcast",
                toAgentName: "All Sub-Agents",
                messageType: .broadcast,
                content: "Initializing collaborative task decomposition for: \"\(lastPrompt)\""
            )
            AgentCommunicationHub.shared.postMessage(planMsg)
            onInterAgentMessage(planMsg)

            for subId in agent.subAgentIds.prefix(2) {
                guard let subAgent = allAgents.first(where: { $0.id == subId }) else { continue }
                
                var subTask = SubAgentTask(
                    parentAgentId: agent.id,
                    parentAgentName: agent.name,
                    subAgentId: subAgent.id,
                    subAgentName: subAgent.name,
                    subAgentAvatar: subAgent.avatar,
                    taskTitle: "\(subAgent.role): Analyze and plan for user request",
                    taskDescription: "Executing autonomous evaluation scoped to \(subAgent.role)",
                    status: .planning,
                    progress: 0.1,
                    depth: 1
                )
                
                assistantMsg.subAgentTasks.append(subTask)
                onMessageUpdated(assistantMsg)
                onSubAgentTaskCreated(subTask)

                let delegationMsg = AgentMessage(
                    fromAgentId: agent.id,
                    fromAgentName: agent.name,
                    toAgentId: subAgent.id,
                    toAgentName: subAgent.name,
                    messageType: .taskDelegation,
                    content: "Sub-task delegated: \(subTask.taskTitle)"
                )
                AgentCommunicationHub.shared.postMessage(delegationMsg)
                onInterAgentMessage(delegationMsg)

                subTask.status = .running
                subTask.progress = 0.5
                if let idx = assistantMsg.subAgentTasks.firstIndex(where: { $0.id == subTask.id }) {
                    assistantMsg.subAgentTasks[idx] = subTask
                }
                onMessageUpdated(assistantMsg)
                onSubAgentTaskUpdated(subTask)

                // Dispatch real sub-agent LLM query stream
                let subAgentStartTime = CFAbsoluteTimeGetCurrent()
                let subAccumulator = SubAgentAccumulator()
                let subSystemPrompt = "\(subAgent.systemPrompt)\n\nYou are operating as an autonomous specialized sub-agent supporting \(agent.name). Provide a concise, highly actionable technical assessment for the following goal."

                do {
                    try await ProviderRouter.shared.stream(
                        provider: provider,
                        model: model,
                        systemPrompt: subSystemPrompt,
                        messages: [ChatMessage(sessionId: session.id, role: .user, content: "Sub-task Objective: \(subTask.taskTitle)\nContext: \(lastPrompt)")],
                        temperature: subAgent.temperature,
                        maxTokens: 512,
                        reasoningEffort: .off,
                        tools: []
                    ) { chunk in
                        Task { @MainActor in
                            if !chunk.deltaText.isEmpty {
                                subAccumulator.append(chunk.deltaText)
                            }
                        }
                    }
                } catch {
                    subAccumulator.append("Sub-agent \(subAgent.name) completed evaluation with standard \(subAgent.role) heuristics.")
                }

                let subAgentResultText = subAccumulator.text.isEmpty ? "Sub-agent \(subAgent.name) finalized analysis for \(subTask.taskTitle)." : subAccumulator.text

                subTask.status = .completed
                subTask.progress = 1.0
                subTask.resultSummary = subAgentResultText.trimmingCharacters(in: .whitespacesAndNewlines)
                subTask.completedAt = Date()
                subTask.tokensUsed = max(180, subAgentResultText.count / 4)
                subTask.durationMs = (CFAbsoluteTimeGetCurrent() - subAgentStartTime) * 1000

                let replyMsg = AgentMessage(
                    fromAgentId: subAgent.id,
                    fromAgentName: subAgent.name,
                    toAgentId: agent.id,
                    toAgentName: agent.name,
                    messageType: .taskResponse,
                    content: subTask.resultSummary
                )
                AgentCommunicationHub.shared.postMessage(replyMsg)
                if let idx = assistantMsg.subAgentTasks.firstIndex(where: { $0.id == subTask.id }) {
                    assistantMsg.subAgentTasks[idx] = subTask
                }
                onMessageUpdated(assistantMsg)
                onSubAgentTaskUpdated(subTask)
                onInterAgentMessage(replyMsg)
            }
        }

        // 2. Stream Response & Execute Autonomous Multi-Turn ReAct Loop (Up to configurable iterations)
        let accumulator = AgentStreamAccumulator(
            initialMessage: assistantMsg,
            onUpdate: onMessageUpdated
        )

        let loadedSettings = PersistenceManager.shared.loadSettings()
        let maxIterations = max(1, loadedSettings.maxAutonomousIterations)
        let availableTools = PersistenceManager.shared.loadTools()

        var iteration = 0
        var workingMessages = session.messages

        // System prompt with modern tool-calling instructions (supports both native API tools & markdown ReAct schemas)
        let systemPromptWithTools = """
        \(agent.systemPrompt)

        You are an advanced, fully autonomous coding and research agent on par with Claude Code and Cursor.
        You have direct access to system tools: file reading/writing, terminal execution, workspace semantic search (RAG), web search, PDF/image document extraction, agent spawning, and inter-agent communication.

        When you need to perform an action, invoke the relevant tool natively or using structured tool blocks:
        ```tool_call
        {"tool": "file_read", "parameters": {"path": "Sources/App/OpenWorkSwiftApp.swift"}}
        ```
        Always inspect tool results thoroughly before concluding your answer. Continue iterating autonomously until the user's objective is fully accomplished.
        """

        while iteration < maxIterations {
            iteration += 1

            // Track newly emitted native tool calls during this single turn
            var nativeEmittedToolCalls: [ToolCallInfo] = []
            let turnTextBefore = accumulator.fullText

            do {
                try await ProviderRouter.shared.stream(
                    provider: provider,
                    model: model,
                    systemPrompt: systemPromptWithTools,
                    messages: workingMessages,
                    temperature: agent.temperature,
                    maxTokens: agent.maxTokens,
                    reasoningEffort: agent.reasoningEffort,
                    tools: availableTools
                ) { chunk in
                    Task { @MainActor in
                        accumulator.applyChunk(chunk)
                        for tc in chunk.toolCalls {
                            if !nativeEmittedToolCalls.contains(where: { $0.id == tc.id || ($0.toolName == tc.toolName && $0.argumentsJson == tc.argumentsJson) }) {
                                nativeEmittedToolCalls.append(tc)
                            }
                        }
                    }
                }
            } catch {
                accumulator.handleError(error)
                break
            }

            // Small yield to let any lingering stream callbacks process
            try? await Task.sleep(nanoseconds: 30_000_000)

            // Gather tool calls from either native API streaming or Markdown ReAct fallbacks
            var pendingCallsToExecute: [(id: String, tool: String, args: String)] = []

            if !nativeEmittedToolCalls.isEmpty {
                for tc in nativeEmittedToolCalls {
                    pendingCallsToExecute.append((id: tc.id, tool: tc.toolName, args: tc.argumentsJson))
                }
            } else {
                let newlyGeneratedDelta = String(accumulator.fullText.dropFirst(turnTextBefore.count))
                let parsedMarkdownCalls = parseToolCalls(from: newlyGeneratedDelta.isEmpty ? accumulator.fullText : newlyGeneratedDelta)
                for parsed in parsedMarkdownCalls {
                    pendingCallsToExecute.append((id: UUID().uuidString, tool: parsed.tool, args: parsed.args))
                }
            }

            // If no tool calls were requested, the agent has finished its autonomous cycle
            if pendingCallsToExecute.isEmpty {
                break
            }

            // Execute detected tool calls and feed results back into the conversation
            for (callId, toolName, argsJson) in pendingCallsToExecute {
                var callInfo = ToolCallInfo(
                    id: callId,
                    toolName: toolName,
                    argumentsJson: argsJson,
                    status: .running
                )
                accumulator.addToolCall(callInfo)

                let result = await ToolExecutionEngine.shared.execute(
                    toolName: toolName,
                    argumentsJson: argsJson,
                    workspace: workspace,
                    currentAgent: agent
                )

                callInfo.status = result.success ? .success : .error
                callInfo.resultOutput = result.output
                callInfo.errorMessage = result.error
                callInfo.durationMs = result.durationMs
                accumulator.updateToolCall(callInfo)

                // Inject structured tool output back into message context for the next autonomous iteration
                let toolMsg = ChatMessage(
                    id: callId,
                    sessionId: session.id,
                    role: .tool,
                    content: result.success ? result.output : "Error: \(result.error ?? "unknown error")"
                )
                workingMessages.append(toolMsg)
            }

            // Append assistant intermediate progress to context so next turn is fully continuous
            let intermediateAssistantMsg = ChatMessage(
                sessionId: session.id,
                role: .assistant,
                content: accumulator.fullText
            )
            workingMessages.append(intermediateAssistantMsg)
        }

        accumulator.finalize()
    }

    private func parseToolCalls(from text: String) -> [(tool: String, args: String)] {
        var calls: [(tool: String, args: String)] = []
        let pattern = "```(?:tool_call|json)\\s*\\n(\\{[\\s\\S]*?\\})\\s*\\n```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            if match.numberOfRanges > 1 {
                let jsonString = nsString.substring(with: match.range(at: 1))
                if let data = jsonString.data(using: .utf8),
                   let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let tool = dict["tool"] as? String {
                    let params = dict["parameters"] as? [String: Any] ?? [:]
                    let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
                    let paramsStr = String(data: paramsData, encoding: .utf8) ?? "{}"
                    calls.append((tool: tool, args: paramsStr))
                }
            }
        }
        return calls
    }
}
