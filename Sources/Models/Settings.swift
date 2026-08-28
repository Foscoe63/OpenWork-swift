import Foundation

public enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark = "dark"
    case light = "light"
    case system = "system"
    case midnight = "midnight"
    case cyberpunk = "cyberpunk"
    case monokai = "monokai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "Dark (Default)"
        case .light: return "Light"
        case .system: return "Match System"
        case .midnight: return "Midnight Deep Blue"
        case .cyberpunk: return "Cyberpunk Neon"
        case .monokai: return "Monokai Pro"
        }
    }
}

public enum AccentColorChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case purple = "purple"
    case blue = "blue"
    case green = "green"
    case amber = "amber"
    case coral = "coral"
    case cyan = "cyan"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .purple: return "OpenWork Purple"
        case .blue: return "Electric Blue"
        case .green: return "Emerald Green"
        case .amber: return "Amber Gold"
        case .coral: return "Coral Sunset"
        case .cyan: return "Cyber Cyan"
        }
    }

    public var hex: String {
        switch self {
        case .purple: return "#8B5CF6"
        case .blue: return "#3B82F6"
        case .green: return "#10B981"
        case .amber: return "#F59E0B"
        case .coral: return "#F43F5E"
        case .cyan: return "#06B6D4"
        }
    }
}

public enum TerminalSafetyLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case alwaysAsk = "alwaysAsk"
    case safeOnly = "safeOnly"
    case allowAll = "allowAll"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alwaysAsk: return "Always Ask Confirmation"
        case .safeOnly: return "Allow Safe Read-Only Commands"
        case .allowAll: return "Unrestricted (Developer Mode)"
        }
    }
}

public enum MCPTransportType: String, Codable, CaseIterable, Identifiable, Sendable {
    case stdio = "stdio"
    case httpSse = "http_sse"
    case websocket = "websocket"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stdio: return "Standard IO (stdio Process)"
        case .httpSse: return "HTTP / Server-Sent Events (SSE)"
        case .websocket: return "WebSocket (ws/wss)"
        }
    }

    public var icon: String {
        switch self {
        case .stdio: return "terminal.fill"
        case .httpSse: return "network"
        case .websocket: return "arrow.left.arrow.right"
        }
    }
}

public struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var transportType: MCPTransportType
    public var command: String
    public var args: [String]
    public var workingDirectory: String
    public var url: String
    public var headers: [String: String]
    public var env: [String: String]
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        transportType: MCPTransportType = .stdio,
        command: String = "npx",
        args: [String] = [],
        workingDirectory: String = "",
        url: String = "",
        headers: [String: String] = [:],
        env: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.url = url
        self.headers = headers
        self.env = env
        self.isEnabled = isEnabled
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    // General
    public var defaultWorkspaceId: String
    public var defaultAgentId: String
    public var defaultProviderId: String
    public var defaultModelId: String
    public var autoSaveIntervalSeconds: Int
    public var startOnLogin: Bool

    // Preferences
    public var defaultTemperature: Double
    public var defaultMaxTokens: Int
    public var defaultTopP: Double
    public var defaultReasoningEffort: ReasoningEffort
    public var streamResponses: Bool
    public var autoCompactContext: Bool
    public var contextCompactionThresholdTokens: Int
    public var playNotificationSounds: Bool

    // Permissions
    public var authorizedFolders: [String]
    public var terminalSafetyLevel: TerminalSafetyLevel
    public var allowWebAccess: Bool
    public var sandboxAgentFileSystem: Bool

    // Appearance
    public var theme: AppTheme
    public var accentColor: AccentColorChoice
    public var uiScalePercent: Int // 100%, 110%, etc.
    public var editorFontSize: Int
    public var useTranslucentBackground: Bool
    public var compactSidebar: Bool

    // Multi-Agent & Orchestration
    public var allowSubAgentCreation: Bool
    public var maxGlobalSubAgentDepth: Int
    public var maxAutonomousIterations: Int
    public var showInterAgentCommunicationLogs: Bool
    public var enableAgentCollaborationRoom: Bool

    // MCP & Extensions
    public var mcpServers: [MCPServerConfig]
    public var voiceInputEnabled: Bool
    public var voiceSynthesisEnabled: Bool
    public var speechVoiceIdentifier: String
    public var imageGenerationEnabled: Bool

    // Environment
    public var customEnvironmentVariables: [String: String]

    // Cloud / Sync (mocked / local-first)
    public var cloudSyncEnabled: Bool
    public var cloudControlPlaneUrl: String
    public var cloudAccountEmail: String
    public var cloudOrganizationName: String

    // Updates & Debug
    public var autoCheckForUpdates: Bool
    public var developerMode: Bool
    public var verboseLogging: Bool

    public init(
        defaultWorkspaceId: String = "default-workspace",
        defaultAgentId: String = "lead-assistant",
        defaultProviderId: String = "ollama-local",
        defaultModelId: String = "llama3:latest",
        autoSaveIntervalSeconds: Int = 30,
        startOnLogin: Bool = false,
        defaultTemperature: Double = 0.7,
        defaultMaxTokens: Int = 4096,
        defaultTopP: Double = 1.0,
        defaultReasoningEffort: ReasoningEffort = .medium,
        streamResponses: Bool = true,
        autoCompactContext: Bool = true,
        contextCompactionThresholdTokens: Int = 32000,
        playNotificationSounds: Bool = true,
        authorizedFolders: [String] = [FileManager.default.homeDirectoryForCurrentUser.path],
        terminalSafetyLevel: TerminalSafetyLevel = .safeOnly,
        allowWebAccess: Bool = true,
        sandboxAgentFileSystem: Bool = false,
        theme: AppTheme = .dark,
        accentColor: AccentColorChoice = .purple,
        uiScalePercent: Int = 100,
        editorFontSize: Int = 14,
        useTranslucentBackground: Bool = true,
        compactSidebar: Bool = false,
        allowSubAgentCreation: Bool = true,
        maxGlobalSubAgentDepth: Int = 3,
        maxAutonomousIterations: Int = 25,
        showInterAgentCommunicationLogs: Bool = true,
        enableAgentCollaborationRoom: Bool = true,
        mcpServers: [MCPServerConfig] = [],
        voiceInputEnabled: Bool = false,
        voiceSynthesisEnabled: Bool = false,
        speechVoiceIdentifier: String = "com.apple.speech.synthesis.voice.Alex",
        imageGenerationEnabled: Bool = true,
        customEnvironmentVariables: [String: String] = ["OPENWORK_ENV": "development"],
        cloudSyncEnabled: Bool = false,
        cloudControlPlaneUrl: String = "https://cloud.openwork.ai/api",
        cloudAccountEmail: String = "developer@openwork.local",
        cloudOrganizationName: String = "Personal Workspace",
        autoCheckForUpdates: Bool = true,
        developerMode: Bool = true,
        verboseLogging: Bool = false
    ) {
        self.defaultWorkspaceId = defaultWorkspaceId
        self.defaultAgentId = defaultAgentId
        self.defaultProviderId = defaultProviderId
        self.defaultModelId = defaultModelId
        self.autoSaveIntervalSeconds = autoSaveIntervalSeconds
        self.startOnLogin = startOnLogin
        self.defaultTemperature = defaultTemperature
        self.defaultMaxTokens = defaultMaxTokens
        self.defaultTopP = defaultTopP
        self.defaultReasoningEffort = defaultReasoningEffort
        self.streamResponses = streamResponses
        self.autoCompactContext = autoCompactContext
        self.contextCompactionThresholdTokens = contextCompactionThresholdTokens
        self.playNotificationSounds = playNotificationSounds
        self.authorizedFolders = authorizedFolders
        self.terminalSafetyLevel = terminalSafetyLevel
        self.allowWebAccess = allowWebAccess
        self.sandboxAgentFileSystem = sandboxAgentFileSystem
        self.theme = theme
        self.accentColor = accentColor
        self.uiScalePercent = uiScalePercent
        self.editorFontSize = editorFontSize
        self.useTranslucentBackground = useTranslucentBackground
        self.compactSidebar = compactSidebar
        self.allowSubAgentCreation = allowSubAgentCreation
        self.maxGlobalSubAgentDepth = maxGlobalSubAgentDepth
        self.maxAutonomousIterations = maxAutonomousIterations
        self.showInterAgentCommunicationLogs = showInterAgentCommunicationLogs
        self.enableAgentCollaborationRoom = enableAgentCollaborationRoom
        self.mcpServers = mcpServers
        self.voiceInputEnabled = voiceInputEnabled
        self.voiceSynthesisEnabled = voiceSynthesisEnabled
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.imageGenerationEnabled = imageGenerationEnabled
        self.customEnvironmentVariables = customEnvironmentVariables
        self.cloudSyncEnabled = cloudSyncEnabled
        self.cloudControlPlaneUrl = cloudControlPlaneUrl
        self.cloudAccountEmail = cloudAccountEmail
        self.cloudOrganizationName = cloudOrganizationName
        self.autoCheckForUpdates = autoCheckForUpdates
        self.developerMode = developerMode
        self.verboseLogging = verboseLogging
    }

    public static let `default` = AppSettings()
}
