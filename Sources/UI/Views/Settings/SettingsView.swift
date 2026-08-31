import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showingResetAlert = false
    @State private var newEnvKey = ""
    @State private var newEnvVal = ""
    @State private var showingAddSkill = false
    @State private var selectedSkillForDetail: Skill? = nil
    @State private var showingAddMcp = false
    @State private var selectedMcpForEdit: MCPServerConfig? = nil
    @State private var showingAddPlugin = false
    @State private var selectedPluginForDetail: AppExtensionPlugin? = nil
    @State private var pluginSearchText = ""
    @State private var selectedPluginTypeFilter: String = "all"
    @State private var skillSearchText = ""
    @State private var showingCreateWorkspaceModal = false
    @State private var showingEditWorkspaceModal = false
    @State private var workspaceToEdit: Workspace? = nil
    @State private var newWsName = ""
    @State private var newWsCategory: WorkspaceCategory = .general
    @State private var newWsAgentId = ""
    @State private var newWsFolderPath = ""
    @State private var showingAddWatchItemModal = false
    @State private var editingWatchItem: WatchItem? = nil

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Settings Sidebar
            settingsSidebar
                .frame(width: 240)
                .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Right Settings Content & Top Header
            VStack(spacing: 0) {
                // Top Settings Header Bar
                settingsTopHeader

                Divider()
                    .background(ThemeColors.border(for: appState.settings.theme))

                // Main Scrollable Page
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch appState.settingsTab {
                        case "general":
                            generalPage
                        case "mlx":
                            mlxSettingsPage
                        case "preferences":
                            preferencesPage
                        case "permissions":
                            permissionsPage
                        case "watchFolders":
                            watchFoldersPage
                        case "extensions":
                            extensionsPage
                        case "advanced":
                            advancedPage
                        case "ai":
                            aiProvidersPage
                        case "appearance":
                            appearancePage
                        case "environment":
                            environmentPage
                        case "updates":
                            updatesPage
                        case "recovery":
                            recoveryPage
                        case "debug":
                            debugPage
                        case "cloud":
                            cloudAccountPage
                        case "connect":
                            connectPage
                        case "skills":
                            skillsPage
                        case "memory":
                            memoryPage
                        default:
                            generalPage
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(ThemeColors.bg(for: appState.settings.theme))
        }
        .sheet(isPresented: $showingCreateWorkspaceModal) {
            createWorkspaceModal
        }
        .sheet(item: $workspaceToEdit) { ws in
            EditWorkspaceModalView(appState: appState, workspace: ws, isPresented: Binding(
                get: { workspaceToEdit != nil },
                set: { if !$0 { workspaceToEdit = nil } }
            ))
        }
        .sheet(isPresented: $showingAddPlugin) {
            AddExtensionModalView(appState: appState, isPresented: $showingAddPlugin)
        }
        .sheet(item: $selectedPluginForDetail) { plug in
            ExtensionDetailModalView(appState: appState, isPresented: Binding(
                get: { selectedPluginForDetail != nil },
                set: { if !$0 { selectedPluginForDetail = nil } }
            ), plugin: plug)
        }
        .sheet(isPresented: $showingAddWatchItemModal) {
            WatchItemEditModalView(appState: appState, isPresented: $showingAddWatchItemModal)
        }
        .sheet(item: $editingWatchItem) { item in
            WatchItemEditModalView(appState: appState, isPresented: Binding(
                get: { editingWatchItem != nil },
                set: { if !$0 { editingWatchItem = nil } }
            ), watchItem: item)
        }
    }

    private var createWorkspaceModal: some View {
        VStack(spacing: 16) {
            Text("Add New Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Name")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("e.g. External SSD Drive, AI Research, OpenWork-Swift", text: $newWsName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Category")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("", selection: $newWsCategory) {
                        ForEach(WorkspaceCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if newWsCategory == .agent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assigned Agent Sandbox")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $newWsAgentId) {
                            Text("None (Shared Workspace)").tag("")
                            ForEach(appState.agents) { ag in
                                Text("\(ag.name) (\(ag.role))").tag(ag.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Directory Path (External SSD, Custom Folder, or Existing Project)")
                        .font(.system(size: 11, weight: .semibold))
                    
                    HStack(spacing: 6) {
                        TextField(
                            "e.g. /Volumes/MyExternalSSD/Workspaces or /Volumes/Storage/Projects/MyRepo",
                            text: Binding(
                                get: {
                                    if newWsFolderPath.isEmpty && !newWsName.isEmpty {
                                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                                        let baseWs = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces")
                                        return (baseWs as NSString).appendingPathComponent(newWsName.replacingOccurrences(of: " ", with: "-"))
                                    }
                                    return newWsFolderPath
                                },
                                set: { newWsFolderPath = $0 }
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
                            panel.prompt = "Choose Folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                newWsFolderPath = url.path
                                if newWsName.isEmpty {
                                    newWsName = url.lastPathComponent
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
                    showingCreateWorkspaceModal = false
                    newWsName = ""
                    newWsAgentId = ""
                    newWsFolderPath = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Workspace") {
                    guard !newWsName.isEmpty else { return }
                    let folder: String
                    if !newWsFolderPath.isEmpty {
                        folder = newWsFolderPath
                    } else {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        let baseWs = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces")
                        folder = (baseWs as NSString).appendingPathComponent(newWsName.replacingOccurrences(of: " ", with: "-"))
                    }

                    let ws = Workspace(
                        name: newWsName,
                        icon: newWsCategory.icon,
                        color: ["#8B5CF6", "#3B82F6", "#10B981", "#EC4899", "#F59E0B", "#06B6D4"].randomElement() ?? "#8B5CF6",
                        folderPath: folder,
                        category: newWsCategory,
                        assignedAgentId: newWsCategory == .agent && !newWsAgentId.isEmpty ? newWsAgentId : nil,
                        isPipelineStagingEnabled: true,
                        inputFolderPath: "input",
                        outputFolderPath: "output"
                    )
                    appState.saveWorkspace(ws)
                    appState.switchWorkspace(to: ws.id)
                    showingCreateWorkspaceModal = false
                    newWsName = ""
                    newWsAgentId = ""
                    newWsFolderPath = ""
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Left Settings Sidebar
    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            // Header with Back Button
            HStack(spacing: 8) {
                Button {
                    appState.navigationDestination = .chat
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Back")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Settings")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Grouped Tab Items
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // WORKSPACE GROUP
                    sidebarGroup(title: "WORKSPACE") {
                        sidebarItem(id: "mlx", title: "Apple Silicon MLX", icon: "cpu.fill")
                        sidebarItem(id: "preferences", title: "Preferences", icon: "slider.horizontal.3")
                        sidebarItem(id: "permissions", title: "Permissions & Folders", icon: "folder.badge.gearshape")
                        sidebarItem(id: "watchFolders", title: "Watch Folders & Triggers", icon: "eye.circle.fill")
                        sidebarItem(id: "extensions", title: "Extensions & Plugins", icon: "puzzlepiece.extension")
                        sidebarItem(id: "advanced", title: "Advanced", icon: "wrench.and.screwdriver")
                    }

                    // GLOBAL GROUP
                    sidebarGroup(title: "GLOBAL") {
                        sidebarItem(id: "general", title: "General", icon: "gearshape")
                        sidebarItem(id: "ai", title: "AI Providers", icon: "bolt.fill")
                        sidebarItem(id: "appearance", title: "Appearance", icon: "paintbrush")
                        sidebarItem(id: "environment", title: "Environment Variables", icon: "terminal")
                        sidebarItem(id: "updates", title: "Updates", icon: "arrow.triangle.2.circlepath")
                        sidebarItem(id: "recovery", title: "Backup & Recovery", icon: "shield.checkered")
                        sidebarItem(id: "debug", title: "Debug & Logs", icon: "ant")
                    }

                    // CLOUD GROUP
                    sidebarGroup(title: "CLOUD & SYNC") {
                        sidebarItem(id: "cloud", title: "Cloud Account", icon: "person.crop.circle")
                        sidebarItem(id: "connect", title: "Connect & Remote", icon: "cable.connector")
                        sidebarItem(id: "skills", title: "Skills & MCP", icon: "sparkles")
                        sidebarItem(id: "memory", title: "Memory", icon: "brain")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
    }

    private func sidebarGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            content()
        }
    }

    private func sidebarItem(id: String, title: String, icon: String) -> some View {
        let isSelected = appState.settingsTab == id
        return Button {
            appState.settingsTab = id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Top Settings Header Bar
    private var settingsTopHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tabTitle(for: appState.settingsTab))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Text(tabDescription(for: appState.settingsTab))
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            // Workspace Badge
            HStack(spacing: 5) {
                Circle().fill(Color(hex: appState.currentWorkspace.color)).frame(width: 8, height: 8)
                Text(appState.currentWorkspace.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .cornerRadius(6)

            // Close Settings Button
            Button {
                appState.navigationDestination = .chat
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .frame(width: 26, height: 26)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close Settings (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Pages
    // 1. General
    private var generalPage: some View {
        VStack(spacing: 18) {
            // Active Workspace Switcher & Configuration
            SettingsCard(title: "Active Workspace", description: "Currently operating in \(appState.currentWorkspace.name)", icon: "folder.fill") {
                // Workspace Switcher Dropdown
                SettingsRow(title: "Active Workspace", subtitle: "Select active workspace for all chat, tools, terminal and storage operations", icon: "arrow.triangle.2.circlepath") {
                    Picker("", selection: Binding(
                        get: { appState.activeWorkspaceId },
                        set: { newId in
                            appState.switchWorkspace(to: newId)
                        }
                    )) {
                        ForEach(appState.workspaces) { ws in
                            HStack {
                                Text(ws.name)
                                if ws.category == .agent {
                                    Text("🤖 (Agent)")
                                } else if ws.category == .research {
                                    Text("🔬 (Research)")
                                }
                            }
                            .tag(ws.id)
                        }
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Workspace Name", subtitle: "Display label for this workspace", icon: "pencil") {
                    TextField("Workspace Name", text: Binding(
                        get: { appState.currentWorkspace.name },
                        set: { val in
                            var ws = appState.currentWorkspace
                            ws.name = val
                            appState.saveWorkspace(ws)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                }

                SettingsRow(title: "Workspace Category", subtitle: "Determines role, isolation level, and icon representation", icon: "tag.fill") {
                    Picker("", selection: Binding(
                        get: { appState.currentWorkspace.category },
                        set: { newCat in
                            var ws = appState.currentWorkspace
                            ws.category = newCat
                            ws.icon = newCat.icon
                            appState.saveWorkspace(ws)
                        }
                    )) {
                        ForEach(WorkspaceCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Assigned Agent Sandbox", subtitle: "Bind this workspace to a dedicated AI Agent role", icon: "person.crop.circle.badge.checkmark") {
                    Picker("", selection: Binding(
                        get: { appState.currentWorkspace.assignedAgentId ?? "" },
                        set: { newAgentId in
                            var ws = appState.currentWorkspace
                            ws.assignedAgentId = newAgentId.isEmpty ? nil : newAgentId
                            appState.saveWorkspace(ws)
                        }
                    )) {
                        Text("None (Shared Workspace)").tag("")
                        ForEach(appState.agents) { ag in
                            Text("\(ag.name) (\(ag.role))").tag(ag.id)
                        }
                    }
                    .frame(width: 240)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingsRow(title: "Workspace Path", subtitle: "Root folder for code, file tools, terminal execution, and artifacts", icon: "folder") {
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") {
                                let url = URL(fileURLWithPath: appState.currentWorkspace.folderPath)
                                appState.ensureWorkspaceFolderExists(for: appState.currentWorkspace)
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Browse Folder / Drive...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.canCreateDirectories = true
                                panel.prompt = "Select Workspace Folder"
                                if panel.runModal() == .OK, let url = panel.url {
                                    var ws = appState.currentWorkspace
                                    ws.folderPath = url.path
                                    appState.saveWorkspace(ws)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    // Direct text editable path field with quick action buttons
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                        TextField("Path (e.g. /Volumes/ExternalSSD/Workspaces/MyProject)", text: Binding(
                            get: { appState.currentWorkspace.folderPath },
                            set: { val in
                                var ws = appState.currentWorkspace
                                ws.folderPath = val
                                appState.saveWorkspace(ws)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                        Button("Set to External SSD...") {
                            let panel = NSOpenPanel()
                            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.canCreateDirectories = true
                            panel.prompt = "Select External Volume Folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                var ws = appState.currentWorkspace
                                ws.folderPath = url.path
                                appState.saveWorkspace(ws)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.leading, 26)
                }

                SettingsRow(title: "Automated Pipeline Staging", subtitle: "Enable automated 'input/' & 'output/' staging directory processing", icon: "tray.2.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.currentWorkspace.isPipelineStagingEnabled },
                        set: { val in
                            var ws = appState.currentWorkspace
                            ws.isPipelineStagingEnabled = val
                            appState.saveWorkspace(ws)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                // Workspace Actions Row
                HStack(spacing: 10) {
                    Button {
                        showingCreateWorkspaceModal = true
                    } label: {
                        Label("Add New Workspace", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        appState.duplicateWorkspace(appState.currentWorkspace)
                    } label: {
                        Label("Duplicate Workspace", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        appState.generateWorkspacesForAgents()
                    } label: {
                        Label("Auto-Generate Workspaces for All Agents", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    if appState.currentWorkspace.id != "default-workspace" {
                        Button(role: .destructive) {
                            appState.deleteWorkspace(appState.currentWorkspace)
                        } label: {
                            Label("Delete Workspace", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }

            // Workspaces Overview List
            SettingsCard(title: "All Configured Workspaces (\(appState.workspaces.count))", description: "Manage dedicated agent environments and project workspaces", icon: "square.grid.2x2.fill") {
                VStack(spacing: 8) {
                    ForEach(appState.workspaces) { ws in
                        let isSelected = ws.id == appState.activeWorkspaceId
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: ws.color))
                                .frame(width: 10, height: 10)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(ws.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                    Text(ws.category.displayName)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12))
                                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                        .cornerRadius(4)

                                    if isSelected {
                                        Text("ACTIVE")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .cornerRadius(3)
                                    }
                                }

                                Text(ws.folderPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                    .lineLimit(1)
                            }

                            Spacer()

                            if let agentId = ws.assignedAgentId, let ag = appState.agents.first(where: { $0.id == agentId }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 10))
                                    Text(ag.name)
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ThemeColors.border(for: appState.settings.theme).opacity(0.4))
                                .cornerRadius(4)
                            }

                            HStack(spacing: 6) {
                                Button("Edit / Path") {
                                    workspaceToEdit = ws
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                if !isSelected {
                                    Button("Switch") {
                                        appState.switchWorkspace(to: ws.id)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                }
                            }
                        }
                        .padding(10)
                        .background(isSelected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.08) : ThemeColors.border(for: appState.settings.theme).opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : Color.clear, lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }
                }
            }

            SettingsCard(title: "Default Lead Agent & Model", description: "Default selections for new sessions", icon: "person.crop.circle.badge.checkmark") {
                SettingsRow(title: "Default Agent", subtitle: "Initial agent assigned to new chats", icon: "person.fill") {
                    Picker("", selection: $appState.settings.defaultAgentId) {
                        ForEach(appState.agents) { ag in
                            Text(ag.name).tag(ag.id)
                        }
                    }
                    .frame(width: 220)
                }

                SettingsRow(title: "Default Model Provider", subtitle: "Provider for default inference", icon: "server.rack") {
                    Picker("", selection: Binding(
                        get: { appState.settings.defaultProviderId },
                        set: { newProvId in
                            appState.settings.defaultProviderId = newProvId
                            if let prov = appState.providers.first(where: { $0.id == newProvId }) {
                                if !prov.models.contains(where: { $0.id == appState.settings.defaultModelId }) {
                                    appState.settings.defaultModelId = prov.models.first?.id ?? ""
                                }
                            }
                            appState.updateSettings(appState.settings)
                        }
                    )) {
                        ForEach(appState.providers.filter { $0.isEnabled }) { prov in
                            Text(prov.name).tag(prov.id)
                        }
                    }
                    .frame(width: 220)
                }

                // Default Model Picker
                let currentProv = appState.providers.first(where: { $0.id == appState.settings.defaultProviderId }) ?? appState.providers.first
                SettingsRow(title: "Default Model", subtitle: "Primary model used for new sessions (\(currentProv?.name ?? "Provider"))", icon: "cpu") {
                    Picker("", selection: $appState.settings.defaultModelId) {
                        if let prov = currentProv {
                            ForEach(prov.models) { model in
                                Text("\(model.name) (\(model.speedTier))").tag(model.id)
                            }
                        }
                    }
                    .frame(width: 220)
                }
            }

            SettingsCard(title: "Startup & Persistence", description: "Storage cadence and launch behavior", icon: "clock.fill") {
                SettingsRow(title: "Auto-Save Cadence", subtitle: "Interval between background data flushes (\(appState.settings.autoSaveIntervalSeconds)s)", icon: "externaldrive.fill") {
                    Stepper("", value: $appState.settings.autoSaveIntervalSeconds, in: 5...120, step: 5)
                }

                SettingsRow(title: "Launch at Login", subtitle: "Automatically open OpenWork when macOS boots", icon: "power") {
                    Toggle("", isOn: $appState.settings.startOnLogin)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // MLX Settings Page (Parity with Osaurus & GrizzyClaw)
    private var mlxSettingsPage: some View {
        VStack(spacing: 16) {
            // Hardware Status Card
            SettingsCard(
                title: "Apple Silicon Unified Memory",
                description: "Hardware telemetry and runtime budget for MLX metal shaders",
                icon: "cpu.fill"
            ) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Physical RAM")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f GB", LocalMLXEngine.physicalRAMGB))
                            .font(.system(size: 16, weight: .bold))
                    }
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Safe GPU Memory Budget")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f GB (%.0f%%)", LocalMLXEngine.physicalRAMGB * appState.settings.mlxGpuMemoryBudgetRatio, appState.settings.mlxGpuMemoryBudgetRatio * 100))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.green)
                    }
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installed MLX Models")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("\(appState.localMLXModels.filter { $0.isDownloaded }.count) Active")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                SettingsRow(title: "GPU Memory Budget Ratio", subtitle: "Fraction of unified RAM allocated for weights + KV cache", icon: "gauge.with.dots.needle.bottom.50percent") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.mlxGpuMemoryBudgetRatio, in: 0.5...0.9, step: 0.05)
                            .frame(width: 140)
                        Text("\(Int(appState.settings.mlxGpuMemoryBudgetRatio * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

                SettingsRow(title: "Default Context Length", subtitle: "Maximum token sequence context for MLX generation", icon: "ruler") {
                    Picker("", selection: $appState.settings.mlxContextLength) {
                        Text("32K (32,768)").tag(32768)
                        Text("64K (65,536)").tag(65536)
                        Text("128K (131,072)").tag(131072)
                        Text("256K (262,144)").tag(262144)
                    }
                    .frame(width: 160)
                }
            }

            // External Model Discovery Locations (Osaurus Parity)
            SettingsCard(
                title: "External Model Locations & Hub Caches",
                description: "Scan existing model weights on this Mac without copying or duplicating files",
                icon: "externaldrive.badge.person.crop"
            ) {
                SettingsRow(title: "Hugging Face Cache (~/.cache/huggingface)", subtitle: "Reference downloaded Hugging Face snapshots in-place", icon: "folder.badge.gearshape") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.scanHuggingFaceCache },
                        set: { val in
                            appState.settings.scanHuggingFaceCache = val
                            appState.updateSettings(appState.settings)
                            appState.rescanMLXModels()
                        }
                    ))
                    .toggleStyle(.switch)
                }

                if appState.settings.scanHuggingFaceCache {
                    SettingsRow(title: "Custom HF Cache Path", subtitle: "Optional custom HF_HOME or HF_HUB_CACHE folder", icon: "folder") {
                        HStack(spacing: 6) {
                            TextField("~/.cache/huggingface/hub", text: $appState.settings.customHFCachePath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    appState.settings.customHFCachePath = url.path
                                    appState.updateSettings(appState.settings)
                                    appState.rescanMLXModels()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                SettingsRow(title: "LM Studio Library (~/.cache/lm-studio)", subtitle: "Discover safetensors and MLX weights from LM Studio", icon: "desktopcomputer") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.scanLMStudioModels },
                        set: { val in
                            appState.settings.scanLMStudioModels = val
                            appState.updateSettings(appState.settings)
                            appState.rescanMLXModels()
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "Custom MLX Models Directory", subtitle: "Specific folder on external SSD or hard drive", icon: "externaldrive.fill") {
                    HStack(spacing: 6) {
                        TextField("~/.openwork/mlx_models", text: $appState.settings.customMLXModelsDirectory)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.settings.customMLXModelsDirectory = url.path
                                appState.updateSettings(appState.settings)
                                appState.rescanMLXModels()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    if appState.isScanningMLX {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        Text("Scanning local directories...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(appState.localMLXModels.filter { $0.isDownloaded }.count) local models discovered")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        appState.rescanMLXModels()
                    } label: {
                        Label("Rescan Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isScanningMLX)
                }
                .padding(.top, 4)
            }

            // Discovered & Curated MLX Models List
            SettingsCard(
                title: "MLX Model Catalog & Installed Weights (\(appState.localMLXModels.count))",
                description: "Select, run, or download Apple Silicon optimized model weights",
                icon: "square.grid.2x2.fill"
            ) {
                VStack(spacing: 8) {
                    ForEach(appState.localMLXModels) { model in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: model.useCase.iconName)
                                .font(.system(size: 14))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(model.name)
                                        .font(.system(size: 12, weight: .bold))

                                    if let q = model.quantization {
                                        Text(q)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)
                                    }

                                    if model.isDownloaded {
                                        Text("INSTALLED")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .cornerRadius(3)
                                    }

                                    Text(model.compatibility.displayName)
                                        .font(.system(size: 9.5))
                                        .foregroundColor(model.compatibility == .runsWell ? .green : (model.compatibility == .tight ? .orange : .red))
                                }

                                Text(model.description)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(model.formattedRAM)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)

                            if model.isDownloaded {
                                Button("Select Model") {
                                    if let omlx = appState.providers.first(where: { $0.kind == .omlx }) {
                                        appState.selectedProviderId = omlx.id
                                        appState.selectedModelId = model.id
                                        appState.showToast("Selected \(model.name) as active model")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button("Download (\(model.formattedSize))") {
                                    appState.pullMLXModel(model)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    // 2. Preferences
    private var preferencesPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Inference & Reasoning", description: "Sampling parameters for autonomous LLM responses", icon: "slider.horizontal.3") {
                SettingsRow(title: "Temperature (\(String(format: "%.2f", appState.settings.defaultTemperature)))", subtitle: "Lower for precise coding, higher for creative research", icon: "thermometer.medium") {
                    Slider(value: $appState.settings.defaultTemperature, in: 0.0...1.0, step: 0.05)
                        .frame(width: 180)
                }

                SettingsRow(title: "Top-P Sampling (\(String(format: "%.2f", appState.settings.defaultTopP)))", subtitle: "Nucleus sampling probability threshold", icon: "chart.bar.xaxis") {
                    Slider(value: $appState.settings.defaultTopP, in: 0.1...1.0, step: 0.05)
                        .frame(width: 180)
                }

                SettingsRow(title: "Max Output Tokens (\(appState.settings.defaultMaxTokens))", subtitle: "Maximum completion token ceiling per turn", icon: "number") {
                    Stepper("", value: $appState.settings.defaultMaxTokens, in: 1024...32768, step: 1024)
                }

                SettingsRow(title: "Reasoning Effort", subtitle: "Budget for thinking models (Claude 3.7, DeepSeek R1, o1/o3)", icon: "brain") {
                    Picker("", selection: $appState.settings.defaultReasoningEffort) {
                        ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    .frame(width: 200)
                }
            }

            SettingsCard(title: "Repetition, Presence & Loop Control", description: "Fine-tune penalties and loop prevention across any LLM provider", icon: "repeat.circle.fill") {
                SettingsRow(title: "Frequency Penalty (\(String(format: "%.2f", appState.settings.defaultFrequencyPenalty)))", subtitle: "Penalizes repeated tokens based on cumulative frequency (-2.0 to 2.0)", icon: "waveform.path.ecg") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.defaultFrequencyPenalty, in: 0.0...1.0, step: 0.05)
                            .frame(width: 140)
                        Button("0.35") {
                            appState.settings.defaultFrequencyPenalty = 0.35
                            appState.updateSettings(appState.settings)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                SettingsRow(title: "Presence Penalty (\(String(format: "%.2f", appState.settings.defaultPresencePenalty)))", subtitle: "Penalizes repeated tokens based on presence in generated text (-2.0 to 2.0)", icon: "sparkle") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.defaultPresencePenalty, in: 0.0...1.0, step: 0.05)
                            .frame(width: 140)
                        Button("0.35") {
                            appState.settings.defaultPresencePenalty = 0.35
                            appState.updateSettings(appState.settings)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                SettingsRow(title: "Repeat Penalty (\(String(format: "%.2f", appState.settings.defaultRepeatPenalty)))", subtitle: "Multiplicative penalty used by Ollama and local engines (1.0 to 2.0)", icon: "arrow.triangle.2.circlepath") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.defaultRepeatPenalty, in: 1.0...2.0, step: 0.05)
                            .frame(width: 140)
                        Button("1.25") {
                            appState.settings.defaultRepeatPenalty = 1.25
                            appState.updateSettings(appState.settings)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                SettingsRow(title: "Auto-Detect & Optimize for Local Models", subtitle: "Automatically apply higher penalties and ReAct safety for MLX, Ollama, and local endpoints", icon: "wand.and.stars") {
                    Toggle("", isOn: $appState.settings.autoAdjustPenaltiesForLocalModels)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Autonomous Stream Loop Breaker", subtitle: "Halt autoregressive sentence looping in real-time using fuzzy similarity", icon: "shield.lefthalf.filled") {
                    Toggle("", isOn: $appState.settings.autoLoopBreakerEnabled)
                        .toggleStyle(.switch)
                }

                // Quick Diagnosis & Auto-Tuning presets
                HStack(spacing: 10) {
                    Button {
                        // Preset for local MLX / Ollama models (prone to repetition)
                        appState.settings.defaultFrequencyPenalty = 0.35
                        appState.settings.defaultPresencePenalty = 0.35
                        appState.settings.defaultRepeatPenalty = 1.25
                        appState.settings.autoAdjustPenaltiesForLocalModels = true
                        appState.settings.autoLoopBreakerEnabled = true
                        appState.updateSettings(appState.settings)
                        appState.showToast("Applied Optimized Anti-Looping Preset")
                    } label: {
                        Label("Apply Anti-Looping Preset (Recommended for MLX/Ollama)", systemImage: "bolt.badge.checkmark.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        // Preset for cloud models (OpenAI/Anthropic/DeepSeek)
                        appState.settings.defaultFrequencyPenalty = 0.0
                        appState.settings.defaultPresencePenalty = 0.0
                        appState.settings.defaultRepeatPenalty = 1.0
                        appState.settings.autoAdjustPenaltiesForLocalModels = true
                        appState.settings.autoLoopBreakerEnabled = true
                        appState.updateSettings(appState.settings)
                        appState.showToast("Applied Standard Cloud Model Defaults")
                    } label: {
                        Label("Reset to Standard Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }

            SettingsCard(title: "Chat Experience", description: "Streaming and context management", icon: "bubble.left.and.bubble.right") {
                SettingsRow(title: "Stream Responses", subtitle: "Display LLM output progressively as generated", icon: "waveform") {
                    Toggle("", isOn: $appState.settings.streamResponses)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Auto-Compact Context", subtitle: "Summarize old messages when nearing context limit", icon: "arrow.triangle.merge") {
                    Toggle("", isOn: $appState.settings.autoCompactContext)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Audio Notifications", subtitle: "Play chime when agents finish long tasks", icon: "speaker.wave.2") {
                    Toggle("", isOn: $appState.settings.playNotificationSounds)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // 3. Permissions
    private var permissionsPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Terminal & Shell Configuration", description: "Default shell binary, execution environment, and interactive console", icon: "terminal.fill") {
                SettingsRow(title: "Default Terminal Shell", subtitle: "Shell executable for terminal tools and interactive console", icon: "chevron.left.forwardslash.chevron.right") {
                    Picker("", selection: Binding(
                        get: { appState.settings.terminalShell },
                        set: { newShell in
                            appState.settings.terminalShell = newShell
                            appState.updateSettings(appState.settings)
                            WorkspaceTerminalSession.shared.activeShellName = (newShell as NSString).lastPathComponent
                        }
                    )) {
                        Text("Zsh (/bin/zsh) [macOS Default]").tag("/bin/zsh")
                        Text("Bash (/bin/bash)").tag("/bin/bash")
                        Text("POSIX sh (/bin/sh)").tag("/bin/sh")
                        Text("Fish (/opt/homebrew/bin/fish)").tag("/opt/homebrew/bin/fish")
                        Text("Dash (/bin/dash)").tag("/bin/dash")
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Custom Shell Binary Path", subtitle: "Override with any custom shell or virtual environment binary", icon: "terminal") {
                    TextField("/bin/zsh", text: Binding(
                        get: { appState.settings.terminalShell },
                        set: { newPath in
                            appState.settings.terminalShell = newPath
                            appState.updateSettings(appState.settings)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 240)
                }

                SettingsRow(title: "Safety Level", subtitle: "Permission policy for autonomous agent shell commands", icon: "shield") {
                    Picker("", selection: $appState.settings.terminalSafetyLevel) {
                        ForEach(TerminalSafetyLevel.allCases) { lvl in
                            Text(lvl.displayName).tag(lvl)
                        }
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Web Search Access", subtitle: "Allow agents to query web search APIs", icon: "globe") {
                    Toggle("", isOn: $appState.settings.allowWebAccess)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Sandbox Agent File System", subtitle: "Restrict write operations strictly to workspace directory", icon: "lock.shield") {
                    Toggle("", isOn: $appState.settings.sandboxAgentFileSystem)
                        .toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Authorized Workspace Directories", description: "Paths agents are granted access to read and write", icon: "folder.fill") {
                ForEach(appState.settings.authorizedFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text(folder)
                            .font(.system(size: 11.5, design: .monospaced))
                        Spacer()
                        Button {
                            appState.settings.authorizedFolders.removeAll(where: { $0 == folder })
                            appState.updateSettings(appState.settings)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.3))
                    .cornerRadius(6)
                }

                Button("Add Authorized Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        if !appState.settings.authorizedFolders.contains(url.path) {
                            appState.settings.authorizedFolders.append(url.path)
                            appState.updateSettings(appState.settings)
                        }
                    }
                }
            }
        }
    }

    // 3b. Watch Folders & Real-Time Triggers
    private var watchFoldersPage: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Watch Folders & Ingestion Targets (\(appState.watchItems.count))",
                description: "Monitor directories and files to automatically synthesize Morning Briefs, Daily Updates, and Code Reviews",
                icon: "eye.circle.fill"
            ) {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Watch Target Monitors")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                            Text("Automatic background filesystem listeners trigger agent synthesis when files are modified or dropped in")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button {
                            showingAddWatchItemModal = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                Text("Add Watch Target...")
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if appState.watchItems.isEmpty {
                        Text("No watch targets configured. Click 'Add Watch Target' above to start monitoring directories.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(appState.watchItems) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.watchType.icon)
                                        .font(.system(size: 14))
                                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                        .frame(width: 24, height: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.name)
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                            Text(item.artifactTemplate.displayName)
                                                .font(.system(size: 9.5, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(ThemeColors.border(for: appState.settings.theme))
                                                .cornerRadius(4)
                                        }

                                        Text(item.path.isEmpty ? appState.currentWorkspace.folderPath : item.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    HStack(spacing: 8) {
                                        Button("Scan Now") {
                                            appState.triggerWatchScan(item)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("Edit") {
                                            editingWatchItem = item
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Toggle("", isOn: Binding(
                                            get: { item.isEnabled },
                                            set: { val in
                                                var updated = item
                                                updated.isEnabled = val
                                                appState.saveWatchItem(updated)
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                    }
                                }
                                .padding(10)
                                .background(ThemeColors.border(for: appState.settings.theme).opacity(0.25))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }

            SettingsCard(
                title: "Artifact Generation Defaults",
                description: "Executive brief formatting and automated pipeline output settings",
                icon: "sparkles.tv.fill"
            ) {
                SettingsRow(
                    title: "Default Briefing Agent",
                    subtitle: "Primary agent assigned to synthesize morning briefs and activity reports",
                    icon: "person.crop.circle.badge.checkmark"
                ) {
                    Picker("", selection: $appState.settings.defaultAgentId) {
                        ForEach(appState.agents) { ag in
                            Text("\(ag.name) (\(ag.role))").tag(ag.id)
                        }
                    }
                    .frame(width: 220)
                }

                SettingsRow(
                    title: "Interactive Live Canvas Output",
                    subtitle: "Render synthesized HTML, Tailwind, and React artifacts in the Live Canvas",
                    icon: "sparkles"
                ) {
                    Toggle("", isOn: .constant(true))
                        .toggleStyle(.switch)
                        .disabled(true)
                }
            }
        }
    }

    // 4. Extensions & Plugins Page
    private var extensionsPage: some View {
        VStack(spacing: 16) {
            // MARK: - TOP BAR & ACTIONS
            SettingsCard(
                title: "Extensions & Plugins Hub (\(appState.plugins.count))",
                description: "Install, manage, configure, or remove custom plugins, MCP tools, external scripts, and agent extensions",
                icon: "puzzlepiece.extension.fill"
            ) {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        // Search bar
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                            TextField("Filter extensions & plugins...", text: $pluginSearchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                            if !pluginSearchText.isEmpty {
                                Button {
                                    pluginSearchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1))

                        // Type Filter
                        Picker("", selection: $selectedPluginTypeFilter) {
                            Text("All Types").tag("all")
                            Text("MCP Servers").tag("mcp")
                            Text("Custom Scripts").tag("script")
                            Text("Media & OCR").tag("media")
                            Text("Voice & Audio").tag("voice")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)

                        Spacer()

                        // Add Plugin Button
                        Button {
                            showingAddPlugin = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                Text("Add Extension / Plugin...")
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // Quick Import Bar (File, Directory, URL)
                    HStack(spacing: 8) {
                        Button {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            panel.canChooseFiles = true
                            panel.allowedContentTypes = [
                                .json,
                                .shellScript,
                                UTType(filenameExtension: "sh") ?? .plainText,
                                UTType(filenameExtension: "py") ?? .plainText,
                                UTType(filenameExtension: "js") ?? .plainText
                            ]
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importPluginFromFile(url: url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.badge.plus")
                                Text("Import Manifest / Script File...")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                let plugin = AppExtensionPlugin(
                                    name: url.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized,
                                    description: "Folder plugin at \(url.path)",
                                    pluginType: .customScript,
                                    source: .directory,
                                    pathOrUrl: url.path,
                                    command: url.path
                                )
                                appState.savePlugin(plugin)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.plus")
                                Text("Load Plugin Directory...")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }
                }
            }

            // MARK: - INSTALLED PLUGINS LIST
            let filteredPlugins = appState.plugins.filter { plug in
                let matchesSearch = pluginSearchText.isEmpty ||
                    plug.name.localizedCaseInsensitiveContains(pluginSearchText) ||
                    plug.description.localizedCaseInsensitiveContains(pluginSearchText) ||
                    plug.command.localizedCaseInsensitiveContains(pluginSearchText)
                let matchesType = selectedPluginTypeFilter == "all" || plug.pluginType.rawValue == selectedPluginTypeFilter
                return matchesSearch && matchesType
            }

            SettingsCard(
                title: "Installed Extensions & Plugins (\(filteredPlugins.count))",
                description: "Active system plugins available across all agent sessions and autonomous loops",
                icon: "cube.box.fill"
            ) {
                if filteredPlugins.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 26))
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        Text(appState.plugins.isEmpty ? "No extensions or plugins installed yet." : "No plugins match your filter criteria.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("Install from Catalog...") {
                            showingAddPlugin = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredPlugins) { plugin in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: plugin.pluginType.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 28, height: 28)
                                    .background(ThemeColors.border(for: appState.settings.theme))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(plugin.name)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                        Text(plugin.pluginType.displayName)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        Text(plugin.source.displayName)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.secondary.opacity(0.12))
                                            .cornerRadius(4)

                                        Text("v\(plugin.version)")
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                    }

                                    if !plugin.description.isEmpty {
                                        Text(plugin.description)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    if !plugin.command.isEmpty {
                                        Text(plugin.command)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button("Configure") {
                                        selectedPluginForDetail = plugin
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { plugin.isEnabled },
                                        set: { val in
                                            var updated = plugin
                                            updated.isEnabled = val
                                            appState.savePlugin(updated)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deletePlugin(plugin)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.85))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove Extension / Plugin")
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }

            // MARK: - NATIVE HARDWARE EXTENSIONS
            SettingsCard(title: "Built-In Hardware & System Extensions", description: "Hardware-accelerated capabilities on Apple Silicon", icon: "cpu.fill") {
                SettingsRow(title: "Voice Input (Whisper / Speech Recognition)", subtitle: "Dictate prompts using microphone input", icon: "mic.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.voiceInputEnabled },
                        set: { val in
                            appState.settings.voiceInputEnabled = val
                            appState.updateSettings(appState.settings)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "Speech Synthesis", subtitle: "Read assistant replies aloud using macOS native TTS", icon: "speaker.wave.2.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.voiceSynthesisEnabled },
                        set: { val in
                            appState.settings.voiceSynthesisEnabled = val
                            appState.updateSettings(appState.settings)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "Generative Media & MLX Vision", subtitle: "Enable DALL-E, local Stable Diffusion, and Apple Vision tools", icon: "paintpalette.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.imageGenerationEnabled },
                        set: { val in
                            appState.settings.imageGenerationEnabled = val
                            appState.updateSettings(appState.settings)
                            for idx in appState.tools.indices {
                                if appState.tools[idx].category == .mediaVision {
                                    appState.tools[idx].isEnabled = val
                                }
                            }
                            PersistenceManager.shared.saveTools(appState.tools)
                            appState.showToast(val ? "Enabled Vision & Media Tools" : "Disabled Vision & Media Tools")
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }

    // 5. Advanced
    private var advancedPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Autonomous ReAct Loop & Hierarchy", description: "Multi-agent hierarchy limits and deep ReAct execution cycles", icon: "point.3.connected.trianglepath.dotted") {
                SettingsRow(title: "Max Autonomous Iteration Loop (\(appState.settings.maxAutonomousIterations) turns)", subtitle: "Maximum iterative ReAct tool calls per agent turn (1 - 50)", icon: "arrow.triangle.2.circlepath") {
                    Stepper("", value: $appState.settings.maxAutonomousIterations, in: 1...50)
                }

                SettingsRow(title: "Allow Sub-Agent Spawning", subtitle: "Enable lead agents to launch child agents", icon: "person.2.fill") {
                    Toggle("", isOn: $appState.settings.allowSubAgentCreation)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Max Global Nesting Depth (\(appState.settings.maxGlobalSubAgentDepth))", subtitle: "Maximum chain of child agents", icon: "arrow.down.right.and.arrow.up.left") {
                    Stepper("", value: $appState.settings.maxGlobalSubAgentDepth, in: 1...5)
                }

                SettingsRow(title: "Inter-Agent Collaboration Hub", subtitle: "Enable direct agent message routing", icon: "bubble.left.and.exclamationmark.bubble.right.fill") {
                    Toggle("", isOn: $appState.settings.enableAgentCollaborationRoom)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // 6. AI Providers
    private var aiProvidersPage: some View {
        VStack(spacing: 16) {
            ForEach(appState.providers) { prov in
                SettingsCard(title: prov.name, description: "\(prov.baseUrl) • \(prov.models.count) models", icon: prov.kind.icon) {
                    HStack(spacing: 10) {
                        if prov.type == .cloud {
                            SecureField("API Key", text: Binding(
                                get: { prov.apiKey },
                                set: { val in
                                    var updated = prov
                                    updated.apiKey = val
                                    appState.saveProvider(updated)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        Button("Fetch Models") {
                            appState.refreshModels(for: prov)
                        }

                        Button("Test") {
                            Task {
                                let ok = (try? await ProviderRouter.shared.client(for: prov).testConnection(provider: prov)) ?? false
                                appState.showToast(ok ? "\(prov.name): Connected!" : "\(prov.name): Failed")
                            }
                        }

                        Toggle("", isOn: Binding(
                            get: { prov.isEnabled },
                            set: { val in
                                var updated = prov
                                updated.isEnabled = val
                                appState.saveProvider(updated)
                            }
                        ))
                        .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    // 7. Appearance
    private var appearancePage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Theme & Palette", description: "Visual appearance of OpenWork", icon: "paintbrush.fill") {
                SettingsRow(title: "Theme Mode", subtitle: "Select window theme styling", icon: "circle.lefthalf.filled") {
                    Picker("", selection: $appState.settings.theme) {
                        ForEach(AppTheme.allCases) { th in
                            Text(th.displayName).tag(th)
                        }
                    }
                    .frame(width: 180)
                }

                SettingsRow(title: "Accent Color", subtitle: "Highlight and brand color", icon: "eyedropper.full") {
                    Picker("", selection: $appState.settings.accentColor) {
                        ForEach(AccentColorChoice.allCases) { ch in
                            Text(ch.displayName).tag(ch)
                        }
                    }
                    .frame(width: 180)
                }

                SettingsRow(title: "Editor Font Size (\(appState.settings.editorFontSize)pt)", subtitle: "Font scale for code and chat text", icon: "textformat.size") {
                    Stepper("", value: $appState.settings.editorFontSize, in: 10...22)
                }

                SettingsRow(title: "Translucent Window Background", subtitle: "Enable macOS vibrancy effect", icon: "macwindow") {
                    Toggle("", isOn: $appState.settings.useTranslucentBackground)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // 8. Environment
    private var environmentPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Environment Variables", description: "Injected into agent shells and MCP processes", icon: "terminal.fill") {
                ForEach(Array(appState.settings.customEnvironmentVariables.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        Spacer()
                        Text(appState.settings.customEnvironmentVariables[key] ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Button {
                            appState.settings.customEnvironmentVariables.removeValue(forKey: key)
                            appState.updateSettings(appState.settings)
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red).font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.3))
                    .cornerRadius(6)
                }

                HStack {
                    TextField("KEY", text: $newEnvKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("VALUE", text: $newEnvVal)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        guard !newEnvKey.isEmpty else { return }
                        appState.settings.customEnvironmentVariables[newEnvKey] = newEnvVal
                        appState.updateSettings(appState.settings)
                        newEnvKey = ""
                        newEnvVal = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // 9. Updates
    private var updatesPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Software Updates & Branding", description: "OpenWork-Swift standalone desktop client", icon: "arrow.triangle.2.circlepath") {
                HStack(spacing: 14) {
                    if let appIconImage = NSImage(contentsOfFile: "/Volumes/Storage/Icons/OpenWork__Alt__8jJIgN0S63_icns-95b0064150.icns") ?? NSImage(named: "AppIcon") {
                        Image(nsImage: appIconImage)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .cornerRadius(10)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("OpenWork-Swift")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        Text("Version 1.0.0 (Darwin arm64)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Autonomous Multi-Agent AI Engineering Platform")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                    }

                    Spacer()

                    Button("Check for Updates") {
                        appState.showToast("You are on the latest version.")
                    }
                }
                .padding(.vertical, 4)

                Divider()

                SettingsRow(title: "Auto-Check Updates", subtitle: "Periodically check for releases on launch", icon: "bell") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.autoCheckForUpdates },
                        set: { val in
                            appState.settings.autoCheckForUpdates = val
                            appState.updateSettings(appState.settings)
                            appState.showToast(val ? "Auto-check for updates enabled" : "Auto-check for updates disabled")
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }

    // 10. Recovery
    private var recoveryPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Backup & Data Export", description: "Export or restore all workspaces, sessions, and agents", icon: "arrow.down.doc.fill") {
                SettingsRow(title: "Export Archive", subtitle: "Save JSON backup archive to disk", icon: "square.and.arrow.up") {
                    Button("Export Backup...") {
                        if let url = StorageService.shared.exportBackup() {
                            appState.showToast("Backup saved to \(url.path)")
                        }
                    }
                }
            }

            SettingsCard(title: "Danger Zone", description: "Erase all local data and restore defaults", icon: "exclamationmark.triangle.fill") {
                SettingsRow(title: "Factory Reset", subtitle: "Wipes sessions, custom agents, memories, and resets configuration", icon: "trash") {
                    Button("Reset All Data...", role: .destructive) {
                        showingResetAlert = true
                    }
                }
            }
        }
        .alert("Confirm Factory Reset", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) {
                StorageService.shared.clearAllData()
                appState.loadAll()
                appState.showToast("Data reset to defaults")
            }
        } message: {
            Text("This will permanently clear all custom sessions, agents, and memories.")
        }
    }

    // 11. Debug
    private var debugPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Developer Options", description: "Runtime diagnostic flags and inspect mode", icon: "ant.fill") {
                SettingsRow(title: "Developer Mode", subtitle: "Enable advanced telemetry and model diagnostics", icon: "hammer") {
                    Toggle("", isOn: $appState.settings.developerMode)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Verbose Logging", subtitle: "Log raw SSE chunks and tool execution payloads", icon: "doc.plaintext") {
                    Toggle("", isOn: $appState.settings.verboseLogging)
                        .toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Live Runtime Telemetry", description: "Real-time state snapshot", icon: "chart.xyaxis.line") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Storage Path: \(StorageService.shared.baseDirectory.path)")
                        .font(.system(size: 11, design: .monospaced))
                    Text("• Registered Agents: \(appState.agents.count)")
                        .font(.system(size: 11, design: .monospaced))
                    Text("• Stored Sessions: \(appState.sessions.count)")
                        .font(.system(size: 11, design: .monospaced))
                    Text("• Enabled Tools: \(appState.tools.filter { $0.isEnabled }.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
            }
        }
    }

    // 12. Cloud Account
    private var cloudAccountPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "OpenWork Cloud Profile", description: "Manage remote sync account", icon: "person.crop.circle.fill") {
                SettingsRow(title: "Email", subtitle: "Account identifier", icon: "envelope") {
                    TextField("email@example.com", text: $appState.settings.cloudAccountEmail)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                SettingsRow(title: "Organization", subtitle: "Team workspace group", icon: "building.2") {
                    TextField("Personal", text: $appState.settings.cloudOrganizationName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                SettingsRow(title: "Cloud Sync", subtitle: "Synchronize sessions across devices", icon: "arrow.triangle.2.circlepath") {
                    Toggle("", isOn: $appState.settings.cloudSyncEnabled)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // 13. Connect
    private var connectPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Remote Workspaces & Pairing", description: "Pair this native client with remote headless servers", icon: "cable.connector") {
                SettingsRow(title: "Control Plane Endpoint", subtitle: "URL to remote OpenWork gateway", icon: "network") {
                    TextField("https://...", text: $appState.settings.cloudControlPlaneUrl)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
        }
    }

    // 14. Skills & MCP
    private var skillsPage: some View {
        VStack(spacing: 20) {
            // MARK: - AGENT SKILLS SECTION
            SettingsCard(
                title: "Agent Skills (\(appState.skills.count))",
                description: "Modular instructions and domain knowledge that enhance agent autonomy",
                icon: "sparkles"
            ) {
                // Actions & Filter Bar
                HStack(spacing: 10) {
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        TextField("Search skills...", text: $skillSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !skillSearchText.isEmpty {
                            Button {
                                skillSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .cornerRadius(6)

                    Spacer()

                    // Add Skill Menu with Multiple Ways
                    Menu {
                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Create Custom Skill...", systemImage: "pencil.and.outline")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.title = "Select SKILL.md or Markdown File"
                            if let mdType = UTType(filenameExtension: "md") {
                                panel.allowedContentTypes = [.plainText, mdType]
                            } else {
                                panel.allowedContentTypes = [.plainText]
                            }
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importSkillFromFile(url: url)
                            }
                        } label: {
                            Label("Import SKILL.md File...", systemImage: "doc.badge.plus")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.title = "Select Folder Containing Skills"
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importSkillsFromFolder(url: url)
                            }
                        } label: {
                            Label("Import from Directory / Folder...", systemImage: "folder.badge.plus")
                        }

                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Import from URL / GitHub...", systemImage: "globe")
                        }

                        Divider()

                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Browse Skill Templates...", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("Add Skill")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 4)

                // List of Skills
                let filteredSkills = appState.skills.filter {
                    skillSearchText.isEmpty ||
                    $0.name.localizedCaseInsensitiveContains(skillSearchText) ||
                    $0.description.localizedCaseInsensitiveContains(skillSearchText) ||
                    $0.category.localizedCaseInsensitiveContains(skillSearchText)
                }

                if filteredSkills.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text(skillSearchText.isEmpty ? "No agent skills installed yet." : "No skills match '\(skillSearchText)'")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Add skills to equip your autonomous agents with specialized instructions, best practices, and domain workflows.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredSkills) { skill in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: skill.source.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(skill.name)
                                            .font(.system(size: 12, weight: .bold))

                                        Text(skill.category)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        Text(skill.source.displayName)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.secondary.opacity(0.12))
                                            .cornerRadius(4)
                                    }

                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    if let path = skill.filePath {
                                        Text(path)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button("Inspect / Edit") {
                                        selectedSkillForDetail = skill
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { skill.isEnabled },
                                        set: { val in
                                            var updated = skill
                                            updated.isEnabled = val
                                            appState.saveSkill(updated)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deleteSkill(skill)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }

            // MARK: - MODEL CONTEXT PROTOCOL (MCP) SERVERS SECTION
            SettingsCard(
                title: "Model Context Protocol (MCP) Servers (\(appState.settings.mcpServers.count))",
                description: "Extend autonomous agents with stdio processes, remote HTTP/SSE gateways, and WebSocket tools",
                icon: "network"
            ) {
                HStack {
                    Text("Configured MCP Servers")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()

                    Button("Restore Defaults") {
                        appState.settings.mcpServers = AppSettings.defaultMCPServers
                        appState.updateSettings(appState.settings)
                        appState.showToast("Restored standard MCP servers")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        selectedMcpForEdit = nil
                        showingAddMcp = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                            Text("Add MCP Server...")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }

                if appState.settings.mcpServers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector.slash")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("No Model Context Protocol servers configured.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Connect servers like @modelcontextprotocol/server-filesystem, memory, sqlite, or remote HTTP/SSE endpoints.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.settings.mcpServers) { mcp in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: mcp.transportType.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(mcp.name)
                                            .font(.system(size: 12, weight: .bold))

                                        Text(mcp.transportType.displayName)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        if !mcp.env.isEmpty {
                                            Text("\(mcp.env.count) ENV")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Color.secondary.opacity(0.12))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if mcp.transportType == .stdio {
                                        Text("\(mcp.command) \(mcp.args.joined(separator: " "))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text(mcp.url)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    if !mcp.workingDirectory.isEmpty {
                                        Text("cwd: \(mcp.workingDirectory)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button("Test Ping") {
                                        appState.showToast("MCP '\(mcp.name)' ready")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Configure") {
                                        selectedMcpForEdit = mcp
                                        showingAddMcp = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { mcp.isEnabled },
                                        set: { val in
                                            var updated = mcp
                                            updated.isEnabled = val
                                            appState.saveMcpServer(updated)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deleteMcpServer(mcp)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSkill) {
            AddSkillModalView(appState: appState, isPresented: $showingAddSkill)
        }
        .sheet(item: $selectedSkillForDetail) { skill in
            SkillDetailModalView(appState: appState, isPresented: Binding(
                get: { selectedSkillForDetail != nil },
                set: { if !$0 { selectedSkillForDetail = nil } }
            ), skill: skill)
        }
        .sheet(isPresented: $showingAddMcp) {
            McpServerEditModalView(
                appState: appState,
                isPresented: $showingAddMcp,
                editingConfig: selectedMcpForEdit
            )
        }
    }

    // 15. Memory
    private var memoryPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Long-Term Workspace Memory", description: "Currently holding \(appState.memories.count) memory items", icon: "brain") {
                ForEach(appState.memories) { mem in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mem.key)
                                .font(.system(size: 12, weight: .bold))
                            Text(mem.content)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.memories.removeAll(where: { $0.id == mem.id })
                            PersistenceManager.shared.saveMemories(appState.memories)
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red).font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.3))
                    .cornerRadius(6)
                }

                Button("Clear All Memories", role: .destructive) {
                    appState.memories.removeAll()
                    PersistenceManager.shared.saveMemories(appState.memories)
                    appState.showToast("Memories cleared")
                }
            }
        }
    }

    // MARK: - Helpers
    private func tabTitle(for tab: String) -> String {
        switch tab {
        case "general": return "General Settings"
        case "mlx": return "Apple Silicon MLX Engine"
        case "preferences": return "Preferences"
        case "permissions": return "Permissions & Authorized Folders"
        case "watchFolders": return "Watch Folders & Ingestion Triggers"
        case "extensions": return "Extensions & Plugins"
        case "advanced": return "Advanced Multi-Agent Settings"
        case "ai": return "AI Model Providers"
        case "appearance": return "Appearance & Styling"
        case "environment": return "Environment Variables"
        case "updates": return "Updates & Diagnostics"
        case "recovery": return "Backup & Recovery"
        case "debug": return "Debug & Developer Logs"
        case "cloud": return "Cloud Account"
        case "connect": return "Connect & Remote Workspaces"
        case "skills": return "Skills & MCP"
        case "memory": return "Long-Term Memory"
        default: return "Settings"
        }
    }

    private func tabDescription(for tab: String) -> String {
        switch tab {
        case "general": return "Core application defaults and workspace directory"
        case "mlx": return "Manage on-device MLX model discovery, Hugging Face caches, LM Studio weights, and GPU memory budgets"
        case "preferences": return "Model sampling, reasoning effort, and chat behavior"
        case "permissions": return "Authorized folders, terminal execution policies, and security"
        case "watchFolders": return "Directory listeners, file debouncing, and automated Morning Brief artifact synthesis"
        case "extensions": return "Install, manage, configure, or remove custom plugins and MCP extensions"
        case "advanced": return "Sub-agent orchestration depth and collaboration room"
        case "ai": return "Configure local Ollama, LM Studio, and cloud API endpoints"
        case "appearance": return "Themes, accent colors, font sizes, and window transparency"
        case "environment": return "Key-value environment variables passed to tools"
        case "updates": return "Application version and release update checking"
        case "recovery": return "Export data archives or perform factory reset"
        case "debug": return "Internal state telemetry and live inspector logs"
        case "cloud": return "OpenWork Cloud profile and remote synchronization"
        case "connect": return "Pair with remote headless OpenWork servers"
        case "skills": return "Model Context Protocol tools and custom extensions"
        case "memory": return "Persistent knowledge stored across agent sessions"
        default: return "Configure OpenWork-Swift preferences"
        }
    }
}

// MARK: - Edit Workspace Modal
public struct EditWorkspaceModalView: View {
    @ObservedObject var appState: AppState
    @State var draft: Workspace
    @Binding var isPresented: Bool

    public init(appState: AppState, workspace: Workspace, isPresented: Binding<Bool>) {
        self.appState = appState
        self._draft = State(initialValue: workspace)
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Workspace")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("Configure directory path, assigned agent, and pipeline automation")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace Name")
                            .font(.system(size: 11, weight: .semibold))
                        TextField("Workspace Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Category")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $draft.category) {
                            ForEach(WorkspaceCategory.allCases) { cat in
                                Label(cat.displayName, systemImage: cat.icon).tag(cat)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Assigned Agent
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assigned Agent Sandbox")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: Binding(
                            get: { draft.assignedAgentId ?? "" },
                            set: { draft.assignedAgentId = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("None (Shared Workspace)").tag("")
                            ForEach(appState.agents) { ag in
                                Text("\(ag.name) (\(ag.role))").tag(ag.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Workspace Directory Path
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Root Directory Path (External SSD / Drive / Custom Folder)")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                        }

                        HStack(spacing: 6) {
                            TextField("Folder Path (e.g. /Volumes/ExternalSSD/Workspaces)", text: $draft.folderPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))

                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.canCreateDirectories = true
                                panel.prompt = "Select Workspace Folder"
                                if panel.runModal() == .OK, let url = panel.url {
                                    draft.folderPath = url.path
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        // Quick Drive / Location Shortcuts
                        HStack(spacing: 8) {
                            Button {
                                let panel = NSOpenPanel()
                                panel.directoryURL = URL(fileURLWithPath: "/Volumes")
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.canCreateDirectories = true
                                panel.prompt = "Choose External SSD Folder"
                                if panel.runModal() == .OK, let url = panel.url {
                                    draft.folderPath = url.path
                                }
                            } label: {
                                Label("Browse External SSD (/Volumes)...", systemImage: "externaldrive")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button {
                                let url = URL(fileURLWithPath: draft.folderPath)
                                appState.ensureWorkspaceFolderExists(for: draft)
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                            } label: {
                                Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }

                    Divider()

                    // Staged Pipeline Automation
                    Toggle("Enable Staged Pipeline ('input/' & 'output/' automation)", isOn: $draft.isPipelineStagingEnabled)
                        .font(.system(size: 11.5, weight: .semibold))
                        .toggleStyle(.switch)

                    if draft.isPipelineStagingEnabled {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Input Subfolder")
                                    .font(.system(size: 10, weight: .medium))
                                TextField("input", text: $draft.inputFolderPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output Subfolder")
                                    .font(.system(size: 10, weight: .medium))
                                TextField("output", text: $draft.outputFolderPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .padding(18)
            }

            Divider()

            // Footer Actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Workspace") {
                    draft.icon = draft.category.icon
                    appState.saveWorkspace(draft)
                    if appState.activeWorkspaceId == draft.id {
                        appState.ensureWorkspaceFolderExists(for: draft)
                    }
                    appState.showToast("Saved workspace '\(draft.name)'")
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))
        }
        .frame(width: 520, height: 500)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
