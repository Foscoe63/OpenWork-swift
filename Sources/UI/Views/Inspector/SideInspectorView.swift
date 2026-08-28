import SwiftUI

public struct SideInspectorView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Inspector Tab Bar
            inspectorTabBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Tab Content
            switch appState.inspectorTab {
            case .subagents:
                SubAgentTreeVisualizer(appState: appState)
            case .comms:
                InterAgentCommLogView(appState: appState)
            case .artifacts:
                ArtifactsPanelView(appState: appState)
            case .tools:
                ToolsPanelView(appState: appState)
            case .terminal:
                terminalView
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Inspector Tab Bar
    private var inspectorTabBar: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                let isSelected = appState.inspectorTab == tab
                Button {
                    appState.inspectorTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11))
                        Text(tab.title)
                            .font(.system(size: 9.5, weight: isSelected ? .bold : .regular))
                    }
                    .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
    }

    // MARK: - Interactive Terminal View
    private var terminalView: some View {
        IntegratedTerminalView(appState: appState)
    }
}

public struct IntegratedTerminalView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var terminalSession = WorkspaceTerminalSession.shared
    @State private var inputCommand: String = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(terminalSession.isRunning ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(terminalSession.isRunning ? "RUNNING" : "READY")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(terminalSession.isRunning ? .orange : .green)
                }

                Spacer()

                Button("Clear") {
                    terminalSession.clear()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                if terminalSession.isRunning {
                    Button("Stop", role: .destructive) {
                        terminalSession.terminate()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            // Console Output ScrollView
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(terminalSession.lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(line.isError ? Color.red.opacity(0.9) : (line.text.hasPrefix("$") ? Color.green : Color.white.opacity(0.85)))
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.8))
                .onMessageCountChanged(count: terminalSession.lines.count) {
                    if let last = terminalSession.lines.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Command Prompt Input
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)

                TextField("Run zsh command...", text: $inputCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        executeCurrentCommand()
                    }

                Button {
                    executeCurrentCommand()
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(inputCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
        }
    }

    private func executeCurrentCommand() {
        guard !inputCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cmd = inputCommand
        inputCommand = ""
        terminalSession.execute(command: cmd, in: appState.currentWorkspace.folderPath)
    }
}
