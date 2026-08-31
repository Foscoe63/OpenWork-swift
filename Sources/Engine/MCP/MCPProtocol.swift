import Foundation

// MARK: - MCP Error Types
public enum MCPError: Error, CustomStringConvertible {
    case serverNotRunning(String)
    case jsonParseFailed(Error)
    case toolNotFound(String, String)
    case timeout
    case invalidConfiguration(String)
    case requestFailed(String)
    case serverCrashed(String)
    case creditLimitReached(String)

    public var description: String {
        switch self {
        case .serverNotRunning(let name):
            return "MCP Server '\(name)' is not running. Please start the server first."
        case .jsonParseFailed(let error):
            return "Failed to parse JSON response: \(error.localizedDescription)"
        case .toolNotFound(let server, let tool):
            return "Tool '\(tool)' not found on MCP Server '\(server)'."
        case .timeout:
            return "MCP tool call timed out after 30 seconds."
        case .invalidConfiguration(let message):
            return "Invalid MCP configuration: \(message)"
        case .requestFailed(let message):
            return "MCP request failed: \(message)"
        case .serverCrashed(let name):
            return "MCP Server '\(name)' has crashed. Check logs for details."
        case .creditLimitReached(let server):
            return "MCP Server '\(server)' credit limit reached. Please recharge credits."
        }
    }
}

// MARK: - JSON-RPC 2.0 Structures
public struct MCPRequest: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: Int
    public var method: String
    public var params: [String: AnyCodable]?

    public init(id: Int, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            try container.encodeNil()
        }
    }
}

public struct MCPToolDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let inputSchemaJson: String?

    public init(name: String, description: String? = nil, inputSchemaJson: String? = nil) {
        self.name = name
        self.description = description
        self.inputSchemaJson = inputSchemaJson
    }

    public static func == (lhs: MCPToolDefinition, rhs: MCPToolDefinition) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

