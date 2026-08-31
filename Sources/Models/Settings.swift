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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "MCP Server"
        self.transportType = try container.decodeIfPresent(MCPTransportType.self, forKey: .transportType) ?? .stdio
        self.command = try container.decodeIfPresent(String.self, forKey: .command) ?? "npx"
        self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
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
    public var defaultPresencePenalty: Double
    public var defaultFrequencyPenalty: Double
    public var defaultRepeatPenalty: Double
    public var autoAdjustPenaltiesForLocalModels: Bool
    public var autoLoopBreakerEnabled: Bool
    public var defaultReasoningEffort: ReasoningEffort
    public var streamResponses: Bool
    public var autoCompactContext: Bool
    public var contextCompactionThresholdTokens: Int
    public var playNotificationSounds: Bool

    // Permissions & Shell
    public var authorizedFolders: [String]
    public var terminalSafetyLevel: TerminalSafetyLevel
    public var terminalShell: String // e.g. "/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"
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

    // MLX Local Runtime & External Models (GrizzyClaw & Osaurus Parity)
    public var customMLXModelsDirectory: String
    public var scanHuggingFaceCache: Bool
    public var scanLMStudioModels: Bool
    public var customHFCachePath: String
    public var autoLoadTopMLXModelOnLaunch: Bool
    public var mlxGpuMemoryBudgetRatio: Double
    public var mlxContextLength: Int

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

    public static var defaultMCPServers: [MCPServerConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workspaceMain = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces/Main")
        return [
            MCPServerConfig(
                id: "mcp-filesystem",
                name: "Filesystem MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", workspaceMain],
                workingDirectory: workspaceMain,
                isEnabled: true
            ),
            MCPServerConfig(
                id: "mcp-fetch",
                name: "Web Fetch MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-fetch"],
                isEnabled: true
            ),
            MCPServerConfig(
                id: "mcp-memory",
                name: "Memory Graph MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-memory"],
                isEnabled: true
            ),
            MCPServerConfig(
                id: "mcp-git",
                name: "Git Repository MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-git", "--repository", workspaceMain],
                workingDirectory: workspaceMain,
                isEnabled: true
            ),
            MCPServerConfig(
                id: "mcp-macuse",
                name: "MacUse",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "macuse-mcp"],
                workingDirectory: workspaceMain,
                isEnabled: true
            )
        ]
    }

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
        defaultPresencePenalty: Double = 0.35,
        defaultFrequencyPenalty: Double = 0.35,
        defaultRepeatPenalty: Double = 1.25,
        autoAdjustPenaltiesForLocalModels: Bool = true,
        autoLoopBreakerEnabled: Bool = true,
        defaultReasoningEffort: ReasoningEffort = .medium,
        streamResponses: Bool = true,
        autoCompactContext: Bool = true,
        contextCompactionThresholdTokens: Int = 32000,
        playNotificationSounds: Bool = true,
        authorizedFolders: [String] = [FileManager.default.homeDirectoryForCurrentUser.path],
        terminalSafetyLevel: TerminalSafetyLevel = .safeOnly,
        terminalShell: String = "/bin/zsh",
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
        mcpServers: [MCPServerConfig] = defaultMCPServers,
        voiceInputEnabled: Bool = false,
        voiceSynthesisEnabled: Bool = false,
        speechVoiceIdentifier: String = "com.apple.speech.synthesis.voice.Alex",
        imageGenerationEnabled: Bool = true,
        customMLXModelsDirectory: String = "",
        scanHuggingFaceCache: Bool = true,
        scanLMStudioModels: Bool = true,
        customHFCachePath: String = "",
        autoLoadTopMLXModelOnLaunch: Bool = false,
        mlxGpuMemoryBudgetRatio: Double = 0.75,
        mlxContextLength: Int = 131072,
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
        self.defaultPresencePenalty = defaultPresencePenalty
        self.defaultFrequencyPenalty = defaultFrequencyPenalty
        self.defaultRepeatPenalty = defaultRepeatPenalty
        self.autoAdjustPenaltiesForLocalModels = autoAdjustPenaltiesForLocalModels
        self.autoLoopBreakerEnabled = autoLoopBreakerEnabled
        self.defaultReasoningEffort = defaultReasoningEffort
        self.streamResponses = streamResponses
        self.autoCompactContext = autoCompactContext
        self.contextCompactionThresholdTokens = contextCompactionThresholdTokens
        self.playNotificationSounds = playNotificationSounds
        self.authorizedFolders = authorizedFolders
        self.terminalSafetyLevel = terminalSafetyLevel
        self.terminalShell = terminalShell
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
        self.mcpServers = mcpServers.isEmpty ? AppSettings.defaultMCPServers : mcpServers
        self.voiceInputEnabled = voiceInputEnabled
        self.voiceSynthesisEnabled = voiceSynthesisEnabled
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.imageGenerationEnabled = imageGenerationEnabled
        self.customMLXModelsDirectory = customMLXModelsDirectory
        self.scanHuggingFaceCache = scanHuggingFaceCache
        self.scanLMStudioModels = scanLMStudioModels
        self.customHFCachePath = customHFCachePath
        self.autoLoadTopMLXModelOnLaunch = autoLoadTopMLXModelOnLaunch
        self.mlxGpuMemoryBudgetRatio = mlxGpuMemoryBudgetRatio
        self.mlxContextLength = mlxContextLength
        self.customEnvironmentVariables = customEnvironmentVariables
        self.cloudSyncEnabled = cloudSyncEnabled
        self.cloudControlPlaneUrl = cloudControlPlaneUrl
        self.cloudAccountEmail = cloudAccountEmail
        self.cloudOrganizationName = cloudOrganizationName
        self.autoCheckForUpdates = autoCheckForUpdates
        self.developerMode = developerMode
        self.verboseLogging = verboseLogging
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = AppSettings.default

        self.defaultWorkspaceId = try container.decodeIfPresent(String.self, forKey: .defaultWorkspaceId) ?? def.defaultWorkspaceId
        self.defaultAgentId = try container.decodeIfPresent(String.self, forKey: .defaultAgentId) ?? def.defaultAgentId
        self.defaultProviderId = try container.decodeIfPresent(String.self, forKey: .defaultProviderId) ?? def.defaultProviderId
        self.defaultModelId = try container.decodeIfPresent(String.self, forKey: .defaultModelId) ?? def.defaultModelId
        self.autoSaveIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSaveIntervalSeconds) ?? def.autoSaveIntervalSeconds
        self.startOnLogin = try container.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? def.startOnLogin

        self.defaultTemperature = try container.decodeIfPresent(Double.self, forKey: .defaultTemperature) ?? def.defaultTemperature
        self.defaultMaxTokens = try container.decodeIfPresent(Int.self, forKey: .defaultMaxTokens) ?? def.defaultMaxTokens
        self.defaultTopP = try container.decodeIfPresent(Double.self, forKey: .defaultTopP) ?? def.defaultTopP
        self.defaultPresencePenalty = try container.decodeIfPresent(Double.self, forKey: .defaultPresencePenalty) ?? def.defaultPresencePenalty
        self.defaultFrequencyPenalty = try container.decodeIfPresent(Double.self, forKey: .defaultFrequencyPenalty) ?? def.defaultFrequencyPenalty
        self.defaultRepeatPenalty = try container.decodeIfPresent(Double.self, forKey: .defaultRepeatPenalty) ?? def.defaultRepeatPenalty
        self.autoAdjustPenaltiesForLocalModels = try container.decodeIfPresent(Bool.self, forKey: .autoAdjustPenaltiesForLocalModels) ?? def.autoAdjustPenaltiesForLocalModels
        self.autoLoopBreakerEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoLoopBreakerEnabled) ?? def.autoLoopBreakerEnabled
        self.defaultReasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .defaultReasoningEffort) ?? def.defaultReasoningEffort
        self.streamResponses = try container.decodeIfPresent(Bool.self, forKey: .streamResponses) ?? def.streamResponses
        self.autoCompactContext = try container.decodeIfPresent(Bool.self, forKey: .autoCompactContext) ?? def.autoCompactContext
        self.contextCompactionThresholdTokens = try container.decodeIfPresent(Int.self, forKey: .contextCompactionThresholdTokens) ?? def.contextCompactionThresholdTokens
        self.playNotificationSounds = try container.decodeIfPresent(Bool.self, forKey: .playNotificationSounds) ?? def.playNotificationSounds

        self.authorizedFolders = try container.decodeIfPresent([String].self, forKey: .authorizedFolders) ?? def.authorizedFolders
        self.terminalSafetyLevel = try container.decodeIfPresent(TerminalSafetyLevel.self, forKey: .terminalSafetyLevel) ?? def.terminalSafetyLevel
        self.terminalShell = try container.decodeIfPresent(String.self, forKey: .terminalShell) ?? def.terminalShell
        self.allowWebAccess = try container.decodeIfPresent(Bool.self, forKey: .allowWebAccess) ?? def.allowWebAccess
        self.sandboxAgentFileSystem = try container.decodeIfPresent(Bool.self, forKey: .sandboxAgentFileSystem) ?? def.sandboxAgentFileSystem

        self.theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? def.theme
        self.accentColor = try container.decodeIfPresent(AccentColorChoice.self, forKey: .accentColor) ?? def.accentColor
        self.uiScalePercent = try container.decodeIfPresent(Int.self, forKey: .uiScalePercent) ?? def.uiScalePercent
        self.editorFontSize = try container.decodeIfPresent(Int.self, forKey: .editorFontSize) ?? def.editorFontSize
        self.useTranslucentBackground = try container.decodeIfPresent(Bool.self, forKey: .useTranslucentBackground) ?? def.useTranslucentBackground
        self.compactSidebar = try container.decodeIfPresent(Bool.self, forKey: .compactSidebar) ?? def.compactSidebar

        self.allowSubAgentCreation = try container.decodeIfPresent(Bool.self, forKey: .allowSubAgentCreation) ?? def.allowSubAgentCreation
        self.maxGlobalSubAgentDepth = try container.decodeIfPresent(Int.self, forKey: .maxGlobalSubAgentDepth) ?? def.maxGlobalSubAgentDepth
        self.maxAutonomousIterations = try container.decodeIfPresent(Int.self, forKey: .maxAutonomousIterations) ?? def.maxAutonomousIterations
        self.showInterAgentCommunicationLogs = try container.decodeIfPresent(Bool.self, forKey: .showInterAgentCommunicationLogs) ?? def.showInterAgentCommunicationLogs
        self.enableAgentCollaborationRoom = try container.decodeIfPresent(Bool.self, forKey: .enableAgentCollaborationRoom) ?? def.enableAgentCollaborationRoom

        let decodedMcp = try container.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? []
        self.mcpServers = decodedMcp.isEmpty ? AppSettings.defaultMCPServers : decodedMcp

        self.voiceInputEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceInputEnabled) ?? def.voiceInputEnabled
        self.voiceSynthesisEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceSynthesisEnabled) ?? def.voiceSynthesisEnabled
        self.speechVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier) ?? def.speechVoiceIdentifier
        self.imageGenerationEnabled = try container.decodeIfPresent(Bool.self, forKey: .imageGenerationEnabled) ?? def.imageGenerationEnabled

        self.customMLXModelsDirectory = try container.decodeIfPresent(String.self, forKey: .customMLXModelsDirectory) ?? def.customMLXModelsDirectory
        self.scanHuggingFaceCache = try container.decodeIfPresent(Bool.self, forKey: .scanHuggingFaceCache) ?? def.scanHuggingFaceCache
        self.scanLMStudioModels = try container.decodeIfPresent(Bool.self, forKey: .scanLMStudioModels) ?? def.scanLMStudioModels
        self.customHFCachePath = try container.decodeIfPresent(String.self, forKey: .customHFCachePath) ?? def.customHFCachePath
        self.autoLoadTopMLXModelOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoLoadTopMLXModelOnLaunch) ?? def.autoLoadTopMLXModelOnLaunch
        self.mlxGpuMemoryBudgetRatio = try container.decodeIfPresent(Double.self, forKey: .mlxGpuMemoryBudgetRatio) ?? def.mlxGpuMemoryBudgetRatio
        self.mlxContextLength = try container.decodeIfPresent(Int.self, forKey: .mlxContextLength) ?? def.mlxContextLength

        self.customEnvironmentVariables = try container.decodeIfPresent([String: String].self, forKey: .customEnvironmentVariables) ?? def.customEnvironmentVariables

        self.cloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudSyncEnabled) ?? def.cloudSyncEnabled
        self.cloudControlPlaneUrl = try container.decodeIfPresent(String.self, forKey: .cloudControlPlaneUrl) ?? def.cloudControlPlaneUrl
        self.cloudAccountEmail = try container.decodeIfPresent(String.self, forKey: .cloudAccountEmail) ?? def.cloudAccountEmail
        self.cloudOrganizationName = try container.decodeIfPresent(String.self, forKey: .cloudOrganizationName) ?? def.cloudOrganizationName

        self.autoCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates) ?? def.autoCheckForUpdates
        self.developerMode = try container.decodeIfPresent(Bool.self, forKey: .developerMode) ?? def.developerMode
        self.verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? def.verboseLogging
    }

    public static var `default`: AppSettings {
        AppSettings()
    }
}
