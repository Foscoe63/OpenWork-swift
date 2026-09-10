import SwiftUI
import AppKit

/// Shared workspace picker used by the sidebar ("Core Workspaces & Research") and the chat header.
/// Both bind to `appState.activeWorkspaceId`, so selections stay in sync.
public struct WorkspaceSwitcherMenu<LabelContent: View>: View {
    @ObservedObject var appState: AppState
    var onSelectWorkspace: (String) -> Void
    var showsManagementActions: Bool
    @ViewBuilder var label: () -> LabelContent

    @State private var showingWorkspaceSheet = false
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceCategory: WorkspaceCategory = .general
    @State private var newWorkspaceAgentId: String = ""
    @State private var newWorkspaceFolderPath: String = ""

    public init(
        appState: AppState,
        showsManagementActions: Bool = true,
        onSelectWorkspace: @escaping (String) -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.appState = appState
        self.showsManagementActions = showsManagementActions
        self.onSelectWorkspace = onSelectWorkspace
        self.label = label
    }

    public var body: some View {
        Menu {
            let coreWorkspaces = appState.workspaces.filter {
                $0.category == .general || $0.category == .research || $0.category == .project
            }
            if !coreWorkspaces.isEmpty {
                Section("Core Workspaces & Research") {
                    ForEach(coreWorkspaces) { ws in
                        workspaceButton(ws)
                    }
                }
            }

            let agentWorkspaces = appState.workspaces.filter { $0.category == .agent }
            if !agentWorkspaces.isEmpty {
                Section("Agent Workspaces") {
                    ForEach(agentWorkspaces) { ws in
                        workspaceButton(ws)
                    }
                }
            }

            if showsManagementActions {
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
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .sheet(isPresented: $showingWorkspaceSheet) {
            newWorkspaceModal
        }
    }

    @ViewBuilder
    private func workspaceButton(_ ws: Workspace) -> some View {
        Button {
            onSelectWorkspace(ws.id)
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
                    resetNewWorkspaceFields()
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
                    onSelectWorkspace(ws.id)
                    showingWorkspaceSheet = false
                    resetNewWorkspaceFields()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func resetNewWorkspaceFields() {
        newWorkspaceName = ""
        newWorkspaceCategory = .general
        newWorkspaceAgentId = ""
        newWorkspaceFolderPath = ""
    }
}
