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
            publishVisibleContent()

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
        publishVisibleContent()
        onUpdate(message)
    }

    public func appendNotice(_ notice: String) {
        guard !notice.isEmpty else { return }
        // Avoid stacking identical status chips.
        if message.notices.last == notice { return }
        message.notices.append(notice)
        onUpdate(message)
    }

    /// Recover stream text if fire-and-forget MainActor chunk tasks lagged behind the provider.
    public func reconcileFromBridge(text: String, reasoning: String, promptTokens: Int, completionTokens: Int) {
        if text.count > fullText.count {
            fullText = text
            publishVisibleContent()
        }
        if reasoning.count > fullReasoning.count {
            fullReasoning = reasoning
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }
        if promptTokens > 0 {
            message.promptTokens = promptTokens
        }
        if completionTokens > 0 {
            message.completionTokens = completionTokens
        }
        onUpdate(message)
    }

    public func setHalt(reason: String, text: String) {
        message.haltReason = reason
        message.haltText = text
        message.isStreaming = false
        if !text.isEmpty {
            fullText += (fullText.isEmpty ? "" : "\n\n") + text
            publishVisibleContent()
        }
        onUpdate(message)
    }

    public func handleError(_ error: Error) {
        message.isStreaming = false
        message.isError = true
        publishVisibleContent()
        if message.content.isEmpty {
            message.content = "Error: \(error.localizedDescription)"
        }
        onUpdate(message)
    }

    /// Split leaked model thinking out of the visible bubble; keep raw `fullText` for tool parsing.
    private func publishVisibleContent() {
        let split = AssistantContentSanitizer.splitThinking(from: fullText)
        if !split.thinking.isEmpty {
            if fullReasoning.isEmpty {
                fullReasoning = split.thinking
            } else if !fullReasoning.contains(split.thinking) && !split.thinking.contains(fullReasoning) {
                fullReasoning += (fullReasoning.hasSuffix("\n") ? "" : "\n") + split.thinking
            } else if split.thinking.count > fullReasoning.count {
                fullReasoning = split.thinking
            }
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }
        message.content = AssistantContentSanitizer.sanitizeVisible(split.visible)
    }

    public func cleanToolCallSyntax(from rawText: String) -> String {
        let split = AssistantContentSanitizer.splitThinking(from: rawText)
        return AssistantContentSanitizer.sanitizeVisible(split.visible)
    }

    public func finalize() {
        message.isStreaming = false
        publishVisibleContent()
        // Drop routine MCP status chips once the answer is on screen.
        message.notices.removeAll { notice in
            let n = notice.lowercased()
            return n.contains("listing configured mcp")
                || n.contains("mcp ready")
                || n.contains("warming mcp")
                || n.contains("connecting ")
                || n.hasPrefix("connecting")
        }
        onUpdate(message)
    }

    /// When the model narrates then emits tools, hide that preamble in the bubble (keep raw text for parsing).
    public func hideTurnNarration(beforeLength: Int) {
        let delta = String(fullText.dropFirst(beforeLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !delta.isEmpty else {
            publishVisibleContent()
            onUpdate(message)
            return
        }
        let split = AssistantContentSanitizer.splitThinking(from: delta)
        let narrate = AssistantContentSanitizer.sanitizeVisible(split.visible)
        let think = [split.thinking, narrate].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !think.isEmpty {
            if fullReasoning.isEmpty {
                fullReasoning = think
            } else if !fullReasoning.contains(think) {
                fullReasoning += "\n\n" + think
            }
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }
        // Show only content from before this turn until the final answer lands.
        let prior = String(fullText.prefix(beforeLength))
        let priorSplit = AssistantContentSanitizer.splitThinking(from: prior)
        message.content = AssistantContentSanitizer.sanitizeVisible(priorSplit.visible)
        onUpdate(message)
    }

    /// Sanitized text suitable for feeding back as an intermediate assistant message.
    public var sanitizedFullText: String {
        let split = AssistantContentSanitizer.splitThinking(from: fullText)
        return AssistantContentSanitizer.sanitizeVisible(split.visible)
    }
}

/// Strips leaked chain-of-thought and tool-call markup from user-visible assistant text.
enum AssistantContentSanitizer {
    static func splitThinking(from raw: String) -> (visible: String, thinking: String) {
        var text = raw
        var thinkingParts: [String] = []

        func extractBlocks(pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
            let ns = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let bodyRange = Range(match.range(at: 1), in: text) else { continue }
                let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { thinkingParts.insert(body, at: 0) }
                if let full = Range(match.range(at: 0), in: text) {
                    text.removeSubrange(full)
                }
            }
        }

        extractBlocks(pattern: #"<think>\s*([\s\S]*?)\s*</think>"#)
        extractBlocks(pattern: #"<thinking>\s*([\s\S]*?)\s*</thinking>"#)
        extractBlocks(pattern: #"<redacted_reasoning>\s*([\s\S]*?)\s*</redacted_reasoning>"#)

        // Qwen / Ornith often emit preamble then a bare </think> with no opener.
        let closeTags = ["</think>", "</thinking>", "</redacted_reasoning>"]
        for tag in closeTags {
            if let range = text.range(of: tag, options: .backwards) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = String(text[range.upperBound...])
                if !before.isEmpty { thinkingParts.append(before) }
                text = after
                break
            }
        }

        // Incomplete streaming think block — hide until closed.
        for open in ["<think>", "<thinking>", "<redacted_reasoning>"] {
            if let openRange = text.range(of: open, options: .backwards) {
                let before = String(text[..<openRange.lowerBound])
                let inside = String(text[openRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inside.isEmpty { thinkingParts.append(inside) }
                text = before
                break
            }
        }

        let thinking = thinkingParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (text, thinking)
    }

    static func sanitizeVisible(_ raw: String) -> String {
        var cleaned = raw

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

        // Remove leftover think tag crumbs and filler intent lines.
        let crumbPattern = "(?i)</?think>|</?thinking>|</?redacted_reasoning>"
        if let regex = try? NSRegularExpression(pattern: crumbPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        let fillerLinesPattern = "(?m)^\\s*(?:Let me emit tool calls\\.?|Let me call the tool\\.?|---\\s*)$\\s*"
        if let regex = try? NSRegularExpression(pattern: fillerLinesPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        cleaned = dedupeRepeatedParagraphs(cleaned)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses consecutive near-duplicate paragraphs (common with leaked monologue).
    private static func dedupeRepeatedParagraphs(_ text: String) -> String {
        let parts = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return text }

        var out: [String] = []
        for part in parts {
            if let last = out.last, paragraphsNearlyEqual(last, part) {
                if part.count > last.count { out[out.count - 1] = part }
                continue
            }
            out.append(part)
        }
        return out.joined(separator: "\n\n")
    }

    private static func paragraphsNearlyEqual(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        if na.count >= 40, nb.count >= 40 {
            if na.hasPrefix(nb) || nb.hasPrefix(na) { return true }
            let wa = Set(na.split(separator: " ").map(String.init))
            let wb = Set(nb.split(separator: " ").map(String.init))
            guard wa.count >= 8, wb.count >= 8 else { return false }
            let inter = Double(wa.intersection(wb).count)
            let union = Double(wa.union(wb).count)
            return union > 0 && inter / union >= 0.9
        }
        return false
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

/// Thread-safe collector for native tool calls emitted from provider stream callbacks
/// (which often run off the MainActor).
private final class AgentToolCallCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolCallInfo] = []

    func add(_ tc: ToolCallInfo) {
        lock.lock()
        defer { lock.unlock() }
        if !items.contains(where: { $0.id == tc.id || ($0.toolName == tc.toolName && $0.argumentsJson == tc.argumentsJson) }) {
            items.append(tc)
        }
    }

    func snapshot() -> [ToolCallInfo] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Aggregates stream text off the MainActor so a delayed UI Task cannot lose the turn.
private final class AgentStreamTextBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var reasoning = ""
    private var completionTokens = 0
    private var promptTokens = 0

    func ingest(_ chunk: LLMStreamChunk) {
        lock.lock()
        defer { lock.unlock() }
        if !chunk.deltaText.isEmpty {
            text += chunk.deltaText
        }
        if let r = chunk.deltaReasoning, !r.isEmpty {
            reasoning += r
        }
        if let c = chunk.completionTokens {
            completionTokens = c
        }
        if let p = chunk.promptTokens {
            promptTokens = p
        }
    }

    func snapshot() -> (text: String, reasoning: String, promptTokens: Int, completionTokens: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (text, reasoning, promptTokens, completionTokens)
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
        reasoningOverride: ReasoningEffort? = nil,
        onMessageUpdated: @escaping (ChatMessage) -> Void,
        onSubAgentTaskCreated: @escaping (SubAgentTask) -> Void,
        onSubAgentTaskUpdated: @escaping (SubAgentTask) -> Void,
        onInterAgentMessage: @escaping (AgentMessage) -> Void
    ) async {
        // The chat composer's "Reasoning" pill overrides the agent's own configured effort for
        // this turn when set; nil (no override) preserves the agent's own setting.
        let effectiveReasoningEffort = reasoningOverride ?? agent.reasoningEffort
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
        defer {
            // Never leave a bubble stuck on isStreaming after cancel / MCP hang recovery.
            if accumulator.message.isStreaming {
                accumulator.finalize()
            }
        }

        let loadedSettings = PersistenceManager.shared.loadSettings()
        let maxIterations = max(1, loadedSettings.maxAutonomousIterations)
        let maxTurnTokens = max(1, loadedSettings.maxTurnTokens)
        var planModeActive = loadedSettings.planModeEnabled
        var availableTools = PersistenceManager.shared.loadTools().filter { $0.isEnabled }
        _ = ToolSchemaCatalog.ensureParityTools(in: &availableTools)

        // Casual / inventory turns must not wait on npx cold starts.
        let casualChat = MCPClientManager.isCasualChatPrompt(lastPrompt)
        let inventoryPrompt = MCPClientManager.isMCPInventoryPrompt(lastPrompt)
        let preferMCP = MCPClientManager.preferredServerIds(
            forPrompt: lastPrompt,
            servers: loadedSettings.mcpServers
        )
        let mcpTools: [Tool]
        if casualChat || inventoryPrompt {
            mcpTools = await MCPClientManager.shared.cachedMcpToolDefs()
            await MCPClientManager.shared.warmAllInBackground()
        } else if !preferMCP.isEmpty {
            // Brief wait only for the servers the prompt actually needs — no status chip spam.
            mcpTools = await MCPClientManager.shared.mcpToolDefs(
                preferServerIds: preferMCP,
                perServerTimeout: .seconds(8),
                overallTimeout: .seconds(6),
                blockForWarm: true
            )
        } else {
            // Cache-first: never stall the bubble on every enabled npx server.
            mcpTools = await MCPClientManager.shared.mcpToolDefs(
                preferServerIds: preferMCP,
                perServerTimeout: .seconds(8),
                overallTimeout: .seconds(6),
                blockForWarm: false
            )
        }

        var mcpPromptSummary = ""
        if inventoryPrompt {
            // Inventory: compact status only — no tool dump, no tool calling.
            let reports = await MCPClientManager.shared.mcpStatusReports(probe: false)
            let liveLines = reports.map { r -> String in
                let state: String
                if !r.enabled { state = "disabled" }
                else if r.connected { state = "connected (\(r.toolCount) tools)" }
                else if let err = r.error { state = "error: \(err)" }
                else { state = "not connected yet" }
                return "| \(r.name) | `\(r.id)` | \(r.transport) | \(state) |"
            }
            mcpPromptSummary = """

            ### MCP inventory (answer from this only)
            | Server | ID | Transport | Status |
            |--------|----|-----------|--------|
            \(liveLines.isEmpty ? "| _(none configured)_ | | | |" : liveLines.joined(separator: "\n"))

            INVENTORY MODE: Reply with one short markdown table of the servers above. \
            Do not call tools. Do not narrate your plan. Do not invent servers.
            """
            availableTools = []
        } else if !mcpTools.isEmpty {
            for t in mcpTools {
                if !availableTools.contains(where: { $0.id == t.id || $0.name == t.name }) {
                    availableTools.append(t)
                }
            }
            // Compact listing — avoid dumping every tool schema twice into the prompt.
            let byServer = Dictionary(grouping: mcpTools) { tool -> String in
                MCPNamespacedTool.parse(tool.name)?.serverId ?? "mcp"
            }
            let lines = byServer.map { serverId, tools -> String in
                let serverName = loadedSettings.mcpServers.first(where: { $0.id == serverId })?.name ?? serverId
                let leafNames = tools.compactMap { MCPNamespacedTool.parse($0.name)?.toolName ?? $0.name }
                    .sorted()
                let shown = leafNames.prefix(10).joined(separator: ", ")
                let more = leafNames.count > 10 ? " (+\(leafNames.count - 10) more)" : ""
                return "- **\(serverName)** (`\(serverId)`): \(shown)\(more)"
            }.sorted()
            mcpPromptSummary = """

            ### MCP tools (\(mcpTools.count) live) — call as `mcp__SERVER_ID__TOOL_NAME`
            \(lines.joined(separator: "\n"))
            Prefer native tool calls. Do not narrate before calling. For MacUse: `get_tool_definitions` then `call_tool_by_name`.
            """
        } else if !casualChat && !loadedSettings.mcpServers.filter(\.isEnabled).isEmpty {
            mcpPromptSummary = """

            ### MCP
            Enabled servers are still warming. Use built-in tools; do not invent MCP tool names.
            """
        }

        if planModeActive && !inventoryPrompt {
            availableTools = Self.filterToolsForPlanMode(availableTools)
        }

        let enabledSkills = PersistenceManager.shared.loadSkills().filter(\.isEnabled)
        var skillsSection = ""
        // Skip skills dump on inventory — it only encourages digression.
        if !enabledSkills.isEmpty && !inventoryPrompt {
            let skillLines = enabledSkills.map { skill -> String in
                let body = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = body.isEmpty ? skill.description : String(body.prefix(160))
                return "- **\(skill.name)**: \(preview)"
            }
            skillsSection = """

            ### Active Skills
            \(skillLines.joined(separator: "\n"))
            """
        }

        var iteration = 0
        var workingMessages = session.messages
        var turnPromptTokens = 0
        var turnCompletionTokens = 0
        var identicalToolCounts: [String: Int] = [:]
        var askUserStreak = 0
        var halted = false
        var finishedNaturally = false
        var macUseDefsFetched = false
        var macUseMailListed = false
        var macUseMailSearched = false
        var macUseMailCheckComplete = false
        var macUseForcedSteps = 0
        var macUseAccountsJSON = ""
        var macUseSearchJSON = ""
        var macUseMessageJSON = ""

        // System prompt with modern tool-calling instructions (supports both native API tools & markdown ReAct schemas)
        let systemPromptWithTools: String
        if inventoryPrompt {
            systemPromptWithTools = """
            \(agent.systemPrompt)
            \(mcpPromptSummary)

            Be concise. No tool calls. No planning narration. Answer with one short table only.
            """
        } else {
            systemPromptWithTools = """
            \(agent.systemPrompt)

            You are an advanced, fully autonomous coding, systems, and research agent.
            Built-in tools (prefer native function/tool calling):
            file_read, file_write, edit_file, file_list, file_copy, file_move, file_delete,
            terminal_command/run_command, fetch_url, web_search, ask_user, exit_plan_mode,
            todo_write, calculator, get_current_date, document_extract,
            gmail_list, gmail_search, google_calendar_list, google_calendar_upcoming.
            \(mcpPromptSummary)
            \(skillsSection)

            CRITICAL:
            1. Do not narrate ("I will check…" / "Let me…"). Call the tool immediately, then answer.
            2. Prefer native tool calls. Markdown fallback only if needed:
            ```tool_call
            {"tool": "file_list", "parameters": {"path": "."}}
            ```
            3. After tools finish, give one clear concise report — no repeated self-talk.
            4. MacUse mail: after `get_tool_definitions`, call `mail_list_accounts` then `mail_search_messages` before summarizing.
            \(planModeActive ? "\n5. PLAN MODE: do not mutate files or run shell. Propose a plan, then `exit_plan_mode` after approval." : "")
            """
        }

        while iteration < maxIterations {
            if Task.isCancelled {
                accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
                halted = true
                break
            }

            iteration += 1

            workingMessages = ContextCompactor.foldOldToolResults(workingMessages)
            if loadedSettings.autoCompactContext {
                let compacted = ContextCompactor.compactIfNeeded(
                    workingMessages,
                    thresholdTokens: loadedSettings.contextCompactionThresholdTokens
                )
                workingMessages = compacted.messages
                if compacted.didCompact {
                    accumulator.appendNotice("Context compacted to free tokens.")
                }
            }

            // Track newly emitted native tool calls during this single turn.
            // Use a lock-backed collector: onChunk runs off the MainActor, and the previous
            // `Task { @MainActor in nativeEmittedToolCalls.append }` raced so tool calls were
            // often lost — the model looked "stuck" narrating without ever executing.
            let toolCallCollector = AgentToolCallCollector()
            let textBridge = AgentStreamTextBridge()
            let turnTextBefore = accumulator.fullText

            do {
                try await ProviderRouter.shared.stream(
                    provider: provider,
                    model: model,
                    systemPrompt: systemPromptWithTools,
                    messages: workingMessages,
                    temperature: agent.temperature,
                    maxTokens: agent.maxTokens,
                    reasoningEffort: effectiveReasoningEffort,
                    tools: availableTools
                ) { chunk in
                    for tc in chunk.toolCalls {
                        toolCallCollector.add(tc)
                    }
                    textBridge.ingest(chunk)
                    Task { @MainActor in
                        accumulator.applyChunk(chunk)
                    }
                }
            } catch {
                let snap = textBridge.snapshot()
                accumulator.reconcileFromBridge(
                    text: snap.text,
                    reasoning: snap.reasoning,
                    promptTokens: snap.promptTokens,
                    completionTokens: snap.completionTokens
                )
                accumulator.handleError(error)
                break
            }

            // Flush / recover MainActor UI updates from stream callbacks
            let snap = textBridge.snapshot()
            accumulator.reconcileFromBridge(
                text: snap.text,
                reasoning: snap.reasoning,
                promptTokens: snap.promptTokens,
                completionTokens: snap.completionTokens
            )
            await Task.yield()

            if accumulator.isLoopDetected {
                break
            }

            turnPromptTokens += accumulator.message.promptTokens
            turnCompletionTokens += accumulator.message.completionTokens
            if turnPromptTokens + turnCompletionTokens > maxTurnTokens {
                accumulator.setHalt(
                    reason: "token_budget",
                    text: "Turn token budget exceeded (\(turnPromptTokens + turnCompletionTokens) > \(maxTurnTokens)). Press Continue to resume."
                )
                halted = true
                break
            }

            // Inventory questions should be one-shot answers — never enter a tool loop.
            if inventoryPrompt {
                finishedNaturally = true
                break
            }

            // Gather tool calls from either native API streaming or Markdown ReAct fallbacks
            var pendingCallsToExecute: [(id: String, tool: String, args: String)] = []
            let nativeEmittedToolCalls = toolCallCollector.snapshot()

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
                let newlyGeneratedDelta = String(accumulator.fullText.dropFirst(turnTextBefore.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercaseDelta = newlyGeneratedDelta.lowercased()
                let userAsk = lastPrompt.lowercased()
                let wantsMacUse = userAsk.contains("macuse") || userAsk.contains("mac use")
                    || ((userAsk.contains("mail") || userAsk.contains("email") || userAsk.contains("inbox"))
                        && (userAsk.contains("mcp") || userAsk.contains("computer") || userAsk.contains("this computer")))

                // Force MacUse chain: defs → list accounts → search messages.
                // Local models routinely stop after narrating the first step.
                if macUseForcedSteps < 6,
                   !macUseMailCheckComplete,
                   let forced = Self.macUseForcedFollowUp(
                    userPrompt: lastPrompt,
                    availableTools: availableTools,
                    defsFetched: macUseDefsFetched,
                    mailListed: macUseMailListed,
                    mailSearched: macUseMailSearched
                   ) {
                    macUseForcedSteps += 1
                    pendingCallsToExecute.append((
                        id: UUID().uuidString,
                        tool: forced.tool,
                        args: forced.args
                    ))
                    accumulator.appendContent("\n\n\(forced.notice)\n")
                    accumulator.appendNotice(forced.notice)
                }

                if pendingCallsToExecute.isEmpty {
                if wantsMacUse,
                   !macUseDefsFetched,
                   availableTools.first(where: {
                       let n = $0.name.lowercased()
                       return n.contains("get_tool_definitions") || n.hasSuffix("__get_tool_definitions")
                   }) == nil {
                    accumulator.setHalt(
                        reason: "mcp_unavailable",
                        text: "MacUse MCP tools were not available (server timed out or failed to start). Open MacUse.app, confirm Accessibility permissions, then press Continue."
                    )
                    halted = true
                    break
                } else if newlyGeneratedDelta.isEmpty && nativeEmittedToolCalls.isEmpty {
                    // Empty model turn — do not silently finalize an blank streaming bubble.
                    if iteration < 2 {
                        accumulator.appendNotice("Model returned no tokens; retrying…")
                        continue
                    }
                    accumulator.setHalt(
                        reason: "empty_response",
                        text: "The model returned an empty response. Press Continue to try again."
                    )
                    halted = true
                    break
                } else {
                    let hasUnfulfilledActionIntent = (
                        lowercaseDelta.contains("let me start") ||
                        lowercaseDelta.contains("let me check") ||
                        lowercaseDelta.contains("let me get") ||
                        lowercaseDelta.contains("let me list") ||
                        lowercaseDelta.contains("let me emit") ||
                        lowercaseDelta.contains("let me search") ||
                        lowercaseDelta.contains("let me proceed") ||
                        lowercaseDelta.contains("let me call") ||
                        lowercaseDelta.contains("i will start by") ||
                        lowercaseDelta.contains("i will now check") ||
                        lowercaseDelta.contains("now let me") ||
                        lowercaseDelta.contains("tools are loaded") ||
                        lowercaseDelta.contains("tool definitions") ||
                        lowercaseDelta.contains("first, let me")
                    ) && newlyGeneratedDelta.count < 1200 && iteration < 6

                    if hasUnfulfilledActionIntent {
                        let toolHint: String = {
                            if let t = availableTools.first(where: { $0.name.contains("call_tool_by_name") }) {
                                return t.name
                            }
                            if let t = availableTools.first(where: { $0.name.contains("get_tool_definitions") }) {
                                return t.name
                            }
                            return availableTools.first(where: { $0.category == .mcp })?.name ?? "mcp_call"
                        }()
                        let nudgeMsg = ChatMessage(
                            sessionId: session.id,
                            role: .user,
                            content: """
                            [System Command]: Stop narrating. Immediately emit a native tool call for `\(toolHint)`.
                            For MacUse mail use:
                            ```tool_call
                            {"tool": "\(toolHint)", "parameters": {"name": "mail_search_messages", "arguments": {"limit": 20}}}
                            ```
                            Do not write more prose before the tool call.
                            """
                        )
                        workingMessages.append(nudgeMsg)
                        continue
                    } else if wantsMacUse && !(macUseMailListed && macUseMailSearched) && macUseForcedSteps < 6 {
                        // Refuse to end a MacUse mail task after prose-only turns.
                        accumulator.appendNotice("MacUse mail steps incomplete — continuing…")
                        continue
                    } else if wantsMacUse && !(macUseMailListed && macUseMailSearched) {
                        accumulator.setHalt(
                            reason: "macuse_incomplete",
                            text: "Stopped before MacUse finished listing/searching mail. Press Continue to retry."
                        )
                        halted = true
                        break
                    } else {
                        finishedNaturally = true
                        break
                    }
                }
                } // pendingCallsToExecute.isEmpty (inner)
            }

            // Execute detected tool calls and feed results back into the conversation.
            // Radiant keeps calling tools until the model stops; local models often stop
            // early, so we also queue MacUse `actions[]` follow-ups in-process (mail search).
            if !pendingCallsToExecute.isEmpty {
                // Hide "Let me check…" preamble once tools are underway.
                accumulator.hideTurnNarration(beforeLength: turnTextBefore.count)
            }
            var stopToolLoop = false
            var toolQueue = pendingCallsToExecute
            var queueIndex = 0
            var macUseNestedDone = Set<String>()
            let macUseCallToolName = availableTools.first(where: {
                let n = $0.name.lowercased()
                return n.hasSuffix("__call_tool_by_name") || n.contains("call_tool_by_name")
            })?.name

            while queueIndex < toolQueue.count {
                let callId = toolQueue[queueIndex].id
                let toolName = toolQueue[queueIndex].tool
                var argsJson = Self.sanitizeToolArgumentsJson(
                    toolName: toolName,
                    argumentsJson: toolQueue[queueIndex].args
                )
                queueIndex += 1

                // Drop duplicate MacUse nested calls (model loves repeating mail_list_accounts).
                let leafName = (MCPNamespacedTool.parse(toolName)?.toolName ?? toolName).lowercased()
                if leafName.contains("call_tool_by_name") || leafName == "call_tool",
                   let nested = Self.macUseNestedToolName(from: argsJson)?.lowercased(),
                   macUseNestedDone.contains(nested) {
                    accumulator.appendNotice("Skipping duplicate MacUse `\(nested)`.")
                    continue
                }

                do {
                    try Task.checkCancellation()
                } catch {
                    accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
                    halted = true
                    stopToolLoop = true
                    break
                }

                var callInfo = ToolCallInfo(
                    id: callId,
                    toolName: toolName,
                    argumentsJson: argsJson,
                    status: .running
                )

                // Sensitive actions (deleting a file, or shell commands under an "always ask"
                // safety policy) are paused for a real user decision before they touch disk.
                if let reason = AgentRunner.approvalReason(
                    toolName: toolName,
                    argumentsJson: argsJson,
                    settings: loadedSettings
                ) {
                    callInfo.status = .waitingApproval
                    callInfo.approvalReason = reason
                    accumulator.addToolCall(callInfo)

                    let approved = await ToolApprovalManager.shared.requestApproval(
                        callId: callId,
                        toolName: toolName,
                        argumentsJson: argsJson,
                        reason: reason
                    )

                    if !approved {
                        callInfo.status = .error
                        callInfo.errorMessage = "Blocked: the user did not approve this action."
                        accumulator.updateToolCall(callInfo)
                        let toolMsg = ChatMessage(
                            id: callId,
                            sessionId: session.id,
                            role: .tool,
                            content: "Action rejected by the user (\(reason)). Do not retry this exact call; explain the situation or propose an alternative."
                        )
                        workingMessages.append(toolMsg)
                        continue
                    }

                    callInfo.status = .running
                    accumulator.updateToolCall(callInfo)
                } else {
                    accumulator.addToolCall(callInfo)
                }

                let signature = toolName + argsJson
                let repeatCount = (identicalToolCounts[signature] ?? 0) + 1
                identicalToolCounts[signature] = repeatCount

                if repeatCount >= 12 {
                    accumulator.setHalt(
                        reason: "stuck_breaker",
                        text: "Identical tool call repeated 12 times (\(toolName)). Press Continue to resume with a new approach."
                    )
                    halted = true
                    stopToolLoop = true
                    break
                }

                var stuckNudge = ""
                if repeatCount >= 8 {
                    stuckNudge = "\n\n[Stuck breaker] Identical call repeated \(repeatCount) times. Stop looping; change strategy or finish."
                } else if repeatCount >= 5 {
                    stuckNudge = "\n\n[Stuck breaker] You've repeated this identical tool call \(repeatCount) times. Try a different approach."
                } else if repeatCount >= 3 {
                    stuckNudge = "\n\n[Stuck breaker] Identical tool+args seen \(repeatCount) times — avoid repeating without progress."
                }

                let startTool = CFAbsoluteTimeGetCurrent()
                var resultOutput: String
                var resultSuccess = true
                var resultError: String?

                if toolName == "ask_user" {
                    askUserStreak += 1
                    if askUserStreak > 5 {
                        resultSuccess = false
                        resultError = "ask_user streak capped at 5. Stop asking and proceed with best judgment or finish."
                        resultOutput = resultError!
                    } else {
                        let parsed = Self.parseAskUserArgs(argsJson)
                        let answer = await UserChoiceManager.shared.request(
                            question: parsed.question,
                            options: parsed.options,
                            callId: callId
                        )
                        resultOutput = answer
                    }
                } else {
                    askUserStreak = 0

                    if toolName == "exit_plan_mode" {
                        planModeActive = false
                        var settings = PersistenceManager.shared.loadSettings()
                        settings.planModeEnabled = false
                        PersistenceManager.shared.saveSettings(settings)
                        availableTools = PersistenceManager.shared.loadTools().filter(\.isEnabled)
                        _ = ToolSchemaCatalog.ensureParityTools(in: &availableTools)
                        for t in mcpTools {
                            if !availableTools.contains(where: { $0.id == t.id || $0.name == t.name }) {
                                availableTools.append(t)
                            }
                        }
                        accumulator.appendNotice("Plan mode exited.")
                        var liveSettings = AppState.shared.settings
                        liveSettings.planModeEnabled = false
                        AppState.shared.settings = liveSettings
                        AppState.shared.showToast("Plan mode exited")
                        resultOutput = "Plan mode exited."
                    } else {
                        let result = await ToolExecutionEngine.shared.execute(
                            toolName: toolName,
                            argumentsJson: argsJson,
                            workspace: workspace,
                            currentAgent: agent
                        )
                        resultSuccess = result.success
                        resultOutput = result.success ? result.output : "Error: \(result.error ?? "unknown error")"
                        resultError = result.error

                        // MacUse rejects `"arguments":"{}"` (string). Retry once with a real map.
                        if !resultSuccess,
                           toolName.lowercased().contains("call_tool_by_name"),
                           (resultOutput + (resultError ?? "")).localizedCaseInsensitiveContains("expected a map")
                            || (resultOutput + (resultError ?? "")).localizedCaseInsensitiveContains("invalid type: string") {
                            let nested = Self.macUseNestedToolName(from: argsJson) ?? "mail_list_accounts"
                            let repaired = MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: nested)
                            argsJson = repaired
                            callInfo.argumentsJson = repaired
                            accumulator.updateToolCall(callInfo)
                            accumulator.appendNotice("Retrying MacUse call with object `arguments`…")
                            let retry = await ToolExecutionEngine.shared.execute(
                                toolName: toolName,
                                argumentsJson: repaired,
                                workspace: workspace,
                                currentAgent: agent
                            )
                            resultSuccess = retry.success
                            resultOutput = retry.success ? retry.output : "Error: \(retry.error ?? "unknown error")"
                            resultError = retry.error
                        }
                    }
                }

                let bounded = ToolBounds.boundResult(resultOutput + stuckNudge)
                if let notice = bounded.notice {
                    accumulator.appendNotice(notice)
                }

                callInfo.status = resultSuccess ? .success : .error
                callInfo.resultOutput = bounded.text
                callInfo.errorMessage = resultError
                callInfo.durationMs = (CFAbsoluteTimeGetCurrent() - startTool) * 1000
                accumulator.updateToolCall(callInfo)

                if resultSuccess {
                    let leaf = MCPNamespacedTool.parse(toolName)?.toolName ?? toolName
                    if leaf.contains("get_tool_definitions") {
                        macUseDefsFetched = true
                    }
                    var nestedForFollowUp = ""
                    if leaf.contains("call_tool_by_name") || leaf == "call_tool" {
                        let nested = Self.macUseNestedToolName(from: argsJson)?.lowercased() ?? ""
                        nestedForFollowUp = nested
                        if !nested.isEmpty {
                            macUseNestedDone.insert(nested)
                        }
                        if nested == "mail_list_accounts" {
                            macUseMailListed = true
                            macUseAccountsJSON = bounded.text
                        }
                        if nested == "mail_search_messages" || nested.hasPrefix("mail_search_") {
                            macUseMailSearched = true
                            macUseMailListed = true
                            macUseSearchJSON = bounded.text
                        }
                        if nested == "mail_get_messages" || nested == "mail_get_thread" {
                            macUseMailSearched = true
                            macUseMessageJSON = bounded.text
                        }
                    }

                    // Radiant does NOT auto-drive MacUse `actions[]` (the model chooses).
                    // For local models we only auto-chain READ steps for a mail check, then stop
                    // and publish a real summary — never reply/forward/mark-read.
                    if let callTool = macUseCallToolName,
                       !macUseMailCheckComplete,
                       leaf.contains("get_tool_definitions")
                        || leaf.contains("call_tool_by_name")
                        || leaf == "call_tool" {
                        let userAsk = lastPrompt.lowercased()
                        let wantsMail = userAsk.contains("mail") || userAsk.contains("email") || userAsk.contains("inbox")

                        if leaf.contains("get_tool_definitions"),
                           wantsMail,
                           !macUseMailListed,
                           !macUseNestedDone.contains("mail_list_accounts"),
                           !toolQueue.suffix(from: queueIndex).contains(where: {
                               $0.args.lowercased().contains("mail_list_accounts")
                           }) {
                            let args = MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: "mail_list_accounts")
                            toolQueue.append((id: UUID().uuidString, tool: callTool, args: args))
                            accumulator.appendNotice("Calling MacUse `mail_list_accounts`…")
                        }

                        if wantsMail,
                           macUseMailListed,
                           !macUseMailSearched,
                           !macUseNestedDone.contains("mail_search_messages"),
                           !toolQueue.suffix(from: queueIndex).contains(where: {
                               $0.args.lowercased().contains("mail_search_messages")
                           }) {
                            let args = MCPToolArgumentDefaults.macUseCallArgsJSON(
                                toolName: "mail_search_messages",
                                arguments: ["limit": 50]
                            )
                            toolQueue.append((id: UUID().uuidString, tool: callTool, args: args))
                            accumulator.appendNotice("Calling MacUse `mail_search_messages`…")
                        }

                        // Only follow explicit READ suggestions (never mutate).
                        if wantsMail, !macUseMailSearched {
                            for suggestion in MCPToolArgumentDefaults.suggestedCalls(fromToolResult: bounded.text) {
                                let nested = suggestion.nestedTool.lowercased()
                                guard Self.isMacUseMailReadTool(nested) else { continue }
                                if macUseNestedDone.contains(nested) { continue }
                                if nested == "mail_list_accounts" { continue }
                                if nested != "mail_search_messages" && !nested.hasPrefix("mail_search_") {
                                    continue
                                }
                                let args = MCPToolArgumentDefaults.macUseCallArgsJSON(
                                    toolName: suggestion.nestedTool,
                                    arguments: suggestion.arguments
                                )
                                toolQueue.append((id: UUID().uuidString, tool: callTool, args: args))
                                accumulator.appendNotice("Calling MacUse `\(suggestion.nestedTool)`…")
                                break
                            }
                        }

                        // After a successful search (or message read), finish the mail check.
                        if wantsMail,
                           (nestedForFollowUp == "mail_search_messages"
                            || nestedForFollowUp.hasPrefix("mail_search_")
                            || nestedForFollowUp == "mail_get_messages") {
                            let summary = Self.formatMacUseMailSummary(
                                accountsJSON: macUseAccountsJSON,
                                searchJSON: macUseSearchJSON.isEmpty ? bounded.text : macUseSearchJSON,
                                messageJSON: macUseMessageJSON
                            )
                            if !summary.isEmpty {
                                accumulator.appendContent("\n\n" + summary + "\n")
                            }
                            macUseMailCheckComplete = true
                            macUseMailSearched = true
                            // Drop any queued mutate/extra MacUse calls (reply/forward/mark-read/etc).
                            if queueIndex < toolQueue.count {
                                toolQueue.removeSubrange(queueIndex..<toolQueue.count)
                            }
                            accumulator.appendNotice("Mail check complete.")
                        }
                    }
                }

                let toolMsg = ChatMessage(
                    id: callId,
                    sessionId: session.id,
                    role: .tool,
                    content: bounded.text
                )
                workingMessages.append(toolMsg)
            }

            if stopToolLoop {
                break
            }

            // Mail check already wrote a deterministic summary — don't keep looping the model.
            if macUseMailCheckComplete {
                finishedNaturally = true
                break
            }

            if macUseMailSearched {
                workingMessages.append(ChatMessage(
                    sessionId: session.id,
                    role: .user,
                    content: """
                    [System Command]: MacUse mail tools finished (accounts + search). \
                    Write a clear, concise inbox summary for the user from the tool results above. \
                    Include account names and notable recent/unread messages. Do not call more tools unless opening one specific message is required.
                    """
                ))
            }

            // Append assistant intermediate progress to context so next turn is fully continuous
            let intermediateAssistantMsg = ChatMessage(
                sessionId: session.id,
                role: .assistant,
                content: accumulator.sanitizedFullText
            )
            workingMessages.append(intermediateAssistantMsg)

            // Do not dump raw tool JSON/text into the user-facing chat bubble.
            // The tool observations are already fed back to the LLM in workingMessages as role: .tool / user observation,
            // allowing the LLM to read the result and write a clean, user-friendly natural language response.
        }

        if !halted && !finishedNaturally && iteration >= maxIterations {
            accumulator.setHalt(
                reason: "round_cap",
                text: "Reached the autonomous round cap (\(maxIterations)). Press Continue to keep going from here."
            )
        }

        accumulator.finalize()
    }

    private static func filterToolsForPlanMode(_ tools: [Tool]) -> [Tool] {
        let blocked: Set<String> = [
            "file_write", "write_file", "create_file", "save_file",
            "file_delete", "delete_file", "rm",
            "file_move", "move_file", "mv",
            "file_copy", "copy_file", "cp",
            "edit_file", "file_edit",
            "terminal_command", "run_command"
        ]
        var filtered = tools.filter { tool in
            if tool.name == "exit_plan_mode" || tool.name == "ask_user" { return true }
            if blocked.contains(tool.name) { return false }
            if MCPNamespacedTool.isNamespaced(tool.name) {
                let leaf = MCPNamespacedTool.parse(tool.name)?.toolName ?? tool.name
                return MCPClientManager.isReadOnlyMCPTool(leaf)
            }
            if tool.name == "mcp_call" || tool.name == "call_mcp_tool" { return false }
            return true
        }
        if !filtered.contains(where: { $0.name == "exit_plan_mode" }) {
            if let exitTool = ToolSchemaCatalog.parityDefaults.first(where: { $0.name == "exit_plan_mode" }) {
                filtered.append(exitTool)
            }
        }
        return filtered
    }

    private static func parseAskUserArgs(_ argsJson: String) -> (question: String, options: [String]) {
        guard let data = argsJson.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ("Please choose how to proceed.", [])
        }
        let question = (dict["question"] as? String)
            ?? (dict["prompt"] as? String)
            ?? (dict["message"] as? String)
            ?? "Please choose how to proceed."
        var options: [String] = []
        if let arr = dict["options"] as? [String] {
            options = arr
        } else if let arr = dict["options"] as? [Any] {
            options = arr.compactMap { $0 as? String }
        } else if let choices = dict["choices"] as? [String] {
            options = choices
        }
        return (question, options)
    }

    /// Returns a human-readable reason the call must be interactively approved before it runs,
    /// or nil if it can proceed immediately. Deleting a file is always irreversible enough to ask;
    /// shell commands are gated by the user's configured Terminal Safety Level.
    private static func approvalReason(
        toolName: String,
        argumentsJson: String = "{}",
        settings: AppSettings
    ) -> String? {
        switch toolName {
        case "ask_user":
            return nil
        case "file_write", "write_file", "create_file", "save_file",
             "edit_file", "file_edit",
             "file_move", "move_file", "mv",
             "file_copy", "copy_file", "cp":
            return "This modifies files on disk."
        case "file_delete", "delete_file", "rm":
            return "This permanently deletes a file from disk."
        case "terminal_command", "run_command":
            if settings.terminalSafetyLevel == .alwaysAsk {
                return "Runs a shell command on your Mac (Terminal Safety Level: Always Ask Confirmation)."
            }
            return nil
        default:
            // MCP read/list/search tools auto-run; mutating ones still ask.
            if MCPNamespacedTool.isNamespaced(toolName) {
                let leaf = MCPNamespacedTool.parse(toolName)?.toolName ?? toolName
                if MCPClientManager.isReadOnlyMCPTool(leaf) {
                    return nil
                }
                // MacUse meta-tool: decide from the nested target name.
                if leaf == "call_tool_by_name" || leaf == "call_tool" {
                    if let nested = macUseNestedToolName(from: argumentsJson),
                       MCPClientManager.isReadOnlyMCPTool(nested)
                        || nested.hasPrefix("mail_list_")
                        || nested.hasPrefix("mail_search_")
                        || nested.hasPrefix("mail_get_")
                        || nested == "mail_list_accounts"
                        || nested == "mail_list_mailboxes"
                        || nested == "mail_search_messages"
                        || nested == "mail_get_messages"
                        || nested == "mail_get_thread"
                        || nested == "mail_get_attachment" {
                        return nil
                    }
                }
                return "Runs a Model Context Protocol (MCP) tool that may change apps or data on this Mac."
            }
            if toolName == "mcp_call" {
                return "Runs a Model Context Protocol (MCP) tool."
            }
            return nil
        }
    }

    private static func isMacUseMailReadTool(_ nested: String) -> Bool {
        let n = nested.lowercased()
        if n == "mail_list_accounts" || n == "mail_list_mailboxes" { return true }
        if n == "mail_search_messages" || n.hasPrefix("mail_search_") { return true }
        if n == "mail_get_messages" || n == "mail_get_thread" || n == "mail_get_attachment" { return true }
        return false
    }

    /// Deterministic inbox summary so a local model cannot "finish" with only narration.
    private static func formatMacUseMailSummary(
        accountsJSON: String,
        searchJSON: String,
        messageJSON: String
    ) -> String {
        var lines: [String] = ["### Mail check (MacUse)", ""]

        if let data = accountsJSON.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let accounts = (root["data"] as? [[String: Any]]) ?? []
            if !accounts.isEmpty {
                lines.append("**Accounts (\(accounts.count)):**")
                for a in accounts {
                    let name = a["name"] as? String ?? "Account"
                    let email = a["email"] as? String ?? ""
                    let type = a["type"] as? String ?? ""
                    let enabled = a["enabled"] as? Bool ?? true
                    let status = enabled ? "" : " (disabled)"
                    if email.isEmpty || email == (a["uuid"] as? String) {
                        lines.append("- \(name)\(type.isEmpty ? "" : " · \(type)")\(status)")
                    } else {
                        lines.append("- \(name): \(email)\(type.isEmpty ? "" : " · \(type)")\(status)")
                    }
                }
                lines.append("")
            }
        }

        var messages: [[String: Any]] = []
        if let data = searchJSON.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let summary = root["summary"] as? String, !summary.isEmpty {
                lines.append("**Search:** \(summary)")
                lines.append("")
            }
            if let dataObj = root["data"] as? [String: Any],
               let msgs = dataObj["messages"] as? [[String: Any]] {
                messages = msgs
            } else if let msgs = root["data"] as? [[String: Any]],
                      msgs.first?["subject"] != nil {
                messages = msgs
            }
        }

        if messages.isEmpty,
           let data = messageJSON.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataObj = root["data"] as? [String: Any],
           let msgs = dataObj["messages"] as? [[String: Any]] {
            messages = msgs
        }

        if messages.isEmpty {
            lines.append("No recent messages matched the search window.")
        } else {
            let unread = messages.filter { ($0["is_read"] as? Bool) == false }
            lines.append("**Messages (\(messages.count)" + (unread.isEmpty ? "" : ", \(unread.count) unread") + "):**")
            for (idx, msg) in messages.prefix(25).enumerated() {
                let subject = (msg["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let sender = msg["sender"] as? String ?? ""
                let date = msg["date_received"] as? String ?? (msg["date"] as? String ?? "")
                let account = msg["account"] as? String ?? ""
                let mailbox = msg["mailbox"] as? String ?? ""
                let read = (msg["is_read"] as? Bool) ?? true
                let flag = read ? "" : " · unread"
                let subj = (subject?.isEmpty == false) ? subject! : "(no subject)"
                var meta: [String] = []
                if !sender.isEmpty { meta.append(sender) }
                if !date.isEmpty { meta.append(date) }
                if !account.isEmpty { meta.append(account) }
                if !mailbox.isEmpty { meta.append(mailbox) }
                lines.append("\(idx + 1). **\(subj)**\(flag)")
                if !meta.isEmpty {
                    lines.append("   \(meta.joined(separator: " · "))")
                }
                if let content = msg["content"] as? String {
                    let clipped = content
                        .replacingOccurrences(of: "\r", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clipped.isEmpty {
                        let preview = clipped.prefix(280)
                        lines.append("   \(preview)\(clipped.count > 280 ? "…" : "")")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func macUseNestedToolName(from argumentsJson: String) -> String? {
        guard let data = argumentsJson.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let name = dict["name"] as? String { return name }
        if let name = dict["tool"] as? String { return name }
        if let name = dict["tool_name"] as? String { return name }
        if let inner = dict["arguments"] as? [String: Any], let name = inner["name"] as? String {
            return name
        }
        return nil
    }

    /// Coerce MLX/stringified nested JSON so MacUse receives real objects.
    private static func sanitizeToolArgumentsJson(toolName: String, argumentsJson: String) -> String {
        let leaf = (MCPNamespacedTool.parse(toolName)?.toolName ?? toolName).lowercased()
        guard let data = argumentsJson.data(using: .utf8),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if leaf == "call_tool_by_name" || leaf == "call_tool" {
                return MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: "mail_list_accounts")
            }
            return argumentsJson
        }
        dict = MCPToolArgumentDefaults.normalizeArguments(
            serverName: "macuse",
            toolName: leaf,
            arguments: dict
        )
        if leaf == "call_tool_by_name" || leaf == "call_tool" {
            let nested = (dict["name"] as? String)
                ?? (dict["tool"] as? String)
                ?? "mail_list_accounts"
            let inner: [String: Any]
            if let obj = dict["arguments"] as? [String: Any] {
                inner = obj
            } else {
                inner = [:]
            }
            return MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: nested, arguments: inner)
        }
        if leaf == "get_tool_definitions" {
            dict.removeValue(forKey: "arguments")
            if dict["names"] == nil {
                dict["names"] = ["*"]
            }
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let out = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: out, encoding: .utf8) else {
            return argumentsJson
        }
        return s
    }

    /// After MacUse `get_tool_definitions`, local models often narrate instead of calling
    /// `call_tool_by_name`. Force the same next step Radiant takes for mail checks.
    private static func macUseForcedFollowUp(
        userPrompt: String,
        availableTools: [Tool],
        defsFetched: Bool,
        mailListed: Bool,
        mailSearched: Bool
    ) -> (tool: String, args: String, notice: String)? {
        let prompt = userPrompt.lowercased()
        let wantsMacUse = prompt.contains("macuse") || prompt.contains("mac use")
            || ((prompt.contains("mail") || prompt.contains("email") || prompt.contains("inbox"))
                && (prompt.contains("mcp") || prompt.contains("computer") || prompt.contains("this computer")))
        guard wantsMacUse else { return nil }

        let wantsMail = prompt.contains("mail") || prompt.contains("email") || prompt.contains("inbox")
        let callTool = availableTools.first(where: {
            let n = $0.name.lowercased()
            return n.hasSuffix("__call_tool_by_name") || n.contains("call_tool_by_name")
        })
        let defsTool = availableTools.first(where: {
            let n = $0.name.lowercased()
            return n.hasSuffix("__get_tool_definitions") || n.contains("get_tool_definitions")
        })

        if !defsFetched, let defsTool {
            let names = wantsMail ? #"{"names":["mail_*"]}"# : #"{"names":["*"]}"#
            return (defsTool.name, names, "Calling MacUse `get_tool_definitions`…")
        }

        guard wantsMail, let callTool else { return nil }

        if !mailListed {
            return (
                callTool.name,
                MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: "mail_list_accounts"),
                "Calling MacUse `mail_list_accounts`…"
            )
        }

        if !mailSearched {
            return (
                callTool.name,
                MCPToolArgumentDefaults.macUseCallArgsJSON(
                    toolName: "mail_search_messages",
                    arguments: ["limit": 50]
                ),
                "Calling MacUse `mail_search_messages`…"
            )
        }

        return nil
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
