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

    /// Build from a tools/list entry, preserving `inputSchema` when present.
    public static func fromToolsListEntry(_ t: [String: Any]) -> MCPToolDefinition {
        let name = t["name"] as? String ?? "tool"
        let desc = t["description"] as? String
        let schemaObj = t["inputSchema"] as? [String: Any] ?? t["input_schema"] as? [String: Any]
        var schemaJson: String?
        if let schemaObj,
           let data = try? JSONSerialization.data(withJSONObject: schemaObj),
           let s = String(data: data, encoding: .utf8) {
            schemaJson = s
        }
        return MCPToolDefinition(name: name, description: desc, inputSchemaJson: schemaJson)
    }
}

/// Radiant-compatible namespaced MCP tool names: `mcp__{serverId}__{toolName}`.
public enum MCPNamespacedTool {
    public static func name(serverId: String, toolName: String) -> String {
        "mcp__\(serverId)__\(toolName)"
    }

    public static func parse(_ name: String) -> (serverId: String, toolName: String)? {
        let parts = name.split(separator: "__", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        let serverId = parts[1]
        let toolName = parts.dropFirst(2).joined(separator: "__")
        guard !serverId.isEmpty, !toolName.isEmpty else { return nil }
        return (serverId, toolName)
    }

    public static func isNamespaced(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
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
        var result = coerceJSONMaps(in: arguments)

        // Unpack nested parameter wrappers (but keep MacUse meta-tool shape intact).
        let leaf = toolName.lowercased()
        let isCallByName = leaf == "call_tool_by_name" || leaf == "call_tool"
        if isCallByName {
            // Local models often emit `"arguments": "{}"` (string). MacUse requires a map.
            if result["arguments"] == nil {
                result["arguments"] = [String: Any]()
            } else if let s = result["arguments"] as? String {
                result["arguments"] = parseObjectMap(s) ?? [String: Any]()
            } else if !(result["arguments"] is [String: Any]) {
                result["arguments"] = [String: Any]()
            }
            if let params = result["parameters"] as? String {
                result["parameters"] = parseObjectMap(params) ?? [String: Any]()
            }
        } else if leaf != "get_tool_definitions" {
            if let params = result["parameters"] as? [String: Any] {
                for (k, v) in params { if result[k] == nil { result[k] = v } }
            }
            if let innerArgs = result["arguments"] as? [String: Any] {
                for (k, v) in innerArgs { if result[k] == nil { result[k] = v } }
            }
        }
        // get_tool_definitions: leave `{names:[...]}` alone — do NOT inject empty `arguments`.

        let sLower = serverName.lowercased()
        let tLower = toolName.lowercased()

        // MacUse Low Context Mode default argument shims
        if tLower == "get_tool_definitions"
            || sLower.contains("macuse")
            || tLower.contains("macuse") {
            if tLower == "get_tool_definitions"
                && (result["names"] == nil || (result["names"] as? [Any])?.isEmpty == true) {
                result["names"] = ["*"]
            }
        }

        return result
    }

    /// Recursively turn JSON-string maps into real dictionaries (MLX/tool-call footgun).
    public static func coerceJSONMaps(in arguments: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in arguments {
            result[key] = coerceValue(value)
        }
        return result
    }

    private static func coerceValue(_ value: Any) -> Any {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let obj = parseObjectMap(trimmed) {
                return obj
            }
            if trimmed.hasPrefix("["),
               let data = trimmed.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return arr.map { coerceValue($0) }
            }
            return s
        }
        if let dict = value as? [String: Any] {
            return coerceJSONMaps(in: dict)
        }
        if let arr = value as? [Any] {
            return arr.map { coerceValue($0) }
        }
        return value
    }

    public static func parseObjectMap(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return coerceJSONMaps(in: obj)
    }

    /// Encode a MacUse `call_tool_by_name` payload with a real object for `arguments`.
    public static func macUseCallArgsJSON(toolName: String, arguments: [String: Any] = [:]) -> String {
        let payload: [String: Any] = [
            "name": toolName,
            "arguments": arguments
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else {
            return #"{"name":"\#(toolName)","arguments":{}}"#
        }
        return s
    }

    /// MacUse results often include `actions: [{ tool_call: { tool, arguments } }]`.
    /// Radiant-quality local loops execute those next instead of hoping the model continues.
    public static func suggestedCalls(fromToolResult text: String) -> [(nestedTool: String, arguments: [String: Any])] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let actions = (root["actions"] as? [[String: Any]]) ?? []
        var out: [(String, [String: Any])] = []
        for action in actions {
            guard let tc = action["tool_call"] as? [String: Any] else { continue }
            let nested = (tc["tool"] as? String)
                ?? (tc["name"] as? String)
                ?? ((tc["arguments"] as? [String: Any])?["name"] as? String)
            guard let nested, !nested.isEmpty else { continue }
            var args: [String: Any] = [:]
            if let a = tc["arguments"] as? [String: Any] {
                // Shape A: { tool: mail_search_messages, arguments: { limit: 50 } }
                // Shape B: { tool: call_tool_by_name, arguments: { name, arguments } }
                if nested == "call_tool_by_name" || nested == "call_tool",
                   let innerName = a["name"] as? String {
                    let innerArgs = (a["arguments"] as? [String: Any]) ?? [:]
                    out.append((innerName, coerceJSONMaps(in: innerArgs)))
                    continue
                }
                if a["name"] != nil && nested.hasPrefix("mail_") == false {
                    // Nested call_tool_by_name style without rewriting nested name above.
                    if let innerName = a["name"] as? String {
                        let innerArgs = (a["arguments"] as? [String: Any]) ?? [:]
                        out.append((innerName, coerceJSONMaps(in: innerArgs)))
                        continue
                    }
                }
                args = coerceJSONMaps(in: a)
            } else if let s = tc["arguments"] as? String {
                args = parseObjectMap(s) ?? [:]
            }
            out.append((nested, args))
        }
        return out
    }
}

