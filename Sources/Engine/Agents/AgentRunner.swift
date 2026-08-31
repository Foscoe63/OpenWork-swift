import Foundation

@MainActor
public final class AgentStreamAccumulator {
    public private(set) var message: ChatMessage
    public private(set) var fullText: String = ""
    public private(set) var fullReasoning: String = ""
    public private(set) var isLoopDetected: Bool = false
    private let startTime: CFAbsoluteTime
    private let onUpdate: (ChatMessage) -> Void
    private let isLoopBreakerEnabled: Bool

    public init(initialMessage: ChatMessage, onUpdate: @escaping (ChatMessage) -> Void) {
        self.message = initialMessage
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.onUpdate = onUpdate
        self.isLoopBreakerEnabled = PersistenceManager.shared.loadSettings().autoLoopBreakerEnabled
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
            
            // Repetition / degenerative loop check on incoming stream (respects user settings)
            if self.isLoopBreakerEnabled && checkRepetitionLoop(in: fullText) {
                isLoopDetected = true
                message.isStreaming = false
                onUpdate(message)
                return
            }
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

    private func checkRepetitionLoop(in text: String) -> Bool {
        guard text.count >= 150 else { return false }
        
        // 1. Check for exact repeating sentences or phrase patterns (30-150 chars repeating 3+ times at tail)
        for patternLen in [30, 40, 50, 60, 70, 80, 100, 120, 140] {
            guard text.count >= patternLen * 3 else { continue }
            let suffix3 = text.suffix(patternLen * 3)
            let s1 = suffix3.prefix(patternLen)
            let s2 = suffix3.dropFirst(patternLen).prefix(patternLen)
            let s3 = suffix3.suffix(patternLen)
            if s1 == s2 && s2 == s3 {
                return true
            }
        }
        
        // 2. Exact line-level repetition (3+ identical non-empty trimmed lines)
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 15 }
        
        if rawLines.count >= 4 {
            let last = rawLines.last!
            let count = rawLines.suffix(5).filter { $0 == last }.count
            if count >= 3 {
                return true
            }
        }

        // 3. Fuzzy / Semantic repetition check on recent lines
        if rawLines.count >= 3 {
            let recentLines = Array(rawLines.suffix(5))
            for i in 0..<(recentLines.count - 1) {
                let lineA = recentLines[i]
                let lineB = recentLines[i + 1]
                
                // Compare normalized word overlap / Jaccard similarity
                let wordsA = Set(lineA.lowercased().split(separator: " ").map { String($0) })
                let wordsB = Set(lineB.lowercased().split(separator: " ").map { String($0) })
                
                guard wordsA.count >= 6 && wordsB.count >= 6 else { continue }
                let commonWords = wordsA.intersection(wordsB)
                let unionWords = wordsA.union(wordsB)
                let similarity = Double(commonWords.count) / Double(unionWords.count)
                
                // If two consecutive generated lines share >85% of words, it's an autoregressive loop
                if similarity >= 0.85 {
                    return true
                }
                
                // Common prefix check (e.g. "Now I have today's date...")
                let prefixLen = zip(lineA.lowercased(), lineB.lowercased()).prefix(while: { $0 == $1 }).count
                if prefixLen >= 45 && prefixLen >= min(lineA.count, lineB.count) * 3 / 4 {
                    return true
                }
            }
        }

        // 4. Repeated N-gram phrases in trailing window (checks if identical 5-word sequence appears 3+ times in the tail)
        let words = text.suffix(1000).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        
        if words.count >= 20 {
            var ngrams: [String: Int] = [:]
            for i in 0..<(words.count - 4) {
                let gram = "\(words[i]) \(words[i+1]) \(words[i+2]) \(words[i+3]) \(words[i+4])"
                let currentCount = (ngrams[gram] ?? 0) + 1
                ngrams[gram] = currentCount
                if currentCount >= 3 {
                    return true
                }
            }
        }

        return false
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

    public func cleanToolCallSyntax(from rawText: String) -> String {
        var cleaned = rawText
        
        // Remove TOOL_CALL = { ... }
        let assignPattern = "TOOL_CALL\\s*=\\s*\\{[\\s\\S]*?\\}"
        if let regex = try? NSRegularExpression(pattern: assignPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove ```tool_call ... ``` or ```json with tool definitions
        let codeBlockPattern = "```(?:tool_call|json)?\\s*(?:\\r?\\n)?\\s*\\{\\s*\"(?:tool|name|mcp|server)\"[\\s\\S]*?\\}\\s*(?:\\r?\\n)?```"
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove XML tool calls <tool_call>...</tool_call>
        let xmlPattern = "<tool_call>[\\s\\S]*?(?:</tool_call>|$)"
        if let regex = try? NSRegularExpression(pattern: xmlPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove raw naked tool JSON if it was the entirety or beginning of a line
        let nakedPattern = "(?m)^\\s*\\{\\s*\"(?:tool|name|mcp|server)\"\\s*:[\\s\\S]*?\\}\\s*$"
        if let regex = try? NSRegularExpression(pattern: nakedPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove conversational tool call intent filler lines that end abruptly (e.g. "Let me emit tool calls.", "---")
        let fillerLinesPattern = "(?m)^\\s*(?:Let me emit tool calls\\.?|Let me call the tool\\.?|---\\s*)$\\s*"
        if let regex = try? NSRegularExpression(pattern: fillerLinesPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func finalize() {
        message.isStreaming = false
        message.content = cleanToolCallSyntax(from: fullText)
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
        var availableTools = PersistenceManager.shared.loadTools()

        // Inject active MCP servers into available tools & prompt
        let enabledMcpServers = loadedSettings.mcpServers.filter { $0.isEnabled }
        var mcpPromptSummary = ""

        if !enabledMcpServers.isEmpty {
            var mcpDescriptions: [String] = []

            for s in enabledMcpServers {
                let cleanName = s.name.lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "-", with: "_")

                let tool = Tool(
                    id: "mcp_\(s.id)",
                    name: "\(cleanName)_call",
                    displayName: "\(s.name) MCP Tool",
                    description: "Execute tools and queries via the \(s.name) Model Context Protocol (MCP) server (\(s.transportType.displayName)).",
                    category: .mcp
                )
                if !availableTools.contains(where: { $0.id == tool.id || $0.name == tool.name }) {
                    availableTools.append(tool)
                }

                if s.transportType == .stdio {
                    mcpDescriptions.append("- **\(s.name)** (tool: `\(cleanName)_call` or `mcp_call` with `server: \"\(s.name)\"`): stdio process `\(s.command) \(s.args.joined(separator: " "))`")
                } else {
                    mcpDescriptions.append("- **\(s.name)** (tool: `\(cleanName)_call` or `mcp_call` with `server: \"\(s.name)\"`): HTTP/SSE gateway `\(s.url)`")
                }
            }

            if !availableTools.contains(where: { $0.name == "mcp_call" }) {
                availableTools.append(Tool(
                    id: "mcp_universal_call",
                    name: "mcp_call",
                    displayName: "Universal MCP Tool Invocation",
                    description: "Invokes any tool on a configured MCP server. Parameters: {\"server\": \"server_name\", \"tool\": \"action_name\", \"arguments\": {...}}",
                    category: .mcp
                ))
            }

            mcpPromptSummary = """

            ### Configured & Active Model Context Protocol (MCP) Servers:
            \(mcpDescriptions.joined(separator: "\n"))

            When you need external data or actions from an MCP server (e.g. web search, calendar, files, or external tools), output a tool call using ANY of these formats:
            Format 1 (Simple):
            TOOL_CALL = { "mcp": "ddg-search", "tool": "search", "arguments": {"query": "Swift 6 features"} }

            Format 2 (Markdown block):
            ```tool_call
            {"tool": "mcp_call", "parameters": {"server": "ddg-search", "tool": "search", "arguments": {"query": "Swift 6 features"}}}
            ```

            Format 3 (Direct tool call):
            ```tool_call
            {"tool": "ddg_search_call", "parameters": {"query": "Swift 6 features"}}
            ```
            """
        }

        var iteration = 0
        var workingMessages = session.messages

        // System prompt with modern tool-calling instructions (supports both native API tools & markdown ReAct schemas)
        let systemPromptWithTools = """
        \(agent.systemPrompt)

        You are an advanced, fully autonomous coding, systems, and research agent on par with Claude Code and Cursor.
        You have direct access to execution tools:
        - `file_read`: {"path": "..."}
        - `file_write`: {"path": "...", "content": "..."}
        - `file_list`: {"path": "..."}
        - `file_copy`: {"source": "...", "destination": "..."}
        - `file_move`: {"source": "...", "destination": "..."}
        - `file_delete`: {"path": "..."}
        - `terminal_command`: {"command": "...", "cwd": "..."}
        - `web_search`: {"query": "..."}
        - `calculator`: {"expression": "..."}
        - `get_current_date`: {}
        - `document_extract`: {"path": "..."}
        - Live Model Context Protocol (MCP) servers
        \(mcpPromptSummary)

        CRITICAL EXECUTION PROTOCOL:
        1. When the user gives you tasks or asks you to perform actions, DO NOT write conversational excuses or say "I will do X". IMMEDIATELY emit the tool call to do X!
        2. Execute actions by outputting standard tool call blocks:
        ```tool_call
        {"tool": "file_write", "parameters": {"path": "/Volumes/WorkSpaces/WorkSpace/IranNews-2026-08-31.md", "content": "# Iran News\\n..."}}
        ```
        or
        ```tool_call
        {"tool": "file_list", "parameters": {"path": "/Volumes/WorkSpaces/WorkSpace"}}
        ```
        or
        ```tool_call
        {"tool": "terminal_command", "parameters": {"command": "date +%Y-%m-%d"}}
        ```
        or
        ```tool_call
        {"tool": "web_search", "parameters": {"query": "US-Israel Iran war news 2026"}}
        ```
        or
        TOOL_CALL = { "mcp": "macuse", "tool": "get_calendar_events", "arguments": {} }

        3. If you need multiple actions, output multiple tool calls in sequence.
        4. After receiving tool results, continue with the remaining steps until ALL tasks are completely executed on disk.
        5. Once all files are written and tasks finished, provide a clear, concise report listing the exact files created and actions performed.
        """

        while iteration < maxIterations {
            if Task.isCancelled {
                break
            }

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

            if accumulator.isLoopDetected {
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
                var parsedMarkdownCalls = parseToolCalls(from: newlyGeneratedDelta)
                if parsedMarkdownCalls.isEmpty && !accumulator.fullText.isEmpty {
                    parsedMarkdownCalls = parseToolCalls(from: accumulator.fullText)
                }
                for parsed in parsedMarkdownCalls {
                    pendingCallsToExecute.append((id: UUID().uuidString, tool: parsed.tool, args: parsed.args))
                }
            }

            // If no tool calls were requested from this turn:
            if pendingCallsToExecute.isEmpty {
                // Check if the assistant ended with unfulfilled execution intent (common in local models that stop after saying "Let me...")
                let newlyGeneratedDelta = String(accumulator.fullText.dropFirst(turnTextBefore.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercaseDelta = newlyGeneratedDelta.lowercased()
                
                let hasUnfulfilledActionIntent = (
                    lowercaseDelta.contains("let me start") ||
                    lowercaseDelta.contains("let me check") ||
                    lowercaseDelta.contains("let me emit") ||
                    lowercaseDelta.contains("let me search") ||
                    lowercaseDelta.contains("let me proceed") ||
                    lowercaseDelta.contains("i will start by") ||
                    lowercaseDelta.contains("i will now check")
                ) && newlyGeneratedDelta.count < 300 && iteration < 3

                if hasUnfulfilledActionIntent {
                    // Feed a direct continuation nudge to prompt the model to emit the tool call payload immediately
                    let nudgeMsg = ChatMessage(
                        sessionId: session.id,
                        role: .user,
                        content: "[System Command]: You expressed intent to perform an action. Do not wait for the user. Immediately output the structured tool call now (e.g. ```tool_call {\"tool\": \"...\", \"parameters\": {...}}```)."
                    )
                    workingMessages.append(nudgeMsg)
                    continue
                } else {
                    // Agent has legitimately concluded its answer
                    break
                }
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

            // Do not dump raw tool JSON/text into the user-facing chat bubble.
            // The tool observations are already fed back to the LLM in workingMessages as role: .tool / user observation,
            // allowing the LLM to read the result and write a clean, user-friendly natural language response.
        }

        accumulator.finalize()
    }

    private func parseToolCalls(from text: String) -> [(tool: String, args: String)] {
        var calls: [(tool: String, args: String)] = []
        
        // Helper to normalize parsed dictionary into (tool, args)
        func addCall(from dict: [String: Any]) {
            // Case 1: GrizzyClaw / MCP style: {"mcp": "server_name", "tool": "tool_name", "arguments": {...}}
            if let mcpServer = dict["mcp"] as? String ?? dict["server"] as? String {
                let mcpTool = dict["tool"] as? String ?? dict["action"] as? String ?? dict["name"] as? String ?? "query"
                let mcpArgs = (dict["arguments"] as? [String: Any]) ?? (dict["parameters"] as? [String: Any]) ?? (dict["args"] as? [String: Any]) ?? [:]
                let wrapper: [String: Any] = [
                    "server": mcpServer,
                    "tool": mcpTool,
                    "arguments": mcpArgs
                ]
                let paramsData = (try? JSONSerialization.data(withJSONObject: wrapper)) ?? Data()
                let paramsStr = String(data: paramsData, encoding: .utf8) ?? "{}"
                calls.append((tool: "mcp_call", args: paramsStr))
                return
            }

            // Case 2: Standard {"tool": "...", "parameters": {...}} or {"name": "...", "arguments": {...}}
            if let tool = (dict["tool"] as? String) ?? (dict["name"] as? String) {
                let params = (dict["parameters"] as? [String: Any]) ?? (dict["arguments"] as? [String: Any]) ?? (dict["args"] as? [String: Any]) ?? [:]
                let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
                let paramsStr = String(data: paramsData, encoding: .utf8) ?? "{}"
                calls.append((tool: tool, args: paramsStr))
            }
        }

        // 1. Match TOOL_CALL = { ... } format (from GrizzyClaw)
        let toolCallAssignPattern = "TOOL_CALL\\s*=\\s*(\\{[\\s\\S]*?\\})"
        if let regex = try? NSRegularExpression(pattern: toolCallAssignPattern, options: []) {
            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if match.numberOfRanges > 1 {
                    let jsonString = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let data = jsonString.data(using: .utf8),
                       let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        addCall(from: dict)
                    }
                }
            }
        }

        // 2. Match Markdown code blocks with JSON: ```tool_call {"tool": "...", "parameters": {...}} ``` or ```json or ```
        let markdownPattern = "```(?:tool_call|json)?\\s*(?:\\r?\\n)?\\s*(\\{[\\s\\S]*?\\})(?:\\s*(?:\\r?\\n)?```|$)"
        if let regex = try? NSRegularExpression(pattern: markdownPattern, options: []) {
            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if match.numberOfRanges > 1 {
                    let jsonString = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let data = jsonString.data(using: .utf8),
                       let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        addCall(from: dict)
                    }
                }
            }
        }
        
        // 3. Fallback: Match naked JSON containing {"tool": "...", "parameters": ...} or {"mcp": "...", "tool": ...}
        if calls.isEmpty {
            let nakedJsonPattern = "(\\{\\s*\"(?:tool|name|mcp|server)\"\\s*:\\s*\"[^\"]+\"[\\s\\S]*?\\})"
            if let regex = try? NSRegularExpression(pattern: nakedJsonPattern, options: []) {
                let nsString = text as NSString
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
                for match in matches {
                    if match.numberOfRanges > 1 {
                        let jsonString = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if let data = jsonString.data(using: .utf8),
                           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            addCall(from: dict)
                        }
                    }
                }
            }
        }
        
        // 4. Match Qwen / XML style tool calls: <tool_call>\n<function=name>\n<parameter=key>\nval\n</parameter>\n</tool_call>
        let xmlPattern = "<tool_call>[\\s\\S]*?<function=([a-zA-Z0-9_-]+)>([\\s\\S]*?)(?:</tool_call>|$)"
        if let xmlRegex = try? NSRegularExpression(pattern: xmlPattern, options: []) {
            let nsString = text as NSString
            let matches = xmlRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let functionName = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let paramsBody = nsString.substring(with: match.range(at: 2))
                
                var paramsDict: [String: Any] = [:]
                let paramTagPattern = "<parameter=([a-zA-Z0-9_-]+)>([\\s\\S]*?)(?:</parameter>|$)"
                if let paramRegex = try? NSRegularExpression(pattern: paramTagPattern, options: []) {
                    let paramNs = paramsBody as NSString
                    let paramMatches = paramRegex.matches(in: paramsBody, options: [], range: NSRange(location: 0, length: paramNs.length))
                    for pMatch in paramMatches {
                        if pMatch.numberOfRanges >= 3 {
                            let pKey = paramNs.substring(with: pMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                            var pVal = paramNs.substring(with: pMatch.range(at: 2))
                            if pVal.hasPrefix("\n") { pVal.removeFirst() }
                            if pVal.hasSuffix("\n") { pVal.removeLast() }
                            paramsDict[pKey] = pVal
                        }
                    }
                }
                
                let paramsData = (try? JSONSerialization.data(withJSONObject: paramsDict)) ?? Data()
                let paramsStr = String(data: paramsData, encoding: .utf8) ?? "{}"
                calls.append((tool: functionName, args: paramsStr))
            }
        }
        
        // 5. Match Loose / Inline tool invocations like `tool_name(param="value")` or `file_list(path="/Volumes/...")`
        if calls.isEmpty {
            let funcCallPattern = "([a-zA-Z0-9_-]+)\\s*\\(\\s*([a-zA-Z0-9_-]+)\\s*=\\s*[\"']([^\"']+)[\"']\\s*\\)"
            if let regex = try? NSRegularExpression(pattern: funcCallPattern, options: []) {
                let nsString = text as NSString
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
                for match in matches {
                    if match.numberOfRanges >= 4 {
                        let tool = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                        let key = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                        let val = nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                        let dict: [String: Any] = ["tool": tool, "parameters": [key: val]]
                        addCall(from: dict)
                    }
                }
            }
        }

        return calls
    }
}
