import SwiftUI

public struct AppSidebar: View {
    @ObservedObject var appState: AppState
    @State private var showingWorkspaceSheet = false
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceCategory: WorkspaceCategory = .general
    @State private var newWorkspaceAgentId: String = ""
    @State private var newWorkspaceFolderPath: String = ""
    @State private var showAllWorkspaceSessions: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Workspace Header
            workspaceHeader

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Navigation Items List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    navButton(for: .chat, count: appState.sessions.filter { !$0.isArchived }.count)
                    navButton(for: .localModels, count: appState.localMLXModels.filter { $0.isDownloaded }.count)
                    navButton(for: .agents, count: appState.agents.count)
                    navButton(for: .providers, count: appState.providers.filter { $0.isEnabled }.count)
                    navButton(for: .automations, count: appState.automations.filter { $0.isEnabled }.count)
                    navButton(for: .watchFolders, count: appState.watchItems.filter { $0.isEnabled }.count)
                    navButton(for: .artifacts, count: appState.artifacts.count)
                    navButton(for: .memory, count: appState.memories.count)
                    navButton(for: .tools, count: appState.tools.filter { $0.isEnabled }.count)
                    navButton(for: .dashboard, count: nil)

                    // Sessions subsection when in Chat mode
                    if appState.navigationDestination == .chat {
                        sessionsListSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Bottom Footer (Settings & Status)
            bottomFooter
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 450)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Workspace Header
    private var workspaceHeader: some View {
        Menu {
            // General, Research, and Project Workspaces
            let coreWorkspaces = appState.workspaces.filter { $0.category == .general || $0.category == .research || $0.category == .project }
            if !coreWorkspaces.isEmpty {
                Section("Core Workspaces & Research") {
                    ForEach(coreWorkspaces) { ws in
                        Button {
                            appState.switchWorkspace(to: ws.id)
                        } label: {
                            HStack {
                                Image(systemName: ws.icon)
                                Text(ws.name)
                                if ws.id == appState.activeWorkspaceId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            // Dedicated Agent Workspaces
            let agentWorkspaces = appState.workspaces.filter { $0.category == .agent }
            if !agentWorkspaces.isEmpty {
                Section("Agent Workspaces") {
                    ForEach(agentWorkspaces) { ws in
                        Button {
                            appState.switchWorkspace(to: ws.id)
                        } label: {
                            HStack {
                                Image(systemName: ws.icon)
                                Text(ws.name)
                                if ws.id == appState.activeWorkspaceId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                showingWorkspaceSheet = true
            } label: {
                Label("Add New Workspace...", systemImage: "plus")
            }

            Button {
                appState.generateWorkspacesForAgents()
            } label: {
                Label("Auto-Generate Workspaces for All Agents", systemImage: "sparkles")
            }

            Button {
                appState.navigationDestination = .settings
                appState.settingsTab = "general"
            } label: {
                Label("Workspace Configuration...", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: appState.currentWorkspace.color))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.currentWorkspace.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineLimit(1)
                    
                    Text(workspaceSubtitle(for: appState.currentWorkspace))
                        .font(.system(size: 9.5))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .sheet(isPresented: $showingWorkspaceSheet) {
            newWorkspaceModal
        }
    }

    private func workspaceSubtitle(for workspace: Workspace) -> String {
        if let agentId = workspace.assignedAgentId, let agent = appState.agents.first(where: { $0.id == agentId }) {
            return "\(agent.role) Sandbox"
        }
        return workspace.category.displayName
    }

    private var newWorkspaceModal: some View {
        VStack(spacing: 16) {
            Text("Create Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Name")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("e.g. AI & Agent Research, Swift Projects", text: $newWorkspaceName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Category")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("", selection: $newWorkspaceCategory) {
                        ForEach(WorkspaceCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if newWorkspaceCategory == .agent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assigned Agent Sandbox")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $newWorkspaceAgentId) {
                            Text("None (Shared Workspace)").tag("")
                            ForEach(appState.agents) { ag in
                                Text("\(ag.name) (\(ag.role))").tag(ag.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Directory Path (External SSD / Custom Folder / Project)")
                        .font(.system(size: 11, weight: .semibold))

                    HStack(spacing: 6) {
                        TextField(
                            "e.g. /Volumes/ExternalSSD/Workspaces or project folder",
                            text: Binding(
                                get: {
                                    if newWorkspaceFolderPath.isEmpty && !newWorkspaceName.isEmpty {
                                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                                        let baseWs = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces")
                                        return (baseWs as NSString).appendingPathComponent(newWorkspaceName.replacingOccurrences(of: " ", with: "-"))
                                    }
                                    return newWorkspaceFolderPath
                                },
                                set: { newWorkspaceFolderPath = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.canCreateDirectories = true
                            panel.prompt = "Choose Workspace Folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                newWorkspaceFolderPath = url.path
                                if newWorkspaceName.isEmpty {
                                    newWorkspaceName = url.lastPathComponent
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    showingWorkspaceSheet = false
                    newWorkspaceName = ""
                    newWorkspaceAgentId = ""
                    newWorkspaceFolderPath = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Workspace") {
                    guard !newWorkspaceName.isEmpty else { return }
                    let folder: String
                    if !newWorkspaceFolderPath.isEmpty {
                        folder = newWorkspaceFolderPath
                    } else {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        let baseWs = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces")
                        folder = (baseWs as NSString).appendingPathComponent(newWorkspaceName.replacingOccurrences(of: " ", with: "-"))
                    }

                    let ws = Workspace(
                        name: newWorkspaceName,
                        icon: newWorkspaceCategory.icon,
                        color: ["#8B5CF6", "#3B82F6", "#10B981", "#EC4899", "#F59E0B", "#06B6D4"].randomElement() ?? "#8B5CF6",
                        folderPath: folder,
                        category: newWorkspaceCategory,
                        assignedAgentId: newWorkspaceCategory == .agent && !newWorkspaceAgentId.isEmpty ? newWorkspaceAgentId : nil,
                        isPipelineStagingEnabled: true,
                        inputFolderPath: "input",
                        outputFolderPath: "output"
                    )
                    appState.saveWorkspace(ws)
                    appState.switchWorkspace(to: ws.id)
                    showingWorkspaceSheet = false
                    newWorkspaceName = ""
                    newWorkspaceAgentId = ""
                    newWorkspaceFolderPath = ""
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Navigation Button
    private func navButton(for destination: NavigationDestination, count: Int?) -> some View {
        let isSelected = appState.navigationDestination == destination
        return Button {
            appState.navigationDestination = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))

                Text(destination.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))

                Spacer()

                if let count = count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.15) : ThemeColors.border(for: appState.settings.theme).opacity(0.6))
                        .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sessions List in Sidebar
    private var sessionsListSection: some View {
        let activeSessions = appState.sessions.filter {
            !$0.isArchived && (showAllWorkspaceSessions || $0.workspaceId == appState.activeWorkspaceId)
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(showAllWorkspaceSessions ? "ALL SESSIONS" : "WORKSPACE SESSIONS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.7))
                    .padding(.leading, 8)
                    .padding(.top, 10)

                Spacer()

                Button {
                    showAllWorkspaceSessions.toggle()
                } label: {
                    Image(systemName: showAllWorkspaceSessions ? "tray.full.fill" : "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.plain)
                .help(showAllWorkspaceSessions ? "Show Active Workspace Only" : "Show All Workspaces")

                Button {
                    appState.createNewSession()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                }
                .buttonStyle(.plain)
                .help("New Session (Cmd+N)")
            }

            if activeSessions.isEmpty {
                VStack(spacing: 6) {
                    Text("No chats in \(appState.currentWorkspace.name)")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                    Button("Start New Chat") {
                        appState.createNewSession()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            } else {
                ForEach(activeSessions) { session in
                    let isCurrent = appState.currentSessionId == session.id
                    HStack(spacing: 8) {
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        } else {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 10))
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        }

                        Text(session.title)
                            .font(.system(size: 12))
                            .foregroundColor(isCurrent ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isCurrent ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12) : Color.clear)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.selectSession(session)
                    }
                    .contextMenu {
                        Button(session.isPinned ? "Unpin Session" : "Pin Session") {
                            appState.togglePinSession(session)
                        }
                        Button("Archive Session") {
                            appState.archiveSession(session)
                        }
                        Divider()
                        Button("Delete Session", role: .destructive) {
                            appState.deleteSession(session)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom Footer
    private var bottomFooter: some View {
        HStack(spacing: 10) {
            Button {
                appState.navigationDestination = .settings
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundColor(appState.navigationDestination == .settings ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))

                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(appState.navigationDestination == .settings ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(appState.navigationDestination == .settings ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Spacer()

            // Standalone node online status
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Online")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