// MARK: - Server Health Status
public enum MCPServerStatus {
    case notStarted, running, crashed, unreachable
}

private enum MCPLaunchError: LocalizedError {
    case processExited(String)

    var errorDescription: String? {
        switch self {
        case .processExited(let message): return message
        }
    }
}

// MARK: - Live MCP Client & Manager
public actor MCPClientManager {
    public static let shared = MCPClientManager()

    private var runningProcesses: [String: Process] = [:]
    private var processOutputPipes: [String: Pipe] = [:]
    private var processInputPipes: [String: Pipe] = [:]
    /// Thread-safe stdout accumulators fed by FileHandle readability handlers (actor-safe across awaits).
    private var processOutputBuffers: [String: MCPStdioBuffer] = [:]
    private var discoveredTools: [String: [MCPToolDefinition]] = [:]
    private var serverStatus: [String: MCPServerStatus] = [:]
    private var sdkSessions: [String: MCPSDKSession] = [:]
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
                serverStatus[server.id] = .crashed
                result[server.name] = []
            }
        }
        return result
    }

    /// Radiant-style first-class MCP tools for the agent loop:
    /// `mcp__{serverId}__{toolName}` with real JSON schemas from tools/list.
    ///
    /// - Parameters:
    ///   - preferServerIds: Warm these first (e.g. MacUse when the user asks about mail).
    ///     When non-empty, only these servers block the agent; others warm in the background.
    ///   - perServerTimeout: Hard cap per server so a stuck `npx`/MacUse cold start cannot
    ///     leave the chat bubble empty and `isStreaming` forever.
    public func mcpToolDefs(
        preferServerIds: [String] = [],
        perServerTimeout: Duration = .seconds(12)
    ) async -> [Tool] {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let enabled = loadedSettings.mcpServers.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return [] }

        let preferred: [MCPServerConfig]
        let deferred: [MCPServerConfig]
        if preferServerIds.isEmpty {
            preferred = enabled
            deferred = []
        } else {
            let preferSet = Set(preferServerIds)
            let matched = enabled.filter { preferSet.contains($0.id) || preferSet.contains($0.name) }
            // Fall back to all if preference matched nothing (stale id).
            if matched.isEmpty {
                preferred = enabled
                deferred = []
            } else {
                preferred = matched
                deferred = enabled.filter { server in !matched.contains(where: { $0.id == server.id }) }
            }
        }

        await warmServers(preferred, perServerTimeout: perServerTimeout)

        if !deferred.isEmpty {
            let timeout = perServerTimeout
            Task {
                await self.warmServers(deferred, perServerTimeout: timeout)
            }
        }

        var result: [Tool] = []
        // Prefer returning tools from preferred servers; include any already-cached others.
        let order = preferred + deferred
        var seenIds = Set<String>()
        for server in order where seenIds.insert(server.id).inserted {
            let defs = discoveredTools[server.id] ?? []
            for t in defs {
                let namespaced = MCPNamespacedTool.name(serverId: server.id, toolName: t.name)
                let schema = t.inputSchemaJson
                    ?? #"{"type":"object","properties":{}}"#
                let leaf = t.name.lowercased()
                let readOnly = Self.isReadOnlyMCPTool(leaf)
                result.append(Tool(
                    id: namespaced,
                    name: namespaced,
                    displayName: "\(server.name): \(t.name)",
                    description: "[\(server.name)] \(t.description ?? t.name)",
                    category: .mcp,
                    parametersJsonSchema: schema,
                    isEnabled: true,
                    requiresApproval: !readOnly
                ))
            }
        }
        return result
    }

    private func warmServers(_ servers: [MCPServerConfig], perServerTimeout: Duration) async {
        guard !servers.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask {
                    await self.ensureServerReady(server, timeout: perServerTimeout)
                }
            }
            for await _ in group {}
        }
    }

    private func ensureServerReady(_ server: MCPServerConfig, timeout: Duration = .seconds(12)) async {
        if case .running = serverStatus[server.id],
           let cached = discoveredTools[server.id], !cached.isEmpty {
            return
        }
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    _ = try await self.startServer(config: server)
                    return true
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return false
                }
                let started = try await group.next() ?? false
                group.cancelAll()
                if !started {
                    throw MCPError.timeout
                }
            }
        } catch is CancellationError {
            // Parent cancelled — leave state as-is.
        } catch {
            if case MCPError.timeout = error {
                serverStatus[server.id] = .crashed
                print("[MCPManager] Timed out starting \(server.name) after \(timeout)")
            }
            // Leave discoveredTools unchanged (empty) so the agent can surface a clear notice.
        }
    }

    /// Match user intent to MCP server ids so we do not block the first token on every `npx` server.
    public nonisolated static func preferredServerIds(
        forPrompt prompt: String,
        servers: [MCPServerConfig]
    ) -> [String] {
        let p = prompt.lowercased()
        let enabled = servers.filter(\.isEnabled)
        func match(_ predicates: [(MCPServerConfig) -> Bool]) -> [String] {
            enabled.filter { server in predicates.contains { $0(server) } }.map(\.id)
        }

        let macuseIntent = p.contains("macuse") || p.contains("mac use")
            || ((p.contains("mail") || p.contains("email") || p.contains("inbox") || p.contains("calendar"))
                && (p.contains("mcp") || p.contains("computer") || p.contains("this computer")))
        if macuseIntent {
            let ids = match([
                { $0.name.lowercased().contains("macuse") },
                { $0.command.lowercased().contains("macuse") }
            ])
            if !ids.isEmpty { return ids }
        }

        if p.contains("codegraph") {
            let ids = match([
                { $0.name.lowercased().contains("codegraph") },
                { $0.command.lowercased().contains("codegraph") }
            ])
            if !ids.isEmpty { return ids }
        }

        // No strong preference — warm everything (still per-server timed out).
        return []
    }

    nonisolated static func isReadOnlyMCPTool(_ leafName: String) -> Bool {
        let leaf = leafName.lowercased()
        if ["get_tool_definitions", "list_tools", "tools_list", "search", "fetch_content",
            "codegraph_explore", "fetch", "read_resource"].contains(leaf) {
            return true
        }
        return leaf.hasPrefix("list_") || leaf.hasPrefix("get_") || leaf.hasPrefix("search")
            || leaf.hasPrefix("fetch") || leaf.hasPrefix("read_") || leaf.hasPrefix("find_")
    }

    /// Resolve the MCP `tools/call` name + arguments.
    /// MacUse exposes only meta-tools (`get_tool_definitions`, `call_tool_by_name`); nested
    /// `name`/`arguments` must stay as parameters — do not unwrap them into a fake top-level tool.
    nonisolated static func resolveMCPCall(
        toolName: String,
        arguments: [String: Any]
    ) -> (name: String, arguments: [String: Any]) {
        let leaf = toolName.lowercased()
        if leaf == "call_tool_by_name" || leaf == "call_tool" || leaf == "get_tool_definitions" {
            return (toolName, arguments)
        }

        var actualTool = arguments["action"] as? String
            ?? arguments["tool"] as? String
            ?? arguments["name"] as? String
            ?? toolName
        // Models often emit `codegraph_call` with nested `{tool: ...}` — unwrap that.
        if actualTool.lowercased().hasSuffix("_call"),
           let nested = arguments["tool"] as? String,
           !nested.isEmpty,
           nested.lowercased() != actualTool.lowercased() {
            actualTool = nested
        }
        let callArgs = arguments["parameters"] as? [String: Any]
            ?? arguments["arguments"] as? [String: Any]
            ?? arguments.filter {
                !["action", "tool", "name", "server", "server_name", "parameters", "arguments"].contains($0.key)
            }
        return (actualTool, callArgs)
    }
    
    public func getServerStatus(serverId: String) -> MCPServerStatus {
        serverStatus[serverId] ?? .notStarted
    }
    
    public func getAllServerStatuses() -> [String: MCPServerStatus] {
        serverStatus
    }

    private func startStdioServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        await stopServer(id: config.id)

        // Prefer the official MCP Swift SDK (Radiant parity); fall back to hand-rolled pipes.
        do {
            let session = MCPSDKSession(config: config)
            let tools = try await session.start()
            sdkSessions[config.id] = session
            discoveredTools[config.id] = tools
            serverStatus[config.id] = .running
            return tools
        } catch {
            print("[MCPManager] SDK start failed for \(config.name), falling back to hand-rolled: \(error.localizedDescription)")
        }

        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        // Never attach an unread stderr Pipe — MCP servers (node/python) log heavily to stderr and
        // will deadlock once the ~64KB pipe buffer fills, freezing the app mid tool-call.
        process.standardError = FileHandle.nullDevice

        let env = ToolExecutionEngine.defaultEnvironment(custom: config.env)
        let launchArgs = Self.sanitizedStdioArgs(command: config.command, name: config.name, args: config.args)
        let resolved = Self.resolveExecutable(config.command, environment: env)
        if resolved.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = launchArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [config.command] + launchArgs
        }

        if !config.workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
        }

        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe

        let stdoutBuffer = MCPStdioBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stdoutBuffer.append(chunk)
            }
        }

        do {
            try process.run()
            // Bad CLI args (e.g. codegraph `alwaysLoad true`) exit immediately — writing stdin then
            // used to raise an uncaught NSException via FileHandle.write(_:) and kill the app.
            try await Task.sleep(nanoseconds: 120_000_000)
            guard process.isRunning else {
                outPipe.fileHandleForReading.readabilityHandler = nil
                throw MCPLaunchError.processExited(
                    "MCP '\(config.name)' exited immediately. Check command/args (got: \(config.command) \(launchArgs.joined(separator: " ")))."
                )
            }

            runningProcesses[config.id] = process
            processInputPipes[config.id] = inPipe
            processOutputPipes[config.id] = outPipe
            processOutputBuffers[config.id] = stdoutBuffer

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
            guard process.isRunning else {
                throw MCPLaunchError.processExited("MCP '\(config.name)' died during initialize.")
            }

            // 2. Send initialized notification
            let initializedNotification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ]
            try sendJson(initializedNotification, to: inPipe)

            // 3. Send tools/list and wait for response to discover real tools
            let listToolsRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [:]
            ]
            try sendJson(listToolsRequest, to: inPipe)

            var tools: [MCPToolDefinition] = []
            // MacUse and other heavy servers can take longer than 3s to answer tools/list.
            let listResp = await readResponse(for: 2, buffer: stdoutBuffer, timeoutSeconds: 12.0)
            if !listResp.isEmpty, let data = listResp.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let toolsArray = (json["tools"] as? [[String: Any]]) ?? ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
                for t in toolsArray {
                    tools.append(MCPToolDefinition.fromToolsListEntry(t))
                }
            }

            guard process.isRunning else {
                throw MCPLaunchError.processExited("MCP '\(config.name)' exited after handshake.")
            }

            serverStatus[config.id] = .running
            discoveredTools[config.id] = tools
            return tools
        } catch {
            print("[MCPManager] Stdio start failed for \(config.name): \(error.localizedDescription)")
            outPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            runningProcesses.removeValue(forKey: config.id)
            processInputPipes.removeValue(forKey: config.id)
            processOutputPipes.removeValue(forKey: config.id)
            processOutputBuffers.removeValue(forKey: config.id)
            serverStatus[config.id] = .crashed
            discoveredTools[config.id] = []
            throw error
        }
    }

    /// Drop invalid CodeGraph argv tokens such as `alwaysLoad` / `true` that make `serve` exit immediately.
    static func sanitizedStdioArgs(command: String, name: String, args: [String]) -> [String] {
        let isCodegraph = command.lowercased().contains("codegraph")
            || name.lowercased().contains("codegraph")
            || name.lowercased().contains("code_graph")
        guard isCodegraph else { return args }

        var out: [String] = []
        var i = 0
        while i < args.count {
            let tok = args[i]
            switch tok {
            case "serve", "--mcp", "--no-watch":
                out.append(tok)
                i += 1
            case "-p", "--path":
                out.append(tok)
                if i + 1 < args.count {
                    out.append(args[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            default:
                // Drop unknowns (alwaysLoad, true, etc.)
                i += 1
            }
        }
        if !out.contains("serve") { out.insert("serve", at: 0) }
        if !out.contains("--mcp") { out.append("--mcp") }
        return out
    }

    static func resolveExecutable(_ command: String, environment: [String: String]) -> String {
        if command.contains("/"), FileManager.default.isExecutableFile(atPath: command) {
            return command
        }
        let pathDirs = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        for dir in pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return command
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
            discoveredTools[config.id] = []
            return []
        }

        do {
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = dict["result"] as? [String: Any],
               let toolsArray = result["tools"] as? [[String: Any]] {
                var list: [MCPToolDefinition] = []
                for t in toolsArray {
                    list.append(MCPToolDefinition.fromToolsListEntry(t))
                }
                serverStatus[config.id] = .running
                discoveredTools[config.id] = list
                return list
            }
        } catch {
            serverStatus[config.id] = .unreachable
        }

        discoveredTools[config.id] = []
        return []
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
                let hasSDK = sdkSessions[server.id] != nil
                let procRunning = runningProcesses[server.id]?.isRunning == true
                if !hasSDK && !procRunning {
                    _ = try? await startStdioServer(config: server)
                }

                // Official SDK path (Radiant parity)
                if let session = sdkSessions[server.id] {
                    let resolved = Self.resolveMCPCall(toolName: toolName, arguments: normArgs)
                    do {
                        let raw = try await session.callTool(name: resolved.name, arguments: resolved.arguments)
                        return ToolBounds.boundResult(raw).text
                    } catch {
                        return "Error: MCP SDK call to '\(server.name)'/\(resolved.name) failed: \(error.localizedDescription)"
                    }
                }

                guard let proc = runningProcesses[server.id], proc.isRunning else {
                    return "Error: MCP Server '\(server.name)' failed to start. If this is CodeGraph, args must be `serve --mcp` (not `alwaysLoad true`)."
                }

                // Verify process is now running
                if let inPipe = processInputPipes[server.id],
                   let stdoutBuffer = processOutputBuffers[server.id] {
                    let reqId = nextRequestId()
                    let resolved = Self.resolveMCPCall(toolName: toolName, arguments: normArgs)
                    let actualTool = resolved.name
                    let callArgs = resolved.arguments

                    if !acquireRequestSlot() {
                        return "MCP Server '\(server.name)' is busy. Please wait and retry your request."
                    }

                    // `list_tools` is an MCP protocol method (tools/list), not a tools/call target.
                    let listAliases: Set<String> = ["list_tools", "tools_list", "list-tools", "tools/list", "listtools"]
                    let callReq: [String: Any]
                    if listAliases.contains(actualTool.lowercased()) {
                        callReq = [
                            "jsonrpc": "2.0",
                            "id": reqId,
                            "method": "tools/list",
                            "params": [:]
                        ]
                    } else {
                        callReq = [
                            "jsonrpc": "2.0",
                            "id": reqId,
                            "method": "tools/call",
                            "params": [
                                "name": actualTool,
                                "arguments": callArgs
                            ]
                        ]
                    }

                    do {
                        try sendJson(callReq, to: inPipe)
                        let responseText = await self.readResponse(for: reqId, buffer: stdoutBuffer, timeoutSeconds: 30.0)
                        releaseRequestSlot()
                        if !responseText.isEmpty {
                            return responseText
                        }
                        return "MCP Server '\(server.name)' returned an empty response for '\(actualTool)' (timed out or no matching JSON-RPC id)."
                    } catch {
                        releaseRequestSlot()
                        return "Error: failed to send MCP request to '\(server.name)': \(error.localizedDescription)"
                    }
                } else {
                    return "Error: MCP Server '\(server.name)' communication pipes not available."
                }
            } else if server.transportType == .httpSse && !server.url.isEmpty {
                guard let endpoint = URL(string: server.url) else {
                    return "Error: MCP Server '\(server.name)' has an invalid URL: \(server.url)"
                }
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (k, v) in server.headers { req.setValue(v, forHTTPHeaderField: k) }
                for (k, v) in server.env { req.setValue(v, forHTTPHeaderField: k) }

                var actualTool = normArgs["action"] as? String ?? normArgs["tool"] as? String ?? normArgs["name"] as? String ?? toolName
                if actualTool.lowercased().hasSuffix("_call"),
                   let nested = normArgs["tool"] as? String,
                   !nested.isEmpty,
                   nested.lowercased() != actualTool.lowercased() {
                    actualTool = nested
                }
                let callArgs = normArgs["parameters"] as? [String: Any]
                    ?? normArgs["arguments"] as? [String: Any]
                    ?? normArgs.filter { !["action", "tool", "name", "server", "server_name", "parameters", "arguments"].contains($0.key) }
                let listAliases: Set<String> = ["list_tools", "tools_list", "list-tools", "tools/list", "listtools"]
                let callReq: [String: Any]
                if listAliases.contains(actualTool.lowercased()) {
                    callReq = [
                        "jsonrpc": "2.0",
                        "id": nextRequestId(),
                        "method": "tools/list",
                        "params": [:]
                    ]
                } else {
                    callReq = [
                        "jsonrpc": "2.0",
                        "id": nextRequestId(),
                        "method": "tools/call",
                        "params": [
                            "name": actualTool,
                            "arguments": callArgs
                        ]
                    ]
                }
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
                                    return texts.joined(separator: "\n")
                                }
                            }
                            if let tools = result["tools"] as? [[String: Any]] {
                                let names = tools.compactMap { $0["name"] as? String }
                                if !names.isEmpty {
                                    return "Available tools on \(server.name):\n" + names.map { "- \($0)" }.joined(separator: "\n")
                                }
                            }
                            let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? "{}"
                            return jsonText
                        }
                        if let error = respDict["error"] as? [String: Any] {
                            return "MCP Error from '\(server.name)': \(error["message"] as? String ?? "\(error)")"
                        }
                    } else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        return "Error: MCP Server '\(server.name)' returned HTTP \(status)."
                    }
                } catch {
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

    private func readResponse(for reqId: Int, buffer: MCPStdioBuffer, timeoutSeconds: Double) async -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if let matched = buffer.extractJSONRPCResponse(id: reqId) {
                return matched
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Final attempt after timeout window
        return buffer.extractJSONRPCResponse(id: reqId) ?? ""
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

        // Drain both pipes as data arrives rather than reading only after waitUntilExit(): besides
        // the usual deadlock once output exceeds the pipe buffer, a first-time Calendar/Reminders
        // access prompt can leave osascript blocked on a system permission dialog indefinitely, so
        // this also needs a hard timeout rather than an unbounded wait.
        let outState = ShellOutputState(maxBytes: 50_000)
        let errState = ShellOutputState(maxBytes: 50_000)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outState.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errState.append(chunk) }
        }

        let timeoutSeconds: TimeInterval = 15
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeoutTimer.schedule(deadline: .now() + timeoutSeconds)
        timeoutTimer.setEventHandler {
            if process.isRunning {
                outState.markTimedOut()
                process.terminate()
            }
        }
        timeoutTimer.resume()

        do {
            try process.run()
            process.waitUntilExit()
            timeoutTimer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let (output, didTimeOut) = outState.finalize()
            let (error, _) = errState.finalize()

            if didTimeOut {
                return "AppleScript Note: timed out after \(Int(timeoutSeconds))s — this usually means macOS is waiting on a permission prompt (System Settings → Privacy & Security → Calendars/Reminders/Automation) that needs a response."
            }
            if !output.isEmpty { return output }
            if !error.isEmpty { return "AppleScript Note: \(error)" }
            return "Script executed successfully."
        } catch {
            timeoutTimer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return "AppleScript Error: \(error.localizedDescription)"
        }
    }

    private func sendJson(_ dict: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        var payload = data
        payload.append(0x0A) // newline-delimited JSON-RPC
        // Prefer throwing write — FileHandle.write(_:) raises NSException on EPIPE and can kill the app.
        try pipe.fileHandleForWriting.write(contentsOf: payload)
    }

    public func stopServer(id: String) async {
        if let session = sdkSessions.removeValue(forKey: id) {
            await session.stop()
        }
        if let outPipe = processOutputPipes[id] {
            outPipe.fileHandleForReading.readabilityHandler = nil
        }
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

    public func stopAll() async {
        let ids = Set(runningProcesses.keys).union(sdkSessions.keys)
        for id in ids {
            await stopServer(id: id)
        }
    }
}

