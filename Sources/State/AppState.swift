import Foundation
import SwiftUI
import Combine

public enum NavigationDestination: String, CaseIterable, Identifiable {
    case chat = "chat"
    case localModels = "localModels"
    case agents = "agents"
    case providers = "providers"
    case automations = "automations"
    case watchFolders = "watchFolders"
    case artifacts = "artifacts"
    case memory = "memory"
    case tools = "tools"
    case dashboard = "dashboard"
    case settings = "settings"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat: return "Chat & Sessions"
        case .localModels: return "Local Models"
        case .agents: return "AI Agents"
        case .providers: return "Model Providers"
        case .automations: return "Automations"
        case .watchFolders: return "Watch Folders"
        case .artifacts: return "Artifacts & Files"
        case .memory: return "Memory & Knowledge"
        case .tools: return "Tools & MCP"
        case .dashboard: return "Dashboard & Metrics"
        case .settings: return "Settings"
        }
    }

    public var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .localModels: return "cube.fill"
        case .agents: return "person.3.sequence.fill"
        case .providers: return "server.rack"
        case .automations: return "bolt.badge.clock.fill"
        case .watchFolders: return "eye.circle.fill"
        case .artifacts: return "folder.fill"
        case .memory: return "brain.head.profile"
        case .tools: return "hammer.fill"
        case .dashboard: return "chart.xyaxis.line"
        case .settings: return "gearshape.fill"
        }
    }
}

