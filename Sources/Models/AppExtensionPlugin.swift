import Foundation

public enum PluginType: String, Codable, CaseIterable, Identifiable, Sendable {
    case mcpServer = "mcp"
    case agentSkill = "skill"
    case customScript = "script"
    case voiceAudio = "voice"
    case mediaVision = "media"
    case workspaceTool = "tool"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mcpServer: return "MCP Server Plugin"
        case .agentSkill: return "Agent Skill / Knowledge"
        case .customScript: return "Custom Shell / Script"
        case .voiceAudio: return "Voice & Speech"
        case .mediaVision: return "Vision & OCR"
        case .workspaceTool: return "Workspace Tool"
        }
    }

    public var icon: String {
        switch self {
        case .mcpServer: return "puzzlepiece.extension.fill"
        case .agentSkill: return "sparkles"
        case .customScript: return "terminal.fill"
        case .voiceAudio: return "waveform"
        case .mediaVision: return "eye.fill"
        case .workspaceTool: return "wrench.and.screwdriver.fill"
        }
    }
}

public enum PluginSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn = "builtIn"
    case mcpRegistry = "mcpRegistry"
    case file = "file"
    case directory = "directory"
    case gitUrl = "gitUrl"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: return "Built-in Core"
        case .mcpRegistry: return "MCP Server Registry"
        case .file: return "Local File (.json / .md / .sh)"
        case .directory: return "Local Folder Plugin"
        case .gitUrl: return "Git / URL Remote"
        case .custom: return "User Configured"
        }
    }

    public var icon: String {
        switch self {
        case .builtIn: return "cube.fill"
        case .mcpRegistry: return "network"
        case .file: return "doc.badge.plus"
        case .directory: return "folder.badge.plus"
        case .gitUrl: return "globe"
        case .custom: return "slider.horizontal.3"
        }
    }
}

public struct AppExtensionPlugin: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var version: String
    public var author: String
    public var pluginType: PluginType
    public var source: PluginSource
    public var isEnabled: Bool
    public var pathOrUrl: String
    public var command: String
    public var envVars: [String: String]
    public var configJson: String
    public var permissions: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        version: String = "1.0.0",
        author: String = "OpenWork Community",
        pluginType: PluginType = .mcpServer,
        source: PluginSource = .custom,
        isEnabled: Bool = true,
        pathOrUrl: String = "",
        command: String = "",
        envVars: [String: String] = [:],
        configJson: String = "{}",
        permissions: [String] = ["filesystem:read"],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.pluginType = pluginType
        self.source = source
        self.isEnabled = isEnabled
        self.pathOrUrl = pathOrUrl
        self.command = command
        self.envVars = envVars
        self.configJson = configJson
        self.permissions = permissions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