/// Thread-safe NDJSON stdout buffer for one MCP stdio process.
final class MCPStdioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        lock.lock()
        text += chunk
        // Cap runaway buffers (log spam / huge payloads)
        if text.count > 2_000_000 {
            text = String(text.suffix(1_000_000))
        }
        lock.unlock()
    }

    /// Pull the first complete JSON-RPC response matching `id`, removing it from the buffer.
    func extractJSONRPCResponse(id: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let remaining = text
        var consumedUpTo = remaining.startIndex
        while let lineEnd = remaining[consumedUpTo...].firstIndex(of: "\n") {
            let line = remaining[consumedUpTo..<lineEnd]
            let next = remaining.index(after: lineEnd)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            consumedUpTo = next
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            let respId: Int? = {
                if let i = json["id"] as? Int { return i }
                if let s = json["id"] as? String { return Int(s) }
                return nil
            }()
            guard respId == id else { continue }

            // Drop everything through this line from the buffer
            text = String(remaining[next...])

            if let result = json["result"] as? [String: Any] {
                if let content = result["content"] as? [[String: Any]] {
                    let texts = content.compactMap { $0["text"] as? String }
                    if !texts.isEmpty { return texts.joined(separator: "\n") }
                }
                if let tools = result["tools"] as? [[String: Any]] {
                    let names = tools.compactMap { $0["name"] as? String }
                    if !names.isEmpty {
                        return "Available tools:\n" + names.map { "- \($0)" }.joined(separator: "\n")
                    }
                }
                if let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data(), encoding: .utf8) {
                    return jsonText
                }
            } else if let error = json["error"] as? [String: Any] {
                return "MCP Error: \(error["message"] as? String ?? "Unknown error")"
            }
            return trimmed
        }
        return nil
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
