import Foundation
import MCP
import System

/// Official Model Context Protocol Swift SDK session for one stdio server.
/// Spawns the child process and bridges pipes into `StdioTransport` — same architecture
/// as Radiant's `@modelcontextprotocol/sdk` Client + StdioClientTransport.
public actor MCPSDKSession {
    public let config: MCPServerConfig
    private var process: Process?
    private var client: Client?
    private var inPipe: Pipe?
    private var outPipe: Pipe?

    public init(config: MCPServerConfig) {
        self.config = config
    }

    public var isRunning: Bool {
        process?.isRunning == true && client != nil
    }

    @discardableResult
    public func start() async throws -> [MCPToolDefinition] {
        if isRunning, let client {
            let (tools, _) = try await client.listTools()
            return tools.map(Self.mapTool)
        }

        await stop()

        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = FileHandle.nullDevice

        let env = ToolExecutionEngine.defaultEnvironment(custom: config.env)
        let launchArgs = MCPClientManager.sanitizedStdioArgs(
            command: config.command,
            name: config.name,
            args: config.args
        )
        let resolved = MCPClientManager.resolveExecutable(config.command, environment: env)
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

        try process.run()
        try await Task.sleep(nanoseconds: 120_000_000)
        guard process.isRunning else {
            throw MCPSDKError.processExited("MCP '\(config.name)' exited immediately after launch.")
        }

        // Retain process before connect so stop() can kill a hung handshake.
        self.process = process
        self.inPipe = inPipe
        self.outPipe = outPipe

        let inputFD = FileDescriptor(rawValue: outPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: inPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: inputFD, output: outputFD)
        let client = Client(name: "OpenWorkSwift", version: "1.0.0")
        do {
            _ = try await client.connect(transport: transport)
        } catch {
            process.terminate()
            self.process = nil
            self.inPipe = nil
            self.outPipe = nil
            throw error
        }

        self.client = client

        let (tools, _) = try await client.listTools()
        return tools.map(Self.mapTool)
    }

    public func callTool(name: String, arguments: [String: Any]) async throws -> String {
        guard let client else {
            throw MCPSDKError.notConnected
        }
        let valueArgs = try Self.toValueObject(arguments)
        let (content, isError) = try await client.callTool(name: name, arguments: valueArgs)
        let text = content.compactMap { part -> String? in
            switch part {
            case .text(let t, _, _):
                return t
            case .image(_, let mime, _, _):
                return "[image \(mime)]"
            case .audio(_, let mime, _, _):
                return "[audio \(mime)]"
            case .resource(let resource, _, _):
                return "[resource \(resource.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "[resourceLink \(name) \(uri)]"
            }
        }.joined(separator: "\n")
        if isError == true {
            throw MCPSDKError.toolError(text.isEmpty ? "Tool returned isError" : text)
        }
        return text.isEmpty ? "(no output)" : text
    }

    public func stop() async {
        if let client {
            await client.disconnect()
        }
        client = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inPipe = nil
        outPipe = nil
    }

    private static func mapTool(_ t: MCP.Tool) -> MCPToolDefinition {
        var schemaJson: String?
        if let data = try? JSONEncoder().encode(t.inputSchema),
           let s = String(data: data, encoding: .utf8) {
            schemaJson = s
        }
        return MCPToolDefinition(
            name: t.name,
            description: t.description,
            inputSchemaJson: schemaJson
        )
    }

    private static func toValueObject(_ dict: [String: Any]) throws -> [String: Value] {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let value = try JSONDecoder().decode(Value.self, from: data)
        guard case .object(let obj) = value else {
            return [:]
        }
        return obj
    }
}

public enum MCPSDKError: LocalizedError {
    case processExited(String)
    case notConnected
    case toolError(String)

    public var errorDescription: String? {
        switch self {
        case .processExited(let m): return m
        case .notConnected: return "MCP SDK client is not connected."
        case .toolError(let m): return m
        }
    }
}
