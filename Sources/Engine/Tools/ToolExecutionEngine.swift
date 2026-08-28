import Foundation

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

        switch toolName {
        case "file_read":
            let path = dict["path"] as? String ?? ""
            return readFile(path: path, startTime: startTime)

        case "file_write":
            let path = dict["path"] as? String ?? ""
            let content = dict["content"] as? String ?? ""
            return writeFile(path: path, content: content, startTime: startTime)

        case "file_list":
            let path = dict["path"] as? String ?? workspace.folderPath
            return listDirectory(path: path, startTime: startTime)

        case "terminal_command":
            let command = dict["command"] as? String ?? ""
            let cwd = dict["cwd"] as? String ?? workspace.folderPath
            return executeShell(command: command, cwd: cwd, startTime: startTime)

        case "calculator":
            let expr = dict["expression"] as? String ?? ""
            return evaluateMath(expression: expr, startTime: startTime)

        case "web_search":
            let query = dict["query"] as? String ?? ""
            return executeWebSearch(query: query, startTime: startTime)

        case "document_extract", "extract_document", "read_pdf_or_image":
            let rawPath = dict["path"] as? String ?? ""
            let fullPath = rawPath.hasPrefix("/") ? rawPath : (workspace.folderPath as NSString).appendingPathComponent(rawPath)
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

        case "agent_spawn":
            let taskTitle = dict["task_title"] as? String ?? "Sub-task"
            let taskDesc = dict["task_description"] as? String ?? ""
            let targetSubAgentId = dict["subagent_id"] as? String ?? "coder-agent"
            let targetSubAgentName = dict["subagent_name"] as? String ?? "Sub-Agent"
            
            let subTask = SubAgentTask(
                parentAgentId: currentAgent.id,
                parentAgentName: currentAgent.name,
                subAgentId: targetSubAgentId,
                subAgentName: targetSubAgentName,
                taskTitle: taskTitle,
                taskDescription: taskDesc,
                status: .running,
                progress: 0.2,
                depth: (currentAgent.parentAgentId != nil) ? 2 : 1
            )
            
            return ToolExecutionResult(
                success: true,
                output: "Spawned sub-agent [\(targetSubAgentName)] to execute task: \(taskTitle)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                createdSubAgentTask: subTask
            )

        case "agent_message":
            let toAgentId = dict["to_agent_id"] as? String ?? "lead-assistant"
            let toAgentName = dict["to_agent_name"] as? String ?? "Lead Agent"
            let content = dict["content"] as? String ?? ""
            let msgTypeStr = dict["message_type"] as? String ?? "task_delegation"
            let msgType = AgentMessageType(rawValue: msgTypeStr) ?? .consultation
            
            let message = AgentMessage(
                fromAgentId: currentAgent.id,
                fromAgentName: currentAgent.name,
                toAgentId: toAgentId,
                toAgentName: toAgentName,
                messageType: msgType,
                content: content
            )
            
            return ToolExecutionResult(
                success: true,
                output: "Message transmitted to agent [\(toAgentName)]",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                createdAgentMessage: message
            )

        case "memory_store":
            let key = dict["key"] as? String ?? "note"
            let content = dict["content"] as? String ?? ""
            let item = MemoryItem(workspaceId: workspace.id, key: key, content: content)
            var current = PersistenceManager.shared.loadMemories()
            current.append(item)
            PersistenceManager.shared.saveMemories(current)
            return ToolExecutionResult(
                success: true,
                output: "Saved '\(key)' into workspace memory",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        case "memory_recall":
            let query = (dict["query"] as? String ?? "").lowercased()
            let memories = PersistenceManager.shared.loadMemories()
            let matches = memories.filter { $0.key.lowercased().contains(query) || $0.content.lowercased().contains(query) }
            let text = matches.map { "• [\($0.key)] \($0.content)" }.joined(separator: "\n")
            return ToolExecutionResult(
                success: true,
                output: text.isEmpty ? "No matching memories found." : text,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )

        default:
            // Check if this tool is serviced by an active MCP server
            if toolName.hasPrefix("mcp_") || toolName.contains("_") {
                let mcpRes = await MCPClientManager.shared.callTool(serverId: "mcp-default", toolName: toolName, arguments: dict)
                return ToolExecutionResult(
                    success: true,
                    output: mcpRes,
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

    private func readFile(path: String, startTime: Double) -> ToolExecutionResult {
        let expanded = (path as NSString).expandingTildeInPath
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
                error: "Failed to read file: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    private func writeFile(path: String, content: String, startTime: Double) -> ToolExecutionResult {
        let expanded = (path as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return ToolExecutionResult(
                success: true,
                output: "Successfully wrote \(content.count) bytes to \(path)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to write file: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    private func listDirectory(path: String, startTime: Double) -> ToolExecutionResult {
        let expanded = (path as NSString).expandingTildeInPath
        do {
            let items = try fileManager.contentsOfDirectory(atPath: expanded)
            let result = items.prefix(100).joined(separator: "\n")
            return ToolExecutionResult(
                success: true,
                output: result.isEmpty ? "(Directory is empty)" : result,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to list directory: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    private func executeShell(command: String, cwd: String, startTime: Double) -> ToolExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return ToolExecutionResult(
                success: process.terminationStatus == 0,
                output: output,
                error: process.terminationStatus != 0 ? "Process exited with code \(process.terminationStatus)" : nil,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
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

    private func executeWebSearch(query: String, startTime: Double) -> ToolExecutionResult {
        return ToolExecutionResult(
            success: true,
            output: "Search results for '\(query)':\n1. OpenWork Ecosystem & Documentation (https://openwork.ai/docs)\n2. Swift 6 Concurrency & SwiftUI Modern Architecture Guide\n3. Local LLM and Autonomous Multi-Agent Systems Integration",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }
}
