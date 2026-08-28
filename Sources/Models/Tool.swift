import Foundation

public enum ToolCategory: String, Codable, CaseIterable, Sendable {
    case system = "system"
    case files = "files"
    case terminal = "terminal"
    case web = "web"
    case agents = "agents"
    case custom = "custom"
    case mcp = "mcp"

    public var displayName: String {
        switch self {
        case .system: return "System & Utilities"
        case .files: return "File Management"
        case .terminal: return "Terminal & Shell"
        case .web: return "Web & Search"
        case .agents: return "Multi-Agent Orchestration"
        case .custom: return "Custom Scripts"
        case .mcp: return "Model Context Protocol (MCP)"
        }
    }

    public var icon: String {
        switch self {
        case .system: return "gearshape.fill"
        case .files: return "doc.text.fill"
        case .terminal: return "terminal.fill"
        case .web: return "globe"
        case .agents: return "person.3.fill"
        case .custom: return "curlybraces"
        case .mcp: return "puzzlepiece.extension.fill"
        }
    }
}

public struct Tool: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var displayName: String
    public var description: String
    public var category: ToolCategory
    public var parametersJsonSchema: String
    public var isEnabled: Bool
    public var requiresApproval: Bool
    public var serverUrl: String?

    public init(
        id: String,
        name: String,
        displayName: String,
        description: String,
        category: ToolCategory,
        parametersJsonSchema: String = "{}",
        isEnabled: Bool = true,
        requiresApproval: Bool = false,
        serverUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.category = category
        self.parametersJsonSchema = parametersJsonSchema
        self.isEnabled = isEnabled
        self.requiresApproval = requiresApproval
        self.serverUrl = serverUrl
    }
}

public enum ToolCallStatus: String, Codable, CaseIterable, Sendable {
    case running = "running"
    case success = "success"
    case error = "error"
    case waitingApproval = "waitingApproval"

    public var icon: String {
        switch self {
        case .running: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .waitingApproval: return "hand.raised.fill"
        }
    }
}

public struct ToolCallInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var toolName: String
    public var argumentsJson: String
    public var status: ToolCallStatus
    public var resultOutput: String?
    public var errorMessage: String?
    public var durationMs: Double
    public var executedAt: Date

    public init(
        id: String = UUID().uuidString,
        toolName: String,
        argumentsJson: String,
        status: ToolCallStatus = .running,
        resultOutput: String? = nil,
        errorMessage: String? = nil,
        durationMs: Double = 0,
        executedAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.argumentsJson = argumentsJson
        self.status = status
        self.resultOutput = resultOutput
        self.errorMessage = errorMessage
        self.durationMs = durationMs
        self.executedAt = executedAt
    }
}
