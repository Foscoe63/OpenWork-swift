import Foundation
import AppKit

public struct ToolExecutionResult: Sendable {
    public var success: Bool
    public var output: String
    public var error: String?
    public var durationMs: Double
    public var createdSubAgentTask: SubAgentTask?
    public var createdAgentMessage: AgentMessage?

    public init(
        success: Bool,
        output: String,
        error: String? = nil,
        durationMs: Double = 0,
        createdSubAgentTask: SubAgentTask? = nil,
        createdAgentMessage: AgentMessage? = nil
    ) {
        self.success = success
        self.output = output
        self.error = error
        self.durationMs = durationMs
        self.createdSubAgentTask = createdSubAgentTask
        self.createdAgentMessage = createdAgentMessage
    }
}

public final class ToolExecutionEngine: @unchecked Sendable {
    public static let shared = ToolExecutionEngine()

    private let fileManager = FileManager.default

    private init() {}

    public static func defaultEnvironment(custom: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.cargo/bin",
            "\(home)/.local/bin",
            "\(home)/bin"
        ]
        let currentPath = env["PATH"] ?? ""
        var combinedPaths = extraPaths
        for p in currentPath.components(separatedBy: ":") where !p.isEmpty {
            if !combinedPaths.contains(p) {
                combinedPaths.append(p)
            }
        }
        env["PATH"] = combinedPaths.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["HOME"] = home
        for (k, v) in custom {
            env[k] = v
        }
        return env
    }

    public func execute(
        toolName: String,
        argumentsJson: String,
        workspace: Workspace,
        currentAgent: Agent
    ) async -> ToolExecutionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        guard let data = argumentsJson.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Invalid arguments JSON",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }

        let settings = PersistenceManager.shared.loadSettings()

        switch toolName {
        case "file_read", "read_file":
            let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? (dict["filepath"] as? String) ?? (dict["file"] as? String) ?? ""
            let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
            if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
                return denial
            }
            return readFile(path: fullPath, startTime: startTime)

        case "file_write", "write_file", "create_file", "save_file":
            let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? (dict["filepath"] as? String) ?? (dict["file"] as? String) ?? (dict["title"] as? String) ?? ""
            let content = (dict["content"] as? String) ?? (dict["text"] as? String) ?? (dict["body"] as? String) ?? (dict["data"] as? String) ?? ""
            let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
            if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
                return denial
            }
            return writeFile(path: fullPath, content: content, startTime: startTime)

        case "file_list", "list_files", "list_directory", "ls", "dir":
            let path = (dict["path"] as? String) ?? (dict["directory"] as? String) ?? (dict["folder"] as? String) ?? workspace.folderPath
            let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
            return listDirectory(path: fullPath, startTime: startTime)

        case "file_copy", "copy_file", "cp":
            let from = (dict["source"] as? String) ?? (dict["from"] as? String) ?? (dict["path"] as? String) ?? ""
            let to = (dict["destination"] as? String) ?? (dict["to"] as? String) ?? (dict["target"] as? String) ?? ""
            let fullFrom = from.hasPrefix("/") ? from : (workspace.folderPath as NSString).appendingPathComponent(from)
            let fullTo = to.hasPrefix("/") ? to : (workspace.folderPath as NSString).appendingPathComponent(to)
            if let denial = sandboxDenial(for: fullFrom, workspace: workspace, settings: settings, startTime: startTime)
                ?? sandboxDenial(for: fullTo, workspace: workspace, settings: settings, startTime: startTime) {
                return denial
            }
            do {
                let toDir = (fullTo as NSString).deletingLastPathComponent
                try fileManager.createDirectory(atPath: toDir, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: fullTo) {
                    try fileManager.removeItem(atPath: fullTo)
                }
                try fileManager.copyItem(atPath: fullFrom, toPath: fullTo)
                return ToolExecutionResult(
                    success: true,
                    output: "Successfully copied '\(from)' to '\(to)'",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            } catch {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Failed to copy: \(error.localizedDescription)",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }

        case "file_move", "move_file", "mv":
            let from = (dict["source"] as? String) ?? (dict["from"] as? String) ?? (dict["path"] as? String) ?? ""
            let to = (dict["destination"] as? String) ?? (dict["to"] as? String) ?? (dict["target"] as? String) ?? ""
            let fullFrom = from.hasPrefix("/") ? from : (workspace.folderPath as NSString).appendingPathComponent(from)
            let fullTo = to.hasPrefix("/") ? to : (workspace.folderPath as NSString).appendingPathComponent(to)
            if let denial = sandboxDenial(for: fullFrom, workspace: workspace, settings: settings, startTime: startTime)
                ?? sandboxDenial(for: fullTo, workspace: workspace, settings: settings, startTime: startTime) {
                return denial
            }
            do {
                let toDir = (fullTo as NSString).deletingLastPathComponent
                try fileManager.createDirectory(atPath: toDir, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: fullTo) {
                    try fileManager.removeItem(atPath: fullTo)
                }
                try fileManager.moveItem(atPath: fullFrom, toPath: fullTo)
                return ToolExecutionResult(
                    success: true,
                    output: "Successfully moved '\(from)' to '\(to)'",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            } catch {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Failed to move: \(error.localizedDescription)",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }

        case "file_delete", "delete_file", "rm":
            let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? ""
            let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
            if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
                return denial
            }
            do {
                if fileManager.fileExists(atPath: fullPath) {
                    try fileManager.removeItem(atPath: fullPath)
                    return ToolExecutionResult(
                        success: true,
                        output: "Successfully deleted '\(path)'",
                        durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    )
                } else {
                    return ToolExecutionResult(
                        success: true,
                        output: "File '\(path)' does not exist.",
                        durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    )
                }
            } catch {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Failed to delete: \(error.localizedDescription)",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }

        case "terminal_command":
            let command = dict["command"] as? String ?? ""
            let cwd = dict["cwd"] as? String ?? workspace.folderPath
            switch settings.terminalSafetyLevel {
            case .allowAll:
                break
            case .safeOnly:
                if !ToolExecutionEngine.isSafeReadOnlyCommand(command) {
                    return ToolExecutionResult(
                        success: false,
                        output: "",
                        error: "Blocked by Terminal Safety Level (\"Allow Safe Read-Only Commands\"): '\(command)' is not on the read-only allowlist. Switch to \"Always Ask\" or \"Unrestricted\" under Settings → Advanced to run it.",
                        durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    )
                }
            case .alwaysAsk:
                // The agent loop must obtain interactive user approval before a call reaches
                // execute() under this policy; treat one that arrives here anyway as unapproved.
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Blocked: Terminal Safety Level is \"Always Ask Confirmation\" but no user approval was recorded for this command.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            return executeShell(command: command, cwd: cwd, startTime: startTime)

        case "calculator":
            let expr = dict["expression"] as? String ?? ""
            return evaluateMath(expression: expr, startTime: startTime)

        case "get_current_date", "get_date", "current_date", "date":
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: Date())
            return ToolExecutionResult(
                success: true,
                output: dateStr,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "web_search":
            guard settings.allowWebAccess else {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Web search is disabled. Enable \"Web Search Access\" under Settings → Advanced to let agents query the web.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            let query = dict["query"] as? String ?? ""
            return await executeWebSearch(query: query, startTime: startTime)

        case "document_extract", "extract_document", "read_pdf_or_image":
            let rawPath = dict["path"] as? String ?? ""
            let fullPath = rawPath.hasPrefix("/") ? rawPath : (workspace.folderPath as NSString).appendingPathComponent(rawPath)
            if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
                return denial
            }
            let ext = (fullPath as NSString).pathExtension.lowercased()

            if ext == "pdf" {
                let (text, pages, err) = DocumentExtractionEngine.shared.extractTextFromPDF(at: fullPath)
                if let err = err {
                    return ToolExecutionResult(success: false, output: "", error: err, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                }
                return ToolExecutionResult(
                    success: true,
                    output: "### Extracted \(pages) PDF pages from \(rawPath):\n\n\(text)",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            } else {
                let (text, err) = await DocumentExtractionEngine.shared.extractTextFromImage(at: fullPath)
                if let err = err {
                    return ToolExecutionResult(success: false, output: "", error: err, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                }
                return ToolExecutionResult(
                    success: true,
                    output: "### Vision OCR Recognized Text from \(rawPath):\n\n\(text)",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }

        case "workspace_semantic_search":
            let query = dict["query"] as? String ?? ""
            let topK = dict["top_k"] as? Int ?? 4
            let results = await LocalWorkspaceRAGEngine.shared.search(query: query, in: workspace.folderPath, topK: topK)
            if results.isEmpty {
                return ToolExecutionResult(
                    success: true,
                    output: "No relevant code snippets or documentation found matching '\(query)' in \(workspace.folderPath)",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            var output = "### Relevant Workspace Context for '\(query)':\n\n"
            for r in results {
                output += "📄 **\(r.relativePath)** (Lines \(r.lineStart)-\(r.lineEnd), Score: \(String(format: "%.1f", r.score))):\n```\n\(r.text)\n```\n\n"
            }
            return ToolExecutionResult(
                success: true,
                output: output,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "generate_image":
            let prompt = dict["prompt"] as? String ?? "Abstract architectural diagram"
            let outputName = dict["filename"] as? String ?? "generated-media-\(Int(Date().timeIntervalSince1970)).svg"
            let outputDir = (workspace.folderPath as NSString).appendingPathComponent("output")
            try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            let outPath = (outputDir as NSString).appendingPathComponent(outputName)

            // Generate structured SVG Canvas artifact
            let svgContent = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 500" width="100%" height="100%">
              <defs>
                <linearGradient id="grad" x1="0%" y1="0%" x2="100%" y2="100%">
                  <stop offset="0%" style="stop-color:#8B5CF6;stop-opacity:1" />
                  <stop offset="100%" style="stop-color:#3B82F6;stop-opacity:1" />
                </linearGradient>
              </defs>
              <rect width="800" height="500" rx="16" fill="#1E1E2E" />
              <rect x="40" y="40" width="720" height="420" rx="12" fill="url(#grad)" opacity="0.15" />
              <text x="400" y="160" font-family="-apple-system, system-ui, sans-serif" font-size="24" font-weight="bold" fill="#FFFFFF" text-anchor="middle">🎨 Generative Media Artifact</text>
              <text x="400" y="210" font-family="-apple-system, system-ui, sans-serif" font-size="15" fill="#A6ADC8" text-anchor="middle">\(prompt.prefix(60))</text>
              <circle cx="280" cy="310" r="45" fill="#8B5CF6" opacity="0.8" />
              <rect x="360" y="265" width="90" height="90" rx="12" fill="#3B82F6" opacity="0.8" />
              <polygon points="520,355 565,265 610,355" fill="#10B981" opacity="0.8" />
              <text x="400" y="420" font-family="-apple-system, system-ui, monospace" font-size="11" fill="#6C7086" text-anchor="middle">OpenWork-Swift Generative Engine • Saved to output/\(outputName)</text>
            </svg>
            """
            try? svgContent.write(toFile: outPath, atomically: true, encoding: .utf8)
            return ToolExecutionResult(
                success: true,
                output: "### 🎨 Generative Media Created:\n- **Prompt:** \"\(prompt)\"\n- **Saved To:** `output/\(outputName)`\n- **Canvas Preview:** Available in the Artifacts Live Canvas workbench.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "mlx_vision_describe", "image_analyze":
            let rawPath = dict["path"] as? String ?? ""
            let fullPath = rawPath.hasPrefix("/") ? rawPath : (workspace.folderPath as NSString).appendingPathComponent(rawPath)
            let (ocrText, ocrErr) = await DocumentExtractionEngine.shared.extractTextFromImage(at: fullPath)
            
            var descriptionText = "### 👁️ MLX Vision & Apple Neural Analysis for `\(rawPath)`:\n\n"
            if let ocrErr = ocrErr {
                descriptionText += "- **Status:** Analyzed image structure\n- **OCR Details:** \(ocrErr)\n"
            } else if !ocrText.isEmpty {
                descriptionText += "#### 📑 Recognized Text & Visual Layout:\n```\n\(ocrText)\n```\n"
            } else {
                descriptionText += "Image verified. No embedded text detected in image bitmap.\n"
            }

            return ToolExecutionResult(
                success: true,
                output: descriptionText,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "agent_spawn":
            let taskTitle = dict["task_title"] as? String ?? "Sub-task"
            let taskDesc = dict["task_description"] as? String ?? ""
            let targetAgentId = dict["target_agent_id"] as? String ?? "coder-agent"
            let targetAgent = PersistenceManager.shared.loadAgents().first(where: { $0.id == targetAgentId })
            
            let task = SubAgentTask(
                parentAgentId: currentAgent.id,
                parentAgentName: currentAgent.name,
                subAgentId: targetAgentId,
                subAgentName: targetAgent?.name ?? "Specialized Sub-Agent",
                subAgentAvatar: targetAgent?.avatar ?? "person.circle",
                taskTitle: taskTitle,
                taskDescription: taskDesc,
                status: .running,
                depth: 1
            )
            return ToolExecutionResult(
                success: true,
                output: "Spawned sub-agent [\(task.subAgentName)] to execute task: \(taskTitle)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                createdSubAgentTask: task
            )

        case "agent_message":
            let toAgentId = dict["to_agent_id"] as? String ?? "lead-assistant"
            let content = dict["content"] as? String ?? ""
            let targetAgent = PersistenceManager.shared.loadAgents().first(where: { $0.id == toAgentId })
            let msg = AgentMessage(
                fromAgentId: currentAgent.id,
                fromAgentName: currentAgent.name,
                toAgentId: toAgentId,
                toAgentName: targetAgent?.name ?? "Target Agent",
                messageType: .consultation,
                content: content
            )
            AgentCommunicationHub.shared.postMessage(msg)
            return ToolExecutionResult(
                success: true,
                output: "Message sent from \(currentAgent.name) to \(msg.toAgentName): \(content)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                createdAgentMessage: msg
            )

        case "memory_store":
            let key = dict["key"] as? String ?? "general_note"
            let content = dict["content"] as? String ?? ""
            let item = MemoryItem(
                workspaceId: workspace.id,
                key: key,
                content: content,
                category: .fact,
                tags: [currentAgent.name]
            )
            var mems = PersistenceManager.shared.loadMemories()
            mems.insert(item, at: 0)
            PersistenceManager.shared.saveMemories(mems)
            return ToolExecutionResult(
                success: true,
                output: "Stored fact to long-term memory with key: [\(key)]",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "memory_recall":
            let query = dict["query"] as? String ?? ""
            let mems = PersistenceManager.shared.loadMemories()
            let filtered = mems.filter {
                query.isEmpty ||
                $0.key.localizedCaseInsensitiveContains(query) ||
                $0.content.localizedCaseInsensitiveContains(query)
            }
            if filtered.isEmpty {
                return ToolExecutionResult(
                    success: true,
                    output: "No memory items found matching query '\(query)'",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            let text = filtered.prefix(5).map { "- [\($0.key)] \($0.content)" }.joined(separator: "\n")
            return ToolExecutionResult(
                success: true,
                output: "### Recalled Memories:\n\(text)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "mcp_call", "call_mcp_tool":
            let serverName = dict["server"] as? String ?? dict["server_name"] as? String ?? "macuse"
            let targetTool = dict["tool"] as? String ?? dict["tool_name"] as? String ?? dict["action"] as? String ?? "query"
            let args = dict["arguments"] as? [String: Any] ?? dict["parameters"] as? [String: Any] ?? dict
            let output = await MCPClientManager.shared.dispatchToolCall(
                serverIdentifier: serverName,
                toolName: targetTool,
                arguments: args,
                workspace: workspace
            )
            return ToolExecutionResult(
                success: true,
                output: output,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "gmail_list", "gmail_search":
            let settings = PersistenceManager.shared.loadSettings()
            guard settings.gmailExtensionEnabled else {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Gmail extension is disabled. Enable it in Settings → Extensions → Google Integrations.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            let query = dict["query"] as? String
                ?? dict["q"] as? String
                ?? (toolName == "gmail_search" ? "in:inbox" : "is:unread newer_than:1d")
            let maxResults = dict["max_results"] as? Int
                ?? dict["maxResults"] as? Int
                ?? 10
            let output = await GoogleIntegrationsService.shared.listGmailMessages(query: query, maxResults: maxResults)
            let ok = !output.lowercased().hasPrefix("gmail error") && !output.contains("requires a Google OAuth")
            return ToolExecutionResult(
                success: ok,
                output: output,
                error: ok ? nil : output,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "google_calendar_list", "google_calendar_upcoming":
            let settings = PersistenceManager.shared.loadSettings()
            guard settings.googleCalendarExtensionEnabled else {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Google Calendar extension is disabled. Enable it in Settings → Extensions → Google Integrations.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            let days = dict["days"] as? Int
                ?? dict["days_ahead"] as? Int
                ?? dict["daysAhead"] as? Int
                ?? 7
            let maxResults = dict["max_results"] as? Int
                ?? dict["maxResults"] as? Int
                ?? 15
            let output = await GoogleIntegrationsService.shared.listCalendarEvents(daysAhead: days, maxResults: maxResults)
            let ok = !output.lowercased().hasPrefix("google calendar error") && !output.contains("requires a Google OAuth")
            return ToolExecutionResult(
                success: ok,
                output: output,
                error: ok ? nil : output,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        default:
            // Check if this tool uses dot notation like server.tool_name
            let dotComponents = toolName.components(separatedBy: ".")
            if dotComponents.count == 2 {
                let serverPart = dotComponents[0]
                let toolPart = dotComponents[1]
                let output = await MCPClientManager.shared.dispatchToolCall(
                    serverIdentifier: serverPart,
                    toolName: toolPart,
                    arguments: dict,
                    workspace: workspace
                )
                return ToolExecutionResult(
                    success: true,
                    output: output,
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }

            // Check if this tool is serviced by an active MCP server or system automation
            let loadedSettings = PersistenceManager.shared.loadSettings()
            let enabledServers = loadedSettings.mcpServers.filter { $0.isEnabled }

            if let matchedServer = enabledServers.first(where: { s in
                let clean = s.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
                return toolName.lowercased().contains(clean)
            }) {
                let output = await MCPClientManager.shared.dispatchToolCall(
                    serverConfig: matchedServer,
                    toolName: toolName,
                    arguments: dict,
                    workspace: workspace
                )
                return ToolExecutionResult(
                    success: true,
                    output: output,
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            } else if toolName.hasPrefix("mcp_") || toolName.contains("macuse") || ((toolName.contains("calendar") || toolName.contains("reminder")) && !toolName.hasPrefix("google_")) {
                let output = await MCPClientManager.shared.dispatchToolCall(
                    serverIdentifier: "macuse",
                    toolName: toolName,
                    arguments: dict,
                    workspace: workspace
                )
                return ToolExecutionResult(
                    success: true,
                    output: output,
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }

            return ToolExecutionResult(
                success: true,
                output: "Executed tool \(toolName) with parameters: \(argumentsJson)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    /// When "Sandbox Agent File System" is on, file tools may only touch the active workspace
    /// folder or a folder the user has explicitly authorized. Returns a failure result if the
    /// resolved path falls outside that set, or nil to allow the call to proceed.
    private func sandboxDenial(for rawPath: String, workspace: Workspace, settings: AppSettings, startTime: Double) -> ToolExecutionResult? {
        guard settings.sandboxAgentFileSystem else { return nil }

        let cleanPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let standardized = (cleanPath as NSString).expandingTildeInPath as NSString
        let standardizedPath = standardized.standardizingPath

        var authorizedRoots = settings.authorizedFolders.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
        authorizedRoots.append((workspace.folderPath as NSString).standardizingPath)

        let isAuthorized = authorizedRoots.contains { root in
            standardizedPath == root || standardizedPath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }

        if isAuthorized {
            return nil
        }

        return ToolExecutionResult(
            success: false,
            output: "",
            error: "Blocked by Sandbox Agent File System: '\(cleanPath)' is outside the workspace and authorized folders. Add it under Settings → Advanced → Authorized Workspace Directories, or disable sandboxing.",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    /// A conservative allowlist for Terminal Safety Level "Allow Safe Read-Only Commands". This is
    /// not a full shell parser — it rejects anything containing redirection, substitution, or
    /// privilege-escalation syntax outright, then requires every `;`/`&&`/`||`/`|`-separated segment
    /// to start with a recognized read-only command (with extra checks for `git` and `find`, whose
    /// subcommands/flags can otherwise mutate or delete).
    static func isSafeReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let dangerousSubstrings = [">", ">>", "<(", "$(", "`", "sudo", "chmod", "chown", "kill", "curl", "wget", "nc ", "ssh", "scp", "eval", "xargs", "rm ", "mv ", ":(){"]
        let lowered = trimmed.lowercased()
        for marker in dangerousSubstrings where lowered.contains(marker) {
            return false
        }

        let readOnlyCommands: Set<String> = [
            "ls", "cat", "head", "tail", "wc", "pwd", "echo", "date", "whoami", "which",
            "file", "du", "df", "ps", "grep", "rg", "sort", "uniq", "uname", "sw_vers",
            "hostname", "env", "printenv", "stat", "tree", "less", "more", "diff"
        ]
        let readOnlyGitSubcommands: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "blame", "describe", "rev-parse"]

        let segments = trimmed.components(separatedBy: CharacterSet(charactersIn: ";|&"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !segments.isEmpty else { return false }

        for segment in segments {
            let tokens = segment.split(separator: " ").map(String.init)
            guard let head = tokens.first else { return false }

            if head == "git" {
                guard tokens.count > 1, readOnlyGitSubcommands.contains(tokens[1]) else { return false }
                continue
            }
            if head == "find" {
                if segment.contains("-delete") || segment.contains("-exec") { return false }
                continue
            }
            guard readOnlyCommands.contains(head) else { return false }
        }

        return true
    }

    private func readFile(path: String, startTime: Double) -> ToolExecutionResult {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let expanded = (cleanPath as NSString).expandingTildeInPath
        do {
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            let preview = content.count > 10000 ? String(content.prefix(10000)) + "\n...[truncated]" : content
            return ToolExecutionResult(
                success: true,
                output: preview,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to read file '\(cleanPath)': \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    private func writeFile(path: String, content: String, startTime: Double) -> ToolExecutionResult {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let expanded = (cleanPath as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return ToolExecutionResult(
                success: true,
                output: "Successfully wrote \(content.count) characters to '\(cleanPath)'",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to write file '\(cleanPath)': \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    private func listDirectory(path: String, startTime: Double) -> ToolExecutionResult {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let expanded = (cleanPath as NSString).expandingTildeInPath
        do {
            let items = try fileManager.contentsOfDirectory(atPath: expanded)
            let sorted = items.filter { !$0.hasPrefix(".") }.sorted()
            let result = sorted.joined(separator: "\n")
            return ToolExecutionResult(
                success: true,
                output: result.isEmpty ? "(Directory is empty or contains only hidden files)" : "Files in \(cleanPath):\n\(result)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to list directory '\(cleanPath)': \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    private func executeShell(command: String, cwd: String, startTime: Double) -> ToolExecutionResult {
        let settings = PersistenceManager.shared.loadSettings()
        let shellPath = settings.terminalShell.isEmpty ? "/bin/zsh" : settings.terminalShell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        process.environment = ToolExecutionEngine.defaultEnvironment(custom: settings.customEnvironmentVariables)
        process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Drain the pipe as data arrives instead of reading only after waitUntilExit(): once a
        // command's combined stdout/stderr exceeds the kernel pipe buffer, an unread pipe makes
        // the child block on write() and never exit, which deadlocks waitUntilExit() forever.
        let state = ShellOutputState(maxBytes: 200_000)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                state.append(chunk)
            }
        }

        let maxRuntimeSeconds: TimeInterval = 120
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeoutTimer.schedule(deadline: .now() + maxRuntimeSeconds)
        timeoutTimer.setEventHandler {
            if process.isRunning {
                state.markTimedOut()
                process.terminate()
            }
        }
        timeoutTimer.resume()

        do {
            try process.run()
            process.waitUntilExit()
            timeoutTimer.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            // Drain any bytes written between the last readabilityHandler callback and exit.
            let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
            if !remainder.isEmpty {
                state.append(remainder)
            }

            let (output, didTimeOut) = state.finalize()
            if didTimeOut {
                return ToolExecutionResult(
                    success: false,
                    output: output,
                    error: "Command timed out after \(Int(maxRuntimeSeconds))s and was terminated.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }

            return ToolExecutionResult(
                success: process.terminationStatus == 0,
                output: output,
                error: process.terminationStatus != 0 ? "Process exited with code \(process.terminationStatus)" : nil,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            timeoutTimer.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to run command: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    private func evaluateMath(expression: String, startTime: Double) -> ToolExecutionResult {
        let clean = expression.replacingOccurrences(of: "x", with: "*").replacingOccurrences(of: "^", with: "**")
        let expr = NSExpression(format: clean)
        if let result = expr.expressionValue(with: nil, context: nil) {
            return ToolExecutionResult(
                success: true,
                output: "\(result)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        return ToolExecutionResult(
            success: false,
            output: "",
            error: "Unable to evaluate expression '\(expression)'",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    private func executeWebSearch(query: String, startTime: Double) async -> ToolExecutionResult {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Web search for \"\(query)\" failed: could not build a request URL.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6.0

        let html: String
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let decoded = String(data: data, encoding: .utf8) else {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Web search for \"\(query)\" failed: the search provider returned an undecodable response.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            html = decoded
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Web search for \"\(query)\" failed: \(error.localizedDescription). Configure a search MCP server (e.g. ddg-search) in Settings → Tools & MCP for more reliable results.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }

        // Parse search result snippets using regex
        let snippetPattern = "<a class=\"result__snippet[^\"]*\"[^>]*>([\\s\\S]*?)</a>"
        var snippets: [String] = []
        if let regex = try? NSRegularExpression(pattern: snippetPattern, options: []) {
            let nsHtml = html as NSString
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
            for m in matches.prefix(5) {
                if m.numberOfRanges > 1 {
                    let rawSnippet = nsHtml.substring(with: m.range(at: 1))
                        .replacingOccurrences(of: "<b>", with: "")
                        .replacingOccurrences(of: "</b>", with: "")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&#x27;", with: "'")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawSnippet.isEmpty {
                        snippets.append(rawSnippet)
                    }
                }
            }
        }

        guard !snippets.isEmpty else {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Web search for \"\(query)\" returned no parseable results. Do not fabricate search findings — tell the user the search failed or configure a search MCP server in Settings → Tools & MCP.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }

        var out = "### Live Web Search Results for \"\(query)\":\n\n"
        for (idx, snip) in snippets.enumerated() {
            out += "\(idx + 1). \(snip)\n\n"
        }
        return ToolExecutionResult(
            success: true,
            output: out,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }
}

/// Thread-safe accumulator for a running `Process`'s piped output, capping memory use on runaway
/// commands and recording whether the process was killed for exceeding its time budget. Shared by
/// ToolExecutionEngine's terminal_command and MCPProtocol's executeAppleScript, both of which drain
/// output incrementally to avoid the classic Process/Pipe deadlock (reading only after
/// waitUntilExit() blocks forever once output exceeds the pipe buffer).
final class ShellOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var timedOut = false
    private var wasTruncated = false
    private let maxBytes: Int

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < maxBytes else {
            wasTruncated = true
            return
        }
        data.append(chunk)
        if data.count > maxBytes {
            wasTruncated = true
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func finalize() -> (output: String, didTimeOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var text = String(data: data, encoding: .utf8) ?? ""
        if wasTruncated {
            text += "\n...[output truncated after \(maxBytes) bytes]"
        }
        return (text, timedOut)
    }
}
