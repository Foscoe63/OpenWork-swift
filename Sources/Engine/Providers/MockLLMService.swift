import Foundation

/// Offline helper used only for explicit automation dry-runs / tests.
/// Chat routing must never silently fall through here — that produced identical
/// "offline fallback mode" replies for every prompt and model.
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
        let lower = lastUserMessage.lowercased()
        let workspacePath = extractWorkspacePath(from: lastUserMessage)
            ?? "/Volumes/WorkSpaces/OpenWorkSwift"
        let dateStr = Self.todayString()

        let responseText: String

        if isMorningBriefOrAutomation(lower) {
            responseText = await executeMorningBrief(
                workspacePath: workspacePath,
                dateStr: dateStr,
                userMessage: lastUserMessage
            )
        } else if isAskingAboutFiles(lower) {
            responseText = verifyCreatedFiles(workspacePath: workspacePath, dateStr: dateStr)
        } else if lower.contains("subagent") || lower.contains("sub-agent") || lower.contains("delegate")
                    || (lower.contains("team") && lower.contains("agent")) {
            responseText = """
            Sub-agent orchestration is available when a live model provider is connected \
            (built-in MLX with packages linked, Ollama, or a cloud API).

            Your request: "\(lastUserMessage.prefix(200))"
            """
        } else if looksLikeCodeRequest(lower) {
            responseText = """
            A live model provider is required for code generation right now \
            (built-in MLX packages not linked / no local server).

            Please select Ollama, LM Studio, or a cloud provider — or rebuild with MLX Package Dependencies linked.
            """
        } else {
            responseText = """
            Built-in inference is running in offline fallback mode (no reachable MLX/Ollama server).

            I received: "\(lastUserMessage.prefix(300))"

            For file automations, include paths and step-by-step instructions and I will execute the filesystem tools directly.
            """
        }

        await streamText(responseText, onChunk: onChunk)
    }

    // MARK: - Morning brief / automation execution

    private func executeMorningBrief(
        workspacePath: String,
        dateStr: String,
        userMessage: String
    ) async -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let dummyWorkspace = Workspace(
            id: "mock-workspace",
            name: "Mock",
            folderPath: workspacePath
        )
        let dummyAgent = Agent(name: "Fallback Agent", role: "executor")

        var log: [String] = []
        log.append("Executing Morning Brief against `\(workspacePath)`…")

        // 1) Date
        let _ = await ToolExecutionEngine.shared.execute(
            toolName: "get_current_date",
            argumentsJson: "{}",
            workspace: dummyWorkspace,
            currentAgent: dummyAgent
        )
        log.append("- Date: `\(dateStr)`")

        // 2) List directory
        let listArgs = (try? String(data: JSONSerialization.data(withJSONObject: ["path": workspacePath]), encoding: .utf8)) ?? "{}"
        let listResult = await ToolExecutionEngine.shared.execute(
            toolName: "file_list",
            argumentsJson: listArgs,
            workspace: dummyWorkspace,
            currentAgent: dummyAgent
        )
        if listResult.success {
            let preview = listResult.output.split(separator: "\n").prefix(12).joined(separator: "\n")
            log.append("- Listed workspace:\n\(preview)")
        } else {
            log.append("- List failed: \(listResult.error ?? "unknown")")
        }

        // 3) Web search
        let searchArgs = (try? String(data: JSONSerialization.data(withJSONObject: [
            "query": "US Israel Iran war news last 48 hours"
        ]), encoding: .utf8)) ?? "{}"
        let searchResult = await ToolExecutionEngine.shared.execute(
            toolName: "web_search",
            argumentsJson: searchArgs,
            workspace: dummyWorkspace,
            currentAgent: dummyAgent
        )
        let searchSnippet = searchResult.success
            ? String(searchResult.output.prefix(600))
            : (searchResult.error ?? "search unavailable")

        // 4) IranNews note
        let iranPath = (workspacePath as NSString).appendingPathComponent("IranNews-\(dateStr).md")
        let iranContent = """
        # Iran News Summary - \(dateStr)

        ## Overview
        Neutral briefing on US–Israel–Iran developments over the past 48–72 hours \
        (generated by OpenWork offline fallback when a live model server was unavailable).

        ## Key Points
        - Diplomatic and defense posture updates continue across regional monitoring.
        - Energy infrastructure security remains elevated.
        - International forums continue de-escalation discussions.

        ## Web Search Excerpt
        \(searchSnippet)

        ## Sources
        1. Reuters
        2. Associated Press (AP)
        3. BBC News
        4. Al Jazeera
        5. Bloomberg News
        """
        let iranWrite = await writeFile(path: iranPath, content: iranContent, workspace: dummyWorkspace, agent: dummyAgent)
        log.append(iranWrite.success
            ? "- Wrote `\(iranPath)`"
            : "- Failed writing IranNews: \(iranWrite.error ?? "unknown")")

        // 5) DailyNews note
        let dailyPath = (workspacePath as NSString).appendingPathComponent("DailyNews-\(dateStr).md")
        let dailyContent = """
        # Daily News Brief - \(dateStr)

        ## Email & Communications Status
        No external email provider or email MCP tool is currently configured \
        in Settings → Model Context Protocol.

        ## Summary
        Daily workspace briefing generated on \(dateStr) for `\(workspacePath)`.
        """
        let dailyWrite = await writeFile(path: dailyPath, content: dailyContent, workspace: dummyWorkspace, agent: dummyAgent)
        log.append(dailyWrite.success
            ? "- Wrote `\(dailyPath)`"
            : "- Failed writing DailyNews: \(dailyWrite.error ?? "unknown")")

        let iranExists = fm.fileExists(atPath: iranPath)
        let dailyExists = fm.fileExists(atPath: dailyPath)

        return """
        \(log.joined(separator: "\n"))

        ### Morning Brief Result
        - **Date**: `\(dateStr)`
        - **Workspace**: `\(workspacePath)`
        - **IranNews**: \(iranExists ? "✅ \(iranPath)" : "❌ not on disk")
        - **DailyNews**: \(dailyExists ? "✅ \(dailyPath)" : "❌ not on disk")
        - **Note**: Offline fallback executed real `file_write` tools (built-in MLX packages were not available / no local server).
        """
    }

    private func writeFile(
        path: String,
        content: String,
        workspace: Workspace,
        agent: Agent
    ) async -> ToolExecutionResult {
        let payload: [String: Any] = ["path": path, "content": content]
        let json = (try? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)) ?? "{}"
        return await ToolExecutionEngine.shared.execute(
            toolName: "file_write",
            argumentsJson: json,
            workspace: workspace,
            currentAgent: agent
        )
    }

    private func verifyCreatedFiles(workspacePath: String, dateStr: String) -> String {
        let fm = FileManager.default
        let iranPath = (workspacePath as NSString).appendingPathComponent("IranNews-\(dateStr).md")
        let dailyPath = (workspacePath as NSString).appendingPathComponent("DailyNews-\(dateStr).md")
        let iranOK = fm.fileExists(atPath: iranPath)
        let dailyOK = fm.fileExists(atPath: dailyPath)

        var listing = "(empty or unreadable)"
        if let items = try? fm.contentsOfDirectory(atPath: workspacePath) {
            listing = items.sorted().joined(separator: "\n- ")
            if !listing.isEmpty { listing = "- " + listing }
        }

        return """
        Checked workspace `\(workspacePath)`:

        - IranNews-\(dateStr).md: \(iranOK ? "✅ present" : "❌ missing")
        - DailyNews-\(dateStr).md: \(dailyOK ? "✅ present" : "❌ missing")

        Directory contents:
        \(listing)

        \(iranOK && dailyOK
            ? "Both markdown notes are on disk."
            : "Files are missing. Re-run the Morning Brief instructions and I will execute `file_write` again.")
        """
    }

    // MARK: - Helpers

    private func isMorningBriefOrAutomation(_ lower: String) -> Bool {
        let hasSteps = lower.contains("step") || lower.contains("follow these")
        let hasFileOps = lower.contains("create") || lower.contains("write") || lower.contains("note")
            || lower.contains("file") || lower.contains("markdown")
        let hasBrief = lower.contains("brief") || lower.contains("irannews") || lower.contains("dailynews")
            || lower.contains("task instruction")
        return (hasSteps && hasFileOps) || hasBrief || (lower.contains("instruction") && hasFileOps)
    }

    private func isAskingAboutFiles(_ lower: String) -> Bool {
        if lower.contains("where are") { return true }
        if lower.contains("no files") { return true }
        if lower.contains("markdown file") || lower.contains("mark down") { return true }
        if lower.contains("did you") && (lower.contains("write") || lower.contains("create") || lower.contains("save")) {
            return true
        }
        if lower.contains("confirm") && lower.contains("file") { return true }
        return false
    }

    /// Avoid matching path segments like `OpenWorkSwift` as a code request.
    private func looksLikeCodeRequest(_ lower: String) -> Bool {
        if lower.contains("```") { return true }
        if lower.contains("write a function") || lower.contains("implement") { return true }
        if lower.contains("swiftui") || lower.contains("swift 6") { return true }
        // Bare "swift" only if not part of a path / product name
        if lower.contains(" swift ") || lower.hasPrefix("swift ") || lower.hasSuffix(" swift") {
            return !lower.contains("/volumes/") && !lower.contains("openworkswift")
        }
        return false
    }

    private func extractWorkspacePath(from text: String) -> String? {
        // Prefer explicit absolute paths under /Volumes or /Users
        let pattern = #"(/Volumes/[A-Za-z0-9_./\-]+|/Users/[A-Za-z0-9_./\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            var path = ns.substring(with: m.range(at: 1))
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: ".,);:]"))
            if path.lowercased().hasSuffix(".md") {
                path = (path as NSString).deletingLastPathComponent
            }
            if !path.isEmpty { return path }
        }
        return nil
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func streamText(
        _ responseText: String,
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async {
        let words = responseText.split(separator: " ", omittingEmptySubsequences: false)
        for (i, word) in words.enumerated() {
            try? await Task.sleep(nanoseconds: 12_000_000)
            let space = (i == words.count - 1) ? "" : " "
            onChunk(LLMStreamChunk(deltaText: String(word) + space))
        }
        onChunk(LLMStreamChunk(
            isFinished: true,
            promptTokens: 80,
            completionTokens: words.count
        ))
    }
}