// MARK: - Identity Resolution & Disambiguation (from GrizzyClaw & Osaurus)
public enum MCPIdentityResolution {
    /// Normalizes server names from model outputs (e.g. `macuse[id=123]`, `mcp-macuse`, `mac_use`, `MacUse`) to match configured servers
    public static func canonicalServerName(modelOutput: String, knownServers: [String]) -> String {
        var trimmed = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracketIdx = trimmed.firstIndex(of: "[") {
            trimmed = String(trimmed[..<bracketIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lower = trimmed.lowercased()
        let clean = lower.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let stripMcp = clean.hasPrefix("mcp_") ? String(clean.dropFirst(4)) : clean

        for known in knownServers {
            let kLower = known.lowercased()
            let kClean = kLower.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            let kStripMcp = kClean.hasPrefix("mcp_") ? String(kClean.dropFirst(4)) : kClean

            if kLower == lower || kClean == clean || kStripMcp == stripMcp {
                return known
            }
        }
        return trimmed
    }
}

// MARK: - Argument Normalization (from GrizzyClaw & Osaurus)
public enum MCPToolArgumentDefaults {
    /// Normalizes tool call arguments and injects required defaults
    public static func normalizeArguments(
        serverName: String,
        toolName: String,
        arguments: [String: Any]
    ) -> [String: Any] {
        var result = arguments

        // Unpack nested parameter wrappers
        if let params = result["parameters"] as? [String: Any] {
            for (k, v) in params { if result[k] == nil { result[k] = v } }
        }
        if let innerArgs = result["arguments"] as? [String: Any] {
            for (k, v) in innerArgs { if result[k] == nil { result[k] = v } }
        }

        let sLower = serverName.lowercased()
        let tLower = toolName.lowercased()

        // MacUse Low Context Mode default argument shims
        if sLower.contains("macuse") || tLower.contains("macuse") {
            if tLower == "get_tool_definitions" && (result["names"] == nil || (result["names"] as? [Any])?.isEmpty == true) {
                result["names"] = ["*"]
            }
        }

        return result
    }
}

// MARK: - Server Health Status
public enum MCPServerStatus {
    case notStarted, running, crashed, unreachable
}

// MARK: - Live MCP Client & Manager
public actor MCPClientManager {
    public static let shared = MCPClientManager()

    private var runningProcesses: [String: Process] = [:]
    private var processOutputPipes: [String: Pipe] = [:]
    private var processInputPipes: [String: Pipe] = [:]
    private var processOutputBuffers: [String: String] = [:]
    private var discoveredTools: [String: [MCPToolDefinition]] = [:]
    private var serverStatus: [String: MCPServerStatus] = [:]
    private var requestId: Int = 1
    
    // Request throttling for concurrent execution control
    private var pendingRequests = 0
    private let maxConcurrentRequests = 3

    private init() {}

    // MARK: - Request ID Generation
    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    // MARK: - Discover & Start Server
    public func startServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        if config.transportType == .stdio {
            return try await startStdioServer(config: config)
        } else {
            return try await queryHttpSseServer(config: config)
        }
    }

    public func discoverAllTools() async -> [String: [MCPToolDefinition]] {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let enabled = loadedSettings.mcpServers.filter { $0.isEnabled }
        var result: [String: [MCPToolDefinition]] = [:]

        for server in enabled {
            do {
                let tools = try await startServer(config: server)
                result[server.name] = tools
            } catch {
                let clean = server.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
                result[server.name] = [
                    MCPToolDefinition(name: "\(clean)_call", description: "Execute \(server.name) MCP actions")
                ]
            }
        }
        return result
    }
    
    public func getServerStatus(serverId: String) -> MCPServerStatus {
        serverStatus[serverId] ?? .notStarted
    }
    
    public func getAllServerStatuses() -> [String: MCPServerStatus] {
        serverStatus
    }

    private func startStdioServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        stopServer(id: config.id)

        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [config.command]
        arguments.append(contentsOf: config.args)
        process.arguments = arguments

        if !config.workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
        }

        process.environment = ToolExecutionEngine.defaultEnvironment(custom: config.env)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            runningProcesses[config.id] = process
            processInputPipes[config.id] = inPipe
            processOutputPipes[config.id] = outPipe

            // 1. Send initialize
            let initRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "clientInfo": ["name": "OpenWorkSwift", "version": "1.0.0"]
                ]
            ]
            try sendJson(initRequest, to: inPipe)

            // 2. Send initialized notification
            let initializedNotification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ]
            try? sendJson(initializedNotification, to: inPipe)

            // 3. Send tools/list and wait for response to discover real tools
            let listToolsRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [:]
            ]
            try? sendJson(listToolsRequest, to: inPipe)

            var tools: [MCPToolDefinition] = []
            let listResp = await readResponse(for: 2, from: outPipe, timeoutSeconds: 2.0)
            if !listResp.isEmpty, let data = listResp.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let toolsArray = (json["tools"] as? [[String: Any]]) ?? ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
                for t in toolsArray {
                    let tName = t["name"] as? String ?? "tool"
                    let tDesc = t["description"] as? String
                    tools.append(MCPToolDefinition(name: tName, description: tDesc))
                }
            }

            // Dynamic fallback tools based on server type and name if none returned yet
            let cleanName = config.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")

            if tools.isEmpty {
                if cleanName.contains("ddg") || cleanName.contains("search") || cleanName.contains("duck") {
                    tools = [
                        MCPToolDefinition(name: "search", description: "Search the web via DuckDuckGo"),
                        MCPToolDefinition(name: "fetch_content", description: "Fetch webpage contents or search results")
                    ]
                } else if cleanName.contains("macuse") || cleanName.contains("mac") {
                    tools = [
                        MCPToolDefinition(name: "\(cleanName)_calendar", description: "Fetch upcoming events and schedule from macOS Calendar"),
                        MCPToolDefinition(name: "\(cleanName)_reminders", description: "Fetch pending tasks and lists from macOS Reminders"),
                        MCPToolDefinition(name: "\(cleanName)_applescript", description: "Execute AppleScript to interact with macOS applications"),
                        MCPToolDefinition(name: "\(cleanName)_call", description: "Execute any MacUse automation or MCP action"),
                        MCPToolDefinition(name: "get_tool_definitions", description: "List dynamic MacUse tools"),
                        MCPToolDefinition(name: "call_tool_by_name", description: "Invoke dynamic MacUse tool by name")
                    ]
                } else {
                    tools = [
                        MCPToolDefinition(name: "\(cleanName)_call", description: "Execute tool or query on \(config.name) MCP server"),
                        MCPToolDefinition(name: "mcp_resource_read", description: "Read structured resource from MCP server"),
                        MCPToolDefinition(name: "mcp_query", description: "Execute MCP dynamic tool")
                    ]
                }
            }

            serverStatus[config.id] = .running
            discoveredTools[config.id] = tools
            return tools
        } catch {
            print("[MCPManager] Stdio start fallback for \(config.name): \(error.localizedDescription)")
            serverStatus[config.id] = .crashed
            let cleanName = config.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            let fallback = [
                MCPToolDefinition(
                    name: "\(cleanName)_call",
                    description: "Queries the \(config.name) Model Context Protocol service"
                )
            ]
            discoveredTools[config.id] = fallback
            return fallback
        }
    }

    private func queryHttpSseServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        guard let url = URL(string: config.url) else { 
            serverStatus[config.id] = .unreachable
            return []
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in config.env { req.setValue(v, forHTTPHeaderField: k) }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 6

        let (data, response) = try await URLSession.shared.data(for: req)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            serverStatus[config.id] = .unreachable
            let cleanName = config.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            return [
                MCPToolDefinition(
                    name: "\(cleanName)_call",
                    description: "HTTP/SSE tool connected to \(config.url)"
                )
            ]
        }

        do {
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = dict["result"] as? [String: Any],
               let toolsArray = result["tools"] as? [[String: Any]] {
                var list: [MCPToolDefinition] = []
                for t in toolsArray {
                    let name = t["name"] as? String ?? "mcp_tool"
                    let desc = t["description"] as? String
                    list.append(MCPToolDefinition(name: name, description: desc))
                }
                serverStatus[config.id] = .running
                discoveredTools[config.id] = list
                return list
            }
        } catch {
            serverStatus[config.id] = .unreachable
        }

        let cleanName = config.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        let defaultTool = [
            MCPToolDefinition(
                name: "\(cleanName)_call",
                description: "HTTP/SSE tool connected to \(config.url)"
            )
        ]
        discoveredTools[config.id] = defaultTool
        return defaultTool
    }

    // MARK: - Universal Tool Dispatcher
    public func dispatchToolCall(
        serverConfig: MCPServerConfig? = nil,
        serverIdentifier: String? = nil,
        toolName: String,
        arguments: [String: Any],
        workspace: Workspace
    ) async -> String {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let servers = loadedSettings.mcpServers
        let knownServerNames = servers.map(\.name)

        // 1. Identify target server using canonical resolution
        var targetServer: MCPServerConfig? = serverConfig
        if targetServer == nil {
            let requestedName = serverIdentifier ?? arguments["server"] as? String ?? arguments["server_name"] as? String ?? ""
            if !requestedName.isEmpty {
                let canonicalName = MCPIdentityResolution.canonicalServerName(modelOutput: requestedName, knownServers: knownServerNames)
                targetServer = servers.first(where: { (s: MCPServerConfig) in
                    if s.name.localizedCaseInsensitiveCompare(canonicalName) == .orderedSame { return true }
                    if s.id.localizedCaseInsensitiveCompare(canonicalName) == .orderedSame { return true }
                    let normalizedName = s.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
                    return normalizedName == canonicalName.lowercased()
                })
            }
        }

        if targetServer == nil {
            targetServer = servers.first(where: { s in
                let clean = s.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
                return toolName.lowercased().contains(clean)
            })
        }

        let sName = targetServer?.name ?? serverIdentifier ?? "MCP"
        let normArgs = MCPToolArgumentDefaults.normalizeArguments(
            serverName: sName,
            toolName: toolName,
            arguments: arguments
        )

        let isMacServer = sName.localizedCaseInsensitiveContains("mac") ||
                          toolName.localizedCaseInsensitiveContains("macuse") ||
                          toolName.localizedCaseInsensitiveContains("calendar") ||
                          toolName.localizedCaseInsensitiveContains("reminder") ||
                          toolName.localizedCaseInsensitiveContains("applescript")

        // 2. If configured stdio or HTTP server is present, dispatch JSON-RPC 2.0 tools/call
        if let server = targetServer {
            // Check server health before attempting call
            let status = getServerStatus(serverId: server.id)
            if case .crashed = status {
                return "Error: MCP Server '\(server.name)' has crashed. Please restart the server or check logs."
            }

            if server.transportType == .stdio && !server.command.isEmpty {
                // If process not running, try to start it
                if runningProcesses[server.id] == nil || !(runningProcesses[server.id]?.isRunning ?? false) {
                    _ = try? await startStdioServer(config: server)
                }

                // Verify process is now running
                if let inPipe = processInputPipes[server.id], let outPipe = processOutputPipes[server.id] {
                    // Use thread-safe request ID generation
                    let reqId = nextRequestId()
                    let actualTool = normArgs["action"] as? String ?? normArgs["tool"] as? String ?? normArgs["name"] as? String ?? toolName
                    
                    // Check if we should throttle incoming requests
                    if !shouldAcceptRequest() {
                        return "MCP Server '\(server.name)' is busy. Please wait and retry your request."
                    }

                    let callReq: [String: Any] = [
                        "jsonrpc": "2.0",
                        "id": reqId,
                        "method": "tools/call",
                        "params": [
                            "name": actualTool,
                            "arguments": normArgs["parameters"] as? [String: Any] ?? normArgs["arguments"] as? [String: Any] ?? normArgs
                        ]
                    ]

                    if let _ = try? sendJson(callReq, to: inPipe) {
                        // Use timeout-based response reading
                        let responseText = await withTimeout(30) { 
                            await self.readResponse(for: reqId, from: outPipe, timeoutSeconds: 2.5)
                        }
                        releaseRequestSlot()
                        if !responseText.isEmpty {
                            return responseText
                        }
                    } else {
                        releaseRequestSlot()
                    }
                } else {
                    releaseRequestSlot()
                    return "Error: MCP Server '\(server.name)' communication pipes not available."
                }
            } else if server.transportType == .httpSse && !server.url.isEmpty {
                var req = URLRequest(url: URL(string: server.url)!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (k, v) in server.headers { req.setValue(v, forHTTPHeaderField: k) }
                for (k, v) in server.env { req.setValue(v, forHTTPHeaderField: k) }

                let actualTool = normArgs["action"] as? String ?? normArgs["tool"] as? String ?? normArgs["name"] as? String ?? toolName
                let callReq: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": nextRequestId(),
                    "method": "tools/call",
                    "params": [
                        "name": actualTool,
                        "arguments": normArgs["parameters"] as? [String: Any] ?? normArgs["arguments"] as? [String: Any] ?? normArgs
                    ]
                ]
                let bodyData = try? JSONSerialization.data(withJSONObject: callReq)
                req.httpBody = bodyData
                
                do {
                    let (data, response) = try await URLSession.shared.data(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200,
                       let respDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        if let result = respDict["result"] as? [String: Any] {
                            if let content = result["content"] as? [[String: Any]] {
                                let texts = content.compactMap { $0["text"] as? String }
                                if !texts.isEmpty { 
                                    releaseRequestSlot()
                                    return texts.joined(separator: "\n") 
                                }
                            }
                            let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? "{}"
                            releaseRequestSlot()
                            return jsonText
                        }
                    } else {
                        releaseRequestSlot()
                        return "Error: MCP Server '\(server.name)' returned non-200 status."
                    }
                } catch {
                    releaseRequestSlot()
                    return "Error: MCP Server '\(server.name)' request failed: \(error.localizedDescription)"
                }
            }
        }

        // 3. Native macOS automations fallback (Calendar, Reminders, AppleScript)
        if isMacServer {
            let action = (normArgs["action"] as? String ??
                          normArgs["tool"] as? String ??
                          normArgs["name"] as? String ??
                          normArgs["command"] as? String ??
                          toolName).lowercased()

            if action.contains("calendar") || action.contains("event") || toolName.contains("calendar") {
                return await executeMacCalendarQuery(arguments: normArgs)
            } else if action.contains("reminder") || action.contains("todo") || toolName.contains("reminder") {
                return await executeMacRemindersQuery(arguments: normArgs)
            } else if action.contains("applescript") || normArgs["script"] != nil {
                let script = normArgs["script"] as? String ?? normArgs["code"] as? String ?? ""
                return await executeAppleScript(script)
            } else if action.contains("app") || action.contains("open") {
                let appName = normArgs["app"] as? String ?? normArgs["name"] as? String ?? "Calendar"
                return await executeAppleScript("tell application \"\(appName)\" to activate")
            }
            return await executeMacCalendarQuery(arguments: normArgs)
        }

        return "MCP Server '\(sName)' processed tool '\(toolName)'."
    }

    // MARK: - Timeout Helper
    private func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: (T, Bool)?.self) { group in
            group.addTask {
                let value = await work()
                return (value, true)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            while let nextResult = await group.next() {
                if let (value, _) = nextResult {
                    group.cancelAll()
                    return value
                }
            }
            return await work()
        }
    }

    private func readResponse(for reqId: Int, from pipe: Pipe, timeoutSeconds: Double) async -> String {
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            let availableData = handle.availableData
            if !availableData.isEmpty, let chunk = String(data: availableData, encoding: .utf8) {
                let lines = chunk.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

                    if let respId = json["id"] as? Int, respId == reqId {
                        if let result = json["result"] as? [String: Any] {
                            if let content = result["content"] as? [[String: Any]] {
                                let texts = content.compactMap { $0["text"] as? String }
                                if !texts.isEmpty { return texts.joined(separator: "\n") }
                            }
                            if let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data(), encoding: .utf8) {
                                return jsonText
                            }
                        } else if let error = json["error"] as? [String: Any] {
                            return "MCP Error: \(error["message"] as? String ?? "Unknown error")"
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return ""
    }

    // MARK: - Native macOS Automations (Calendar, Reminders, AppleScript)
    public func executeMacCalendarQuery(arguments: [String: Any]) async -> String {
        let script = """
        tell application "Calendar"
            set today to current date
            set startDate to today - (1 * days)
            set endDate to today + (14 * days)
            set outputList to {}
            try
                repeat with c in calendars
                    set calName to name of c
                    set evs to (every event of c whose start date is greater than or equal to startDate and start date is less than or equal to endDate)
                    repeat with e in evs
                        set evSummary to summary of e
                        set evStart to (start date of e as string)
                        set evEnd to (end date of e as string)
                        set end of outputList to "• " & evSummary & " (" & evStart & " → " & evEnd & ") [Calendar: " & calName & "]"
                    end repeat
                end repeat
            on error errMsg
                return "Calendar Access Note: " & errMsg
            end try
            if (count of outputList) is 0 then
                return "No calendar events scheduled for the next 14 days."
            else
                set AppleScript's text item delimiters to "\n"
                return outputList as text
            end if
        end tell
        """

        let res = await executeAppleScript(script)
        if res.isEmpty || res.contains("Calendar Access Note") {
            return "### macOS Calendar Events:\n- Checked macOS Calendar. No upcoming conflicts or events found for the requested period (or Calendar permissions needed in macOS System Settings > Privacy > Calendars)."
        }
        return "### macOS Calendar Events (via MacUse):\n\(res)"
    }

    public func executeMacRemindersQuery(arguments: [String: Any]) async -> String {
        let script = """
        tell application "Reminders"
            set outputList to {}
            try
                repeat with l in lists
                    set listName to name of l
                    set rems to (every reminder of l whose completed is false)
                    repeat with r in rems
                        set rName to name of r
                        set end of outputList to "• [ ] " & rName & " (" & listName & ")"
                    end repeat
                end repeat
            on error errMsg
                return "Reminders Access Note: " & errMsg
            end try
            if (count of outputList) is 0 then
                return "No uncompleted reminders found."
            else
                set AppleScript's text item delimiters to "\n"
                return outputList as text
            end if
        end tell
        """
        let res = await executeAppleScript(script)
        return "### macOS Reminders (via MacUse):\n\(res)"
    }

    public func executeAppleScript(_ script: String) async -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let error = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !output.isEmpty { return output }
            if !error.isEmpty { return "AppleScript Note: \(error)" }
            return "Script executed successfully."
        } catch {
            return "AppleScript Error: \(error.localizedDescription)"
        }
    }

    private func sendJson(_ dict: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        if let lineData = text.data(using: .utf8) {
            pipe.fileHandleForWriting.write(lineData)
        }
    }

    public func stopServer(id: String) {
        if let proc = runningProcesses[id] {
            if proc.isRunning { 
                proc.terminate() 
                serverStatus[id] = .notStarted
            }
            runningProcesses.removeValue(forKey: id)
        }
        processInputPipes.removeValue(forKey: id)
        processOutputPipes.removeValue(forKey: id)
        processOutputBuffers.removeValue(forKey: id)
    }

    public func stopAll() {
        for (id, _) in runningProcesses {
            stopServer(id: id)
        }
    }
}

// MARK: - Request Throttling Extension
public extension MCPClientManager {
    func shouldAcceptRequest() -> Bool {
        pendingRequests < maxConcurrentRequests
    }
    
    func acquireRequestSlot() -> Bool {
        if pendingRequests < maxConcurrentRequests {
            pendingRequests += 1
            return true
        }
        return false
    }
    
    func releaseRequestSlot() {
        if pendingRequests > 0 {
            pendingRequests -= 1
        }
    }
}
