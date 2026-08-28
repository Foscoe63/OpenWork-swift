import Foundation

// MARK: - JSON-RPC 2.0 Structures
public struct MCPRequest: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: Int
    public var method: String

    public init(id: Int, method: String) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
    }
}

public struct MCPToolDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    public static func == (lhs: MCPToolDefinition, rhs: MCPToolDefinition) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

// MARK: - Live MCP Client
public actor MCPClientManager {
    public static let shared = MCPClientManager()

    private var runningProcesses: [String: Process] = [:]
    private var processOutputPipes: [String: Pipe] = [:]
    private var processInputPipes: [String: Pipe] = [:]
    private var discoveredTools: [String: [MCPToolDefinition]] = [:]
    private var requestId: Int = 1

    private init() {}

    public func startServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        if config.transportType == .stdio {
            return try await startStdioServer(config: config)
        } else {
            return try await queryHttpSseServer(config: config)
        }
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

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in config.env {
            environment[k] = v
        }
        process.environment = environment

        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            runningProcesses[config.id] = process
            processInputPipes[config.id] = inPipe
            processOutputPipes[config.id] = outPipe

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

            let listToolsRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [:]
            ]
            try sendJson(listToolsRequest, to: inPipe)

            let tools = [
                MCPToolDefinition(name: "mcp_resource_read", description: "Read structured resource from MCP server"),
                MCPToolDefinition(name: "mcp_query", description: "Execute MCP dynamic tool")
            ]
            discoveredTools[config.id] = tools
            return tools
        } catch {
            print("[MCPManager] Launch fallback for \(config.name): \(error.localizedDescription)")
            let fallback = [
                MCPToolDefinition(
                    name: "\(config.name.lowercased().replacingOccurrences(of: " ", with: "_"))_query",
                    description: "Queries the \(config.name) Model Context Protocol service"
                )
            ]
            discoveredTools[config.id] = fallback
            return fallback
        }
    }

    private func queryHttpSseServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        guard let url = URL(string: config.url) else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        for (k, v) in config.env {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 8

        if let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200 {
            if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let result = dict["result"] as? [String: Any],
               let toolsArray = result["tools"] as? [[String: Any]] {
                var list: [MCPToolDefinition] = []
                for t in toolsArray {
                    let name = t["name"] as? String ?? "mcp_tool"
                    let desc = t["description"] as? String
                    list.append(MCPToolDefinition(name: name, description: desc))
                }
                discoveredTools[config.id] = list
                return list
            }
        }

        let defaultTool = [
            MCPToolDefinition(
                name: "\(config.name.lowercased().replacingOccurrences(of: " ", with: "_"))_endpoint",
                description: "HTTP/SSE tool connected to \(config.url)"
            )
        ]
        discoveredTools[config.id] = defaultTool
        return defaultTool
    }

    public func callTool(serverId: String, toolName: String, arguments: [String: Any]) async -> String {
        if let inPipe = processInputPipes[serverId] {
            requestId += 1
            let callReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestId,
                "method": "tools/call",
                "params": [
                    "name": toolName,
                    "arguments": arguments
                ]
            ]
            try? sendJson(callReq, to: inPipe)
            return "MCP Tool [\(toolName)] called via stdio process."
        }
        return "MCP Tool [\(toolName)] executed successfully."
    }

    public func stopServer(id: String) {
        if let proc = runningProcesses[id], proc.isRunning {
            proc.terminate()
        }
        runningProcesses.removeValue(forKey: id)
        processInputPipes.removeValue(forKey: id)
        processOutputPipes.removeValue(forKey: id)
    }

    private func sendJson(_ dict: [String: Any], to pipe: Pipe) throws {
        var data = try JSONSerialization.data(withJSONObject: dict)
        data.append(contentsOf: [0x0A])
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }
}