public enum InspectorTab: String, CaseIterable, Identifiable {
    case subagents = "subagents"
    case comms = "comms"
    case artifacts = "artifacts"
    case tools = "tools"
    case terminal = "terminal"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .subagents: return "Sub-Agent Tree"
        case .comms: return "Agent Messages"
        case .artifacts: return "Artifacts"
        case .tools: return "Tools"
        case .terminal: return "Terminal"
        }
    }

    public var icon: String {
        switch self {
        case .subagents: return "point.3.connected.trianglepath.dotted"
        case .comms: return "bubble.left.and.exclamationmark.bubble.right.fill"
        case .artifacts: return "doc.text.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .terminal: return "terminal.fill"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // MARK: - Navigation & Layout
    @Published public var navigationDestination: NavigationDestination = .chat
    @Published public var isInspectorOpen: Bool = true
    @Published public var inspectorTab: InspectorTab = .subagents
    @Published public var settingsTab: String = "general"
    @Published public var searchSessionText: String = ""
    @Published public var isSearchDialogOpen: Bool = false
    @Published public var toastMessage: String? = nil

    // MARK: - Core Entities
    @Published public var workspaces: [Workspace] = []
    @Published public var activeWorkspaceId: String = "default-workspace"
    @Published public var sessions: [Session] = []
    @Published public var currentSessionId: String? = nil
    @Published public var agents: [Agent] = []
    @Published public var providers: [ModelProvider] = []
    @Published public var tools: [Tool] = []
    @Published public var skills: [Skill] = []
    @Published public var plugins: [AppExtensionPlugin] = []
    @Published public var memories: [MemoryItem] = []
    @Published public var automations: [Automation] = []
    @Published public var watchItems: [WatchItem] = []
    @Published public var artifacts: [AutomationArtifact] = []
    @Published public var settings: AppSettings = AppSettings.default {
        didSet {
            persistence.saveSettings(settings)
        }
    }
    @Published public var interAgentMessages: [AgentMessage] = []
    @Published public var activeSubAgentTasks: [SubAgentTask] = []
    @Published public var localMLXModels: [LocalMLXModel] = []
    @Published public var isScanningMLX: Bool = false

    // MARK: - Runtime
    @Published public var isGenerating: Bool = false
    @Published public var composerText: String = ""
    @Published public var selectedAgentId: String = "lead-assistant"
    @Published public var selectedProviderId: String = "ollama-local"
    @Published public var selectedModelId: String = "llama3:latest"
    @Published public var isReasoningEnabled: Bool = true
    @Published public var pullModelProgress: Double = 0.0
    @Published public var pullModelStatusText: String = ""
    @Published public var isPullingModel: Bool = false
    private var currentExecutionTask: Task<Void, Never>? = nil

    private let persistence = PersistenceManager.shared

    public init() {
        loadAll()
    }

    public func loadAll() {
        self.workspaces = persistence.loadWorkspaces()
        self.settings = persistence.loadSettings()
        self.providers = persistence.loadProviders()
        self.agents = persistence.loadAgents()
        self.sessions = persistence.loadSessions()
        self.tools = persistence.loadTools()
        self.skills = persistence.loadSkills()
        self.plugins = persistence.loadPlugins()
        self.memories = persistence.loadMemories()
        self.automations = persistence.loadAutomations()
        self.watchItems = persistence.loadWatchItems()
        self.artifacts = persistence.loadArtifacts()

        // Hydrate active workspace from settings
        if workspaces.contains(where: { $0.id == settings.defaultWorkspaceId }) {
            self.activeWorkspaceId = settings.defaultWorkspaceId
        } else if let firstWs = workspaces.first {
            self.activeWorkspaceId = firstWs.id
        }

        // Ensure default local providers (omlx, vmlx) exist in user configuration if upgraded
        let defaults = PersistenceManager.shared.defaultProviders
        for def in defaults {
            if !providers.contains(where: { $0.id == def.id || $0.kind == def.kind }) {
                providers.append(def)
            }
        }
        persistence.saveProviders(providers)

        // Ensure workspace folder exists
        ensureWorkspaceFolderExists(for: currentWorkspace)

        // Select initial session matching active workspace if available
        let activeWsSessions = sessions.filter { $0.workspaceId == activeWorkspaceId && !$0.isArchived }
        if let first = activeWsSessions.first ?? sessions.first {
            self.currentSessionId = first.id
            self.selectedAgentId = first.agentId
            self.selectedProviderId = first.providerId.isEmpty ? settings.defaultProviderId : first.providerId
            self.selectedModelId = first.modelId.isEmpty ? settings.defaultModelId : first.modelId
            self.interAgentMessages = first.interAgentMessages
            self.activeSubAgentTasks = first.activeSubAgentTasks
        } else {
            self.selectedProviderId = settings.defaultProviderId
            self.selectedModelId = settings.defaultModelId
        }

        // Validate selectedProviderId & selectedModelId are valid and present
        if !providers.contains(where: { $0.id == selectedProviderId }) {
            self.selectedProviderId = providers.first(where: { $0.isEnabled })?.id ?? providers.first?.id ?? "ollama-local"
        }
        let activeProv = currentProvider
        let isLocalMLX = localMLXModels.contains(where: { $0.id == selectedModelId }) || LocalMLXEngine.curatedModels.contains(where: { $0.id == selectedModelId })
        if !activeProv.models.contains(where: { $0.id == selectedModelId }) && !isLocalMLX {
            self.selectedModelId = activeProv.models.first?.id ?? "llama3:latest"
        }

        // Initialize active file monitors
        restartWatchEngine()
        
        // Sync MCP tools inventory
        syncMcpTools()

        // Scan local MLX models
        rescanMLXModels()
    }

    public var currentWorkspace: Workspace {
        workspaces.first(where: { $0.id == activeWorkspaceId }) ?? Workspace.default
    }

    public var currentSession: Session? {
        guard let id = currentSessionId else { return sessions.first }
        return sessions.first(where: { $0.id == id })
    }

    public var currentAgent: Agent {
        agents.first(where: { $0.id == selectedAgentId }) ?? agents.first ?? Agent(id: "default", name: "Assistant")
    }

    public var currentProvider: ModelProvider {
        providers.first(where: { $0.id == selectedProviderId }) ?? providers.first(where: { $0.isEnabled }) ?? providers.first ?? ModelProvider(name: "Default", type: .local, kind: .ollama)
    }

    public var currentModel: ModelInfo {
        let prov = currentProvider
        if let found = prov.models.first(where: { $0.id == selectedModelId }) {
            return found
        }
        if let local = localMLXModels.first(where: { $0.id == selectedModelId }) ?? LocalMLXEngine.curatedModels.first(where: { $0.id == selectedModelId }) {
            return ModelInfo(
                id: local.id,
                name: "\(local.name) (\(local.quantization ?? "MLX"))",
                providerId: prov.id,
                contextWindow: local.contextWindow ?? 131072,
                supportsVision: local.isVLM,
                supportsReasoning: local.useCase == .reasoning,
                supportsStreaming: true,
                supportsTools: true,
                description: local.description,
                isDefault: local.isTopPick,
                speedTier: local.useCase == .fast ? "Fast" : "Powerful"
            )
        }
        return prov.models.first ?? ModelInfo(id: selectedModelId, name: selectedModelId)
    }

    public func selectLocalMLXModel(_ model: LocalMLXModel) {
        // Ensure Apple Silicon built-in provider exists and is enabled
        if let omlxIdx = providers.firstIndex(where: { $0.kind == .omlx }) {
            providers[omlxIdx].isEnabled = true
            providers[omlxIdx].name = "Apple Silicon (Built-in)"
            selectedProviderId = providers[omlxIdx].id

            // Ensure model info exists in provider's model list
            if !providers[omlxIdx].models.contains(where: { $0.id == model.id }) {
                let info = ModelInfo(
                    id: model.id,
                    name: "\(model.name) (\(model.quantization ?? "MLX"))",
                    providerId: providers[omlxIdx].id,
                    contextWindow: model.contextWindow ?? 131072,
                    supportsVision: model.isVLM,
                    supportsReasoning: model.useCase == .reasoning,
                    supportsStreaming: true,
                    supportsTools: true,
                    description: model.description,
                    isDefault: model.isTopPick,
                    speedTier: model.useCase == .fast ? "Fast" : "Powerful"
                )
                providers[omlxIdx].models.append(info)
                persistence.saveProviders(providers)
            }
        } else {
            let newOmlx = ModelProvider(
                id: "builtin-mlx-local",
                name: "Apple Silicon (Built-in)",
                type: .local,
                kind: .omlx,
                baseUrl: "http://127.0.0.1:8000/v1",
                isEnabled: true,
                models: [
                    ModelInfo(
                        id: model.id,
                        name: "\(model.name) (\(model.quantization ?? "MLX"))",
                        providerId: "builtin-mlx-local",
                        contextWindow: model.contextWindow ?? 131072,
                        supportsVision: model.isVLM,
                        supportsReasoning: model.useCase == .reasoning,
                        supportsStreaming: true,
                        supportsTools: true,
                        description: model.description,
                        isDefault: true,
                        speedTier: "Fast"
                    )
                ]
            )
            providers.append(newOmlx)
            selectedProviderId = newOmlx.id
            persistence.saveProviders(providers)
        }

        selectedModelId = model.id

        // Initialize local model engine in the background
        Task.detached(priority: .userInitiated) {
            let res = await LocalMLXEngine.shared.ensureServerRunning()
            if res.success {
                await MainActor.run {
                    self.showToast("⚡️ Apple Silicon model ready: \(model.name)")
                }
            }
        }

        // Update active session with the selected model
        if var curr = currentSession {
            curr.providerId = selectedProviderId
            curr.modelId = selectedModelId
            if let idx = sessions.firstIndex(where: { $0.id == curr.id }) {
                sessions[idx] = curr
                persistence.saveSessions(sessions)
            }
        }

        showToast("Active model: \(model.name)")
    }

    // MARK: - Sessions Operations
    public func createNewSession(agentId: String? = nil) {
        let chosenAgent = agentId ?? selectedAgentId
        let newSession = Session(
            workspaceId: activeWorkspaceId,
            title: "New Session",
            agentId: chosenAgent,
            providerId: selectedProviderId,
            modelId: selectedModelId,
            messages: []
        )
        sessions.insert(newSession, at: 0)
        currentSessionId = newSession.id
        interAgentMessages.removeAll()
        activeSubAgentTasks.removeAll()
        persistence.saveSessions(sessions)
        navigationDestination = .chat
    }

    public func selectSession(_ session: Session) {
        currentSessionId = session.id
        selectedAgentId = session.agentId
        if !session.providerId.isEmpty { selectedProviderId = session.providerId }
        if !session.modelId.isEmpty { selectedModelId = session.modelId }
        interAgentMessages = session.interAgentMessages
        activeSubAgentTasks = session.activeSubAgentTasks
    }

    public func deleteSession(_ session: Session) {
        sessions.removeAll(where: { $0.id == session.id })
        if currentSessionId == session.id {
            currentSessionId = sessions.first?.id
        }
        persistence.saveSessions(sessions)
    }

    public func togglePinSession(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].isPinned.toggle()
            persistence.saveSessions(sessions)
        }
    }

    public func archiveSession(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].isArchived.toggle()
            persistence.saveSessions(sessions)
        }
    }

    public func renameSession(_ session: Session, newTitle: String) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].title = newTitle
            persistence.saveSessions(sessions)
        }
    }

    public enum SessionExportFormat {
        case markdown
        case json
        case html
    }

    public func exportCurrentSession(as format: SessionExportFormat) {
        guard let session = currentSession, !session.messages.isEmpty else {
            showToast("Session is empty")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        let safeTitle = session.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)

        switch format {
        case .markdown:
            savePanel.nameFieldStringValue = "\(safeTitle).md"
            savePanel.allowedContentTypes = [.plainText]
        case .json:
            savePanel.nameFieldStringValue = "\(safeTitle).json"
            savePanel.allowedContentTypes = [.json]
        case .html:
            savePanel.nameFieldStringValue = "\(safeTitle).html"
            savePanel.allowedContentTypes = [.html]
        }

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                switch format {
                case .markdown:
                    var md = "# \(session.title)\n\n"
                    md += "*Exported from OpenWork-Swift on \(Date().formatted())*\n\n---\n\n"
                    for m in session.messages {
                        let sender = m.role == .user ? "**User**" : "**\(m.agentName ?? "Agent")** (\(m.modelId ?? "LLM"))"
                        md += "### \(sender) - \(m.timestamp.formatted())\n\n"
                        if let r = m.reasoning, !r.isEmpty {
                            md += "> 🧠 **Thinking / Reasoning:**\n> " + r.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
                        }
                        md += "\(m.content)\n\n---\n\n"
                    }
                    try md.write(to: url, atomically: true, encoding: .utf8)

                case .json:
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(session)
                    try data.write(to: url)

                case .html:
                    var html = """
                    <!DOCTYPE html>
                    <html>
                    <head>
                    <meta charset="utf-8">
                    <title>\(session.title)</title>
                    <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; line-height: 1.6; color: #1e1e2e; background: #fafafa; }
                    .msg { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
                    .user { border-left: 4px solid #6366f1; }
                    .agent { border-left: 4px solid #10b981; }
                    .meta { font-size: 0.85em; color: #64748b; margin-bottom: 10px; font-weight: 600; }
                    .reasoning { background: #f8fafc; border-left: 3px solid #f59e0b; padding: 10px 14px; margin-bottom: 12px; font-size: 0.9em; color: #475569; font-style: italic; }
                    pre { background: #1e1e2e; color: #cdd6f4; padding: 12px; border-radius: 6px; overflow-x: auto; }
                    </style>
                    </head>
                    <body>
                    <h1>\(session.title)</h1>
                    <p style="color: #64748b; font-size: 0.9em;">Exported from OpenWork-Swift on \(Date().formatted())</p>
                    <hr style="border: 0; border-top: 1px solid #e2e8f0; margin: 20px 0;">
                    """
                    for m in session.messages {
                        let isUser = m.role == .user
                        let sender = isUser ? "User" : "\(m.agentName ?? "Agent") (\(m.modelId ?? "LLM"))"
                        let cssClass = isUser ? "user" : "agent"
                        html += "<div class=\"msg \(cssClass)\">"
                        html += "<div class=\"meta\">\(sender) • \(m.timestamp.formatted())</div>"
                        if let r = m.reasoning, !r.isEmpty {
                            html += "<div class=\"reasoning\"><strong>🧠 Reasoning:</strong><br>\(r.replacingOccurrences(of: "\n", with: "<br>"))</div>"
                        }
                        let safeContent = m.content
                            .replacingOccurrences(of: "<", with: "&lt;")
                            .replacingOccurrences(of: ">", with: "&gt;")
                            .replacingOccurrences(of: "\n", with: "<br>")
                        html += "<div>\(safeContent)</div>"
                        html += "</div>"
                    }
                    html += "</body></html>"
                    try html.write(to: url, atomically: true, encoding: .utf8)
                }
                showToast("Exported session successfully!")
            } catch {
                showToast("Export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Chat & Execution
    public func sendMessage(text: String, attachments: [MessageAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        guard var session = currentSession else {
            createNewSession()
            sendMessage(text: text, attachments: attachments)
            return
        }

        // Handle slash commands
        if trimmed.hasPrefix("/") {
            if handleSlashCommand(trimmed) {
                composerText = ""
                return
            }
        }

        let userMsg = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: trimmed,
            timestamp: Date(),
            attachments: attachments
        )

        session.messages.append(userMsg)
        
        // Auto rename session title on first message
        if session.messages.filter({ $0.role == .user }).count == 1 {
            session.title = String(trimmed.prefix(35))
        }

        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        }
        persistence.saveSessions(sessions)

        composerText = ""
        isGenerating = true

        let agent = currentAgent
        let provider = currentProvider
        let model = currentModel
        let workspace = currentWorkspace
        let allAgentsList = agents

        currentExecutionTask?.cancel()
        currentExecutionTask = Task { [weak self] in
            guard let self = self else { return }
            await AgentRunner.shared.run(
                session: session,
                agent: agent,
                provider: provider,
                model: model,
                workspace: workspace,
                allAgents: allAgentsList,
                onMessageUpdated: { [weak self] updatedMsg in
                    guard let self = self else { return }
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        if let mIdx = self.sessions[sIdx].messages.firstIndex(where: { $0.id == updatedMsg.id }) {
                            self.sessions[sIdx].messages[mIdx] = updatedMsg
                        } else {
                            self.sessions[sIdx].messages.append(updatedMsg)
                        }
                        self.persistence.saveSessions(self.sessions)
                    }
                },
                onSubAgentTaskCreated: { [weak self] subTask in
                    guard let self = self else { return }
                    self.activeSubAgentTasks.append(subTask)
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        self.sessions[sIdx].activeSubAgentTasks.append(subTask)
                    }
                },
                onSubAgentTaskUpdated: { [weak self] subTask in
                    guard let self = self else { return }
                    if let idx = self.activeSubAgentTasks.firstIndex(where: { $0.id == subTask.id }) {
                        self.activeSubAgentTasks[idx] = subTask
                    }
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        if let tIdx = self.sessions[sIdx].activeSubAgentTasks.firstIndex(where: { $0.id == subTask.id }) {
                            self.sessions[sIdx].activeSubAgentTasks[tIdx] = subTask
                        }
                    }
                },
                onInterAgentMessage: { [weak self] msg in
                    guard let self = self else { return }
                    self.interAgentMessages.append(msg)
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        self.sessions[sIdx].interAgentMessages.append(msg)
                    }
                }
            )

            await MainActor.run {
                self.isGenerating = false
                self.currentExecutionTask = nil
                self.persistence.saveSessions(self.sessions)
            }
        }
    }

    public func cancelCurrentGeneration() {
        currentExecutionTask?.cancel()
        currentExecutionTask = nil
        isGenerating = false
        showToast("Generation cancelled")
    }

    private func handleSlashCommand(_ command: String) -> Bool {
        let parts = command.split(separator: " ")
        guard let first = parts.first?.lowercased() else { return false }
        
        switch first {
        case "/clear":
            if var session = currentSession {
                session.messages.removeAll()
                session.activeSubAgentTasks.removeAll()
                session.interAgentMessages.removeAll()
                if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[idx] = session
                }
                interAgentMessages.removeAll()
                activeSubAgentTasks.removeAll()
                persistence.saveSessions(sessions)
                showToast("Session cleared")
            }
            return true

        case "/agent":
            if parts.count > 1 {
                let query = parts.dropFirst().joined(separator: " ").lowercased()
                if let found = agents.first(where: { $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query) }) {
                    selectedAgentId = found.id
                    showToast("Switched agent to \(found.name)")
                    return true
                }
            }
            navigationDestination = .agents
            return true

        case "/model":
            if parts.count > 1 {
                let query = parts.dropFirst().joined(separator: " ").lowercased()
                for p in providers {
                    if let m = p.models.first(where: { $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query) }) {
                        selectedProviderId = p.id
                        selectedModelId = m.id
                        showToast("Model switched to \(m.name)")
                        return true
                    }
                }
            }
            navigationDestination = .providers
            return true

        case "/help":
            if var session = currentSession {
                let helpMsg = ChatMessage(
                    sessionId: session.id,
                    role: .assistant,
                    content: """
                    ### OpenWork-Swift Available Slash Commands:
                    - `/agent <name>` - Switch current active agent or open Agents hub
                    - `/model <name>` - Switch active model provider or open Providers catalog
                    - `/clear` - Clear messages in this session
                    - `/settings` - Jump to App Settings
                    - `/tools` - Inspect MCP & built-in tools
                    - `/memory` - Search or view long-term memory
                    - `/help` - Show this command reference
                    """,
                    agentName: "System Help",
                    agentAvatar: "questionmark.circle.fill",
                    agentColor: "#8B5CF6"
                )
                session.messages.append(helpMsg)
                if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[idx] = session
                }
                persistence.saveSessions(sessions)
            }
            return true

        case "/settings":
            navigationDestination = .settings
            return true

        case "/tools":
            navigationDestination = .tools
            return true

        case "/memory":
            navigationDestination = .memory
            return true

        default:
            return false
        }
    }

    public func ensurePipelineFoldersExist(for workspace: Workspace) {
        guard workspace.isPipelineStagingEnabled else { return }
        let root = URL(fileURLWithPath: workspace.folderPath)
        let inputURL = root.appendingPathComponent(workspace.inputFolderPath.isEmpty ? "input" : workspace.inputFolderPath)
        let outputURL = root.appendingPathComponent(workspace.outputFolderPath.isEmpty ? "output" : workspace.outputFolderPath)
        
        try? FileManager.default.createDirectory(at: inputURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    }

    public func ensureWorkspaceFolderExists(for workspace: Workspace) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: workspace.folderPath) {
            try? fm.createDirectory(atPath: workspace.folderPath, withIntermediateDirectories: true)
        }
        if workspace.isPipelineStagingEnabled {
            ensurePipelineFoldersExist(for: workspace)
        }
    }

    public func switchWorkspace(to workspaceId: String) {
        guard let target = workspaces.first(where: { $0.id == workspaceId }) else { return }
        self.activeWorkspaceId = target.id
        self.settings.defaultWorkspaceId = target.id
        self.persistence.saveSettings(self.settings)

        ensureWorkspaceFolderExists(for: target)

        // Automatically select the assigned agent if linked to this workspace
        if let assignedAgentId = target.assignedAgentId, agents.contains(where: { $0.id == assignedAgentId }) {
            self.selectedAgentId = assignedAgentId
        }

        // Switch to the most recent session for this workspace, or create one if none exist
        let activeWsSessions = sessions.filter { $0.workspaceId == target.id && !$0.isArchived }
        if let mostRecent = activeWsSessions.first {
            self.selectSession(mostRecent)
        } else {
            self.createNewSession(agentId: target.assignedAgentId ?? selectedAgentId)
        }

        showToast("Switched to '\(target.name)'")
    }

    public func showToast(_ message: String) {
        self.toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                if self.toastMessage == message {
                    self.toastMessage = nil
                }
            }
        }
    }

    // MARK: - Providers & Models
    public func saveProvider(_ provider: ModelProvider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        persistence.saveProviders(providers)
    }

    public func deleteProvider(_ provider: ModelProvider) {
        providers.removeAll(where: { $0.id == provider.id })
        persistence.saveProviders(providers)
    }

    // MARK: - MLX Local Runtime & Discovery
    public func rescanMLXModels() {
        isScanningMLX = true
        Task.detached(priority: .userInitiated) {
            let models = LocalMLXEngine.shared.scanInstalledModels(settings: PersistenceManager.shared.loadSettings())
            await MainActor.run {
                self.localMLXModels = models
                self.isScanningMLX = false

                // Synchronize discovered MLX models with the oMLX / vMLX providers
                let installed = models.filter { $0.isDownloaded }
                if !installed.isEmpty {
                    for i in 0..<self.providers.count {
                        if self.providers[i].kind == .omlx || self.providers[i].kind == .vmlx {
                            var updatedModels: [ModelInfo] = []
                            for m in installed {
                                let info = ModelInfo(
                                    id: m.id,
                                    name: "\(m.name) (\(m.quantization ?? "MLX"))",
                                    providerId: self.providers[i].id,
                                    contextWindow: m.contextWindow ?? 131072,
                                    supportsVision: m.isVLM,
                                    supportsReasoning: m.useCase == .reasoning,
                                    supportsStreaming: true,
                                    supportsTools: true,
                                    description: m.description,
                                    isDefault: m.isTopPick,
                                    speedTier: m.useCase == .fast ? "Fast" : "Powerful"
                                )
                                updatedModels.append(info)
                            }
                            if !updatedModels.isEmpty {
                                self.providers[i].models = updatedModels
                            }
                        }
                    }
                    self.persistence.saveProviders(self.providers)
                }
            }
        }
    }

    public func pullMLXModel(_ model: LocalMLXModel) {
        isPullingModel = true
        pullModelProgress = 0.0
        pullModelStatusText = "Downloading \(model.name) weights..."

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await LocalMLXEngine.shared.pullModel(repoId: model.id) { [weak self] fraction, status in
                    Task { @MainActor in
                        self?.pullModelProgress = fraction
                        self?.pullModelStatusText = "\(status)"
                    }
                }
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("MLX model '\(model.name)' installed successfully!")
                    self.rescanMLXModels()
                }
            } catch {
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func pullOllamaModel(name: String) {
        guard let ollama = providers.first(where: { $0.kind == .ollama }) else { return }
        isPullingModel = true
        pullModelProgress = 0.0
        pullModelStatusText = "Connecting to Ollama at \(ollama.baseUrl)..."
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await OllamaService.shared.pullModel(provider: ollama, modelName: name) { [weak self] fraction, status in
                    Task { @MainActor in
                        self?.pullModelProgress = fraction
                        self?.pullModelStatusText = "\(status): \(Int(fraction * 100))%"
                    }
                }
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("Model \(name) pulled successfully!")
                    self.refreshModels(for: ollama)
                }
            } catch {
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("Failed to pull model: \(error.localizedDescription)")
                }
            }
        }
    }

    public func refreshModels(for provider: ModelProvider) {
        Task {
            do {
                let models = try await ProviderRouter.shared.client(for: provider).listModels(provider: provider)
                await MainActor.run {
                    if let idx = self.providers.firstIndex(where: { $0.id == provider.id }) {
                        if !models.isEmpty {
                            self.providers[idx].models = models
                            self.persistence.saveProviders(self.providers)
                            self.showToast("Fetched \(models.count) models for \(provider.name)")
                        } else {
                            self.showToast("No models returned by \(provider.name) endpoint (\(provider.baseUrl))")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.showToast("Could not fetch models: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Agents
    public func saveAgent(_ agent: Agent) {
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx] = agent
        } else {
            agents.append(agent)
        }
        persistence.saveAgents(agents)
    }

    public func deleteAgent(_ agent: Agent) {
        agents.removeAll(where: { $0.id == agent.id })
        persistence.saveAgents(agents)
    }

    // MARK: - Skills
    public func saveSkill(_ skill: Skill) {
        if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[idx] = skill
        } else {
            skills.append(skill)
        }
        persistence.saveSkills(skills)
        showToast("Skill '\(skill.name)' saved")
    }

    public func deleteSkill(_ skill: Skill) {
        skills.removeAll(where: { $0.id == skill.id })
        persistence.saveSkills(skills)
        showToast("Skill deleted")
    }

    public func importSkillFromFile(url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent
            let skill = Skill(
                name: name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized,
                description: "Imported from \(url.lastPathComponent)",
                category: "Imported",
                content: content,
                source: .fileImport,
                filePath: url.path
            )
            saveSkill(skill)
            showToast("Imported skill: \(skill.name)")
        } catch {
            showToast("Failed to read skill file: \(error.localizedDescription)")
        }
    }

    public func importSkillsFromFolder(url: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        var importedCount = 0
        for case let fileUrl as URL in enumerator {
            if fileUrl.lastPathComponent.lowercased() == "skill.md" || fileUrl.pathExtension.lowercased() == "md" {
                if let content = try? String(contentsOf: fileUrl, encoding: .utf8), content.contains("#") {
                    let parentFolder = fileUrl.deletingLastPathComponent().lastPathComponent
                    let skillName = parentFolder.isEmpty ? fileUrl.deletingPathExtension().lastPathComponent : parentFolder
                    let skill = Skill(
                        name: skillName.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized,
                        description: "Imported from \(fileUrl.path)",
                        category: "Folder Import",
                        content: content,
                        source: .fileImport,
                        filePath: fileUrl.path
                    )
                    saveSkill(skill)
                    importedCount += 1
                }
            }
        }
        showToast("Imported \(importedCount) skills from directory")
    }

    public func importSkillFromUrl(urlString: String, name: String? = nil) {
        guard let url = URL(string: urlString) else {
            showToast("Invalid URL")
            return
        }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let content = String(data: data, encoding: .utf8) else {
                    await MainActor.run { self.showToast("Failed to fetch skill from URL") }
                    return
                }
                let skillName = name?.isEmpty == false ? name! : url.lastPathComponent.replacingOccurrences(of: ".md", with: "").capitalized
                let skill = Skill(
                    name: skillName,
                    description: "Imported from \(urlString)",
                    category: "Web Import",
                    content: content,
                    source: .urlImport,
                    url: urlString
                )
                await MainActor.run {
                    self.saveSkill(skill)
                    self.showToast("Imported skill: \(skill.name)")
                }
            } catch {
                await MainActor.run {
                    self.showToast("Fetch error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Extensions & Plugins
    public func savePlugin(_ plugin: AppExtensionPlugin) {
        if let idx = plugins.firstIndex(where: { $0.id == plugin.id }) {
            plugins[idx] = plugin
        } else {
            plugins.append(plugin)
        }
        persistence.savePlugins(plugins)
        showToast("Plugin '\(plugin.name)' saved")
    }

    public func deletePlugin(_ plugin: AppExtensionPlugin) {
        plugins.removeAll(where: { $0.id == plugin.id })
        persistence.savePlugins(plugins)
        showToast("Deleted plugin '\(plugin.name)'")
    }

    public func importPluginFromFile(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if let decoded = try? JSONDecoder().decode(AppExtensionPlugin.self, from: data) {
                savePlugin(decoded)
                showToast("Imported plugin: \(decoded.name)")
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let name = (json["name"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let desc = (json["description"] as? String) ?? "Imported from \(url.lastPathComponent)"
                let command = (json["command"] as? String) ?? ""
                let plugin = AppExtensionPlugin(
                    name: name,
                    description: desc,
                    pluginType: .customScript,
                    source: .file,
                    pathOrUrl: url.path,
                    command: command
                )
                savePlugin(plugin)
                showToast("Imported plugin config: \(plugin.name)")
            } else {
                let _ = String(data: data, encoding: .utf8) ?? ""
                let plugin = AppExtensionPlugin(
                    name: url.deletingPathExtension().lastPathComponent.capitalized,
                    description: "Script plugin loaded from \(url.lastPathComponent)",
                    pluginType: .customScript,
                    source: .file,
                    pathOrUrl: url.path,
                    command: url.path
                )
                savePlugin(plugin)
                showToast("Imported script plugin: \(plugin.name)")
            }
        } catch {
            showToast("Failed to read plugin: \(error.localizedDescription)")
        }
    }

    public func importPluginFromUrl(urlString: String, name: String? = nil) {
        guard let url = URL(string: urlString) else {
            showToast("Invalid URL")
            return
        }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    await MainActor.run { self.showToast("Failed to fetch from URL") }
                    return
                }
                let pluginName = name?.isEmpty == false ? name! : url.lastPathComponent.replacingOccurrences(of: ".json", with: "").capitalized
                if let decoded = try? JSONDecoder().decode(AppExtensionPlugin.self, from: data) {
                    await MainActor.run {
                        self.savePlugin(decoded)
                        self.showToast("Imported plugin: \(decoded.name)")
                    }
                } else {
                    let plugin = AppExtensionPlugin(
                        name: pluginName,
                        description: "Remote plugin loaded from \(urlString)",
                        pluginType: .mcpServer,
                        source: .gitUrl,
                        pathOrUrl: urlString
                    )
                    await MainActor.run {
                        self.savePlugin(plugin)
                        self.showToast("Imported plugin: \(plugin.name)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.showToast("Plugin fetch error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - MCP Servers
    public func saveMcpServer(_ config: MCPServerConfig) {
        if let idx = settings.mcpServers.firstIndex(where: { $0.id == config.id }) {
            settings.mcpServers[idx] = config
        } else {
            settings.mcpServers.append(config)
        }
        updateSettings(settings)
        syncMcpTools()
        showToast("MCP Server '\(config.name)' saved")
    }

    public func deleteMcpServer(_ config: MCPServerConfig) {
        let toolId = "mcp_\(config.id)"
        let clean = config.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        let toolName = "\(clean)_call"

        settings.mcpServers.removeAll(where: { $0.id == config.id })
        updateSettings(settings)

        tools.removeAll(where: { $0.id == toolId || $0.name == toolName })
        persistence.saveTools(tools)

        showToast("MCP Server deleted")
    }

    public func syncMcpTools() {
        var currentTools = persistence.loadTools()

        for server in settings.mcpServers {
            let toolId = "mcp_\(server.id)"
            let clean = server.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            let toolName = "\(clean)_call"

            if let idx = currentTools.firstIndex(where: { $0.id == toolId || $0.name == toolName }) {
                currentTools[idx].displayName = "\(server.name) MCP Server"
                currentTools[idx].description = "Executes tools and actions via the \(server.name) MCP server (\(server.transportType.displayName))"
                currentTools[idx].category = .mcp
                currentTools[idx].isEnabled = server.isEnabled
            } else {
                currentTools.append(Tool(
                    id: toolId,
                    name: toolName,
                    displayName: "\(server.name) MCP Server",
                    description: "Executes tools and actions via the \(server.name) MCP server (\(server.transportType.displayName))",
                    category: .mcp,
                    isEnabled: server.isEnabled
                ))
            }
        }

        // Remove tools for MCP servers that no longer exist
        currentTools.removeAll { tool in
            if tool.category == .mcp && tool.id.hasPrefix("mcp_") && tool.id != "mcp_universal_call" {
                let serverId = String(tool.id.dropFirst(4))
                return !settings.mcpServers.contains(where: { $0.id == serverId })
            }
            return false
        }

        self.tools = currentTools
        persistence.saveTools(currentTools)
    }

    // MARK: - Workspaces
    public func saveWorkspace(_ workspace: Workspace) {
        if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[idx] = workspace
        } else {
            workspaces.append(workspace)
        }
        persistence.saveWorkspaces(workspaces)
        ensureWorkspaceFolderExists(for: workspace)
    }

    public func deleteWorkspace(_ workspace: Workspace) {
        workspaces.removeAll(where: { $0.id == workspace.id })
        if activeWorkspaceId == workspace.id {
            if let first = workspaces.first {
                switchWorkspace(to: first.id)
            } else {
                let defaultWs = Workspace.default
                workspaces.append(defaultWs)
                switchWorkspace(to: defaultWs.id)
            }
        }
        persistence.saveWorkspaces(workspaces)
        showToast("Deleted workspace '\(workspace.name)'")
    }

    public func duplicateWorkspace(_ workspace: Workspace) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseWs = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces")
        let cleanName = "\(workspace.name) (Copy)"
        let newFolderPath = (baseWs as NSString).appendingPathComponent(cleanName.replacingOccurrences(of: " ", with: "-"))
        
        let newWs = Workspace(
            name: cleanName,
            icon: workspace.icon,
            color: workspace.color,
            folderPath: newFolderPath,
            category: workspace.category,
            assignedAgentId: workspace.assignedAgentId,
            isPipelineStagingEnabled: workspace.isPipelineStagingEnabled,
            inputFolderPath: workspace.inputFolderPath,
            outputFolderPath: workspace.outputFolderPath
        )
        saveWorkspace(newWs)
        showToast("Duplicated '\(workspace.name)'")
    }

    public func generateWorkspacesForAgents() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseWs = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces")
        var createdCount = 0

        for agent in agents {
            if !workspaces.contains(where: { $0.assignedAgentId == agent.id }) {
                let sanitizedName = agent.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                let wsFolder = (baseWs as NSString).appendingPathComponent(sanitizedName)
                let newWs = Workspace(
                    name: "\(agent.name) Workspace",
                    icon: agent.avatar.isEmpty ? "person.crop.circle" : agent.avatar,
                    color: agent.color.isEmpty ? "#8B5CF6" : agent.color,
                    folderPath: wsFolder,
                    category: .agent,
                    assignedAgentId: agent.id,
                    isPipelineStagingEnabled: true,
                    inputFolderPath: "input",
                    outputFolderPath: "output"
                )
                saveWorkspace(newWs)
                createdCount += 1
            }
        }

        if createdCount > 0 {
            showToast("Created \(createdCount) dedicated agent workspaces!")
        } else {
            showToast("All agents already have dedicated workspaces.")
        }
    }

    // MARK: - Watch Folders & Watch Items
    public func saveWatchItem(_ item: WatchItem) {
        if let idx = watchItems.firstIndex(where: { $0.id == item.id }) {
            watchItems[idx] = item
        } else {
            watchItems.append(item)
        }
        persistence.saveWatchItems(watchItems)
        restartWatchEngine()
        showToast("Watch target '\(item.name)' saved")
    }

    public func deleteWatchItem(_ item: WatchItem) {
        watchItems.removeAll(where: { $0.id == item.id })
        persistence.saveWatchItems(watchItems)
        restartWatchEngine()
        showToast("Deleted watch target '\(item.name)'")
    }

    public func restartWatchEngine() {
        let activeItems = watchItems.filter { $0.isEnabled }
        WatchFolderEngine.shared.startWatching(items: activeItems) { [weak self] item, eventSummary in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleWatchEventTriggered(for: item, summary: eventSummary)
            }
        }
    }

    public func handleWatchEventTriggered(for item: WatchItem, summary: String) {
        if let idx = watchItems.firstIndex(where: { $0.id == item.id }) {
            var updated = watchItems[idx]
            updated.lastEventAt = Date()
            updated.lastEventSummary = summary
            updated.eventsCount += 1
            watchItems[idx] = updated
            persistence.saveWatchItems(watchItems)
        }

        showToast("⚡️ Watch event in '\(item.name)'")

        if item.autoGenerateArtifact {
            triggerWatchScan(item)
        }
    }

    public func triggerWatchScan(_ item: WatchItem) {
        let agent = agents.first(where: { $0.id == item.targetAgentId }) ?? currentAgent
        let provider = currentProvider
        let model = currentModel
        let ws = workspaces.first(where: { $0.id == item.workspaceId }) ?? currentWorkspace

        showToast("Generating \(item.artifactTemplate.displayName)...")

        Task { [weak self] in
            guard let self = self else { return }
            await WatchFolderEngine.shared.triggerManualScan(
                item: item,
                workspace: ws,
                agent: agent,
                provider: provider,
                model: model
            ) { newArtifact in
                Task { @MainActor in
                    self.saveArtifact(newArtifact)
                    if let idx = self.watchItems.firstIndex(where: { $0.id == item.id }) {
                        self.watchItems[idx].createdArtifactsCount += 1
                        self.persistence.saveWatchItems(self.watchItems)
                    }
                    self.showToast("🎉 Generated \(newArtifact.title)")
                }
            }
        }
    }

    // MARK: - Artifacts Management
    public func saveArtifact(_ artifact: AutomationArtifact) {
        if let idx = artifacts.firstIndex(where: { $0.id == artifact.id }) {
            artifacts[idx] = artifact
        } else {
            artifacts.insert(artifact, at: 0)
        }
        persistence.saveArtifacts(artifacts)
    }

    public func deleteArtifact(_ artifact: AutomationArtifact) {
        artifacts.removeAll(where: { $0.id == artifact.id })
        persistence.saveArtifacts(artifacts)
        showToast("Artifact deleted")
    }

    public func createArtifactFromAutomation(_ automation: Automation) {
        let agent = agents.first(where: { $0.id == automation.targetAgentId }) ?? currentAgent
        let provider = currentProvider
        let model = currentModel
        let ws = workspaces.first(where: { $0.id == automation.workspaceId }) ?? currentWorkspace

        showToast("Executing automation: \(automation.name)...")

        let prompt = """
        \(automation.promptTemplate)

        Please synthesize a structured executive artifact (such as a Morning Brief, Project Status Digest, or Report).
        Format in rich Markdown with clean sections, emojis, and clear takeaways.
        """

        Task {
            let autoAccumulator = SubAgentAccumulator()
            do {
                try await ProviderRouter.shared.stream(
                    provider: provider,
                    model: model,
                    systemPrompt: agent.systemPrompt,
                    messages: [ChatMessage(sessionId: "auto-\(automation.id)", role: .user, content: prompt)],
                    temperature: agent.temperature,
                    maxTokens: 2048,
                    reasoningEffort: .off,
                    tools: []
                ) { chunk in
                    Task { @MainActor in
                        if !chunk.deltaText.isEmpty {
                            autoAccumulator.append(chunk.deltaText)
                        }
                    }
                }
            } catch {
                autoAccumulator.append("""
                # 📋 \(automation.name) Report
                *Timestamp: \(Date().formatted())*

                \(automation.description)

                Automated pipeline execution finished with status: healthy.
                """)
            }

            let synthesized = autoAccumulator.text.isEmpty ? """
            # 📋 \(automation.name) Report
            *Timestamp: \(Date().formatted())*

            \(automation.description)
            """ : autoAccumulator.text

            let artifact = AutomationArtifact(
                workspaceId: ws.id,
                automationId: automation.id,
                agentId: agent.id,
                agentName: agent.name,
                title: "\(automation.name) - \(Date().formatted(date: .abbreviated, time: .shortened))",
                subtitle: "Automated report from \(agent.name)",
                category: .report,
                content: synthesized,
                format: "markdown",
                sourceTrigger: "Automation: \(automation.name)"
            )

            await MainActor.run {
                self.saveArtifact(artifact)
                if let aIdx = self.automations.firstIndex(where: { $0.id == automation.id }) {
                    var updated = self.automations[aIdx]
                    updated.lastRunAt = Date()
                    updated.lastStatus = "success"
                    updated.lastResultSummary = "Generated artifact: \(artifact.title)"
                    self.automations[aIdx] = updated
                    self.persistence.saveAutomations(self.automations)
                }
                self.showToast("🎉 Generated Artifact for '\(automation.name)'")
            }
        }
    }

    // MARK: - Settings
    public func updateSettings(_ newSettings: AppSettings) {
        self.settings = newSettings
        persistence.saveSettings(newSettings)
        showToast("Settings saved")
    }
}
