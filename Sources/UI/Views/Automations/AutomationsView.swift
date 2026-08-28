import SwiftUI

public struct AutomationsView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddModal = false
    @State private var showingVisualBuilder = false
    @State private var editingAutomation: Automation? = nil

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automations & Workflows")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("Configure recurring agent tasks, directory watch triggers, and automated workflows")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                Spacer()

                Button {
                    showingVisualBuilder = true
                } label: {
                    Label("Visual Flow Builder", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)

                Button {
                    showingAddModal = true
                } label: {
                    Label("Add Automation", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeColors.accent(for: appState.settings.accentColor))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            ScrollView {
                VStack(spacing: 12) {
                    if appState.automations.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("No automations configured yet.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        ForEach(appState.automations) { auto in
                            automationCard(auto: auto)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddModal) {
            NewAutomationModalView(appState: appState, isPresented: $showingAddModal)
        }
        .sheet(isPresented: $showingVisualBuilder) {
            VisualAgentFlowBuilderView(appState: appState, isPresented: $showingVisualBuilder)
        }
    }

    private func automationCard(auto: Automation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: auto.triggerType.icon)
                    .font(.system(size: 16))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    .frame(width: 32, height: 32)
                    .background(ThemeColors.border(for: appState.settings.theme))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(auto.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text(auto.triggerType.displayName + " • " + auto.cronSchedule)
                        .font(.system(size: 10.5))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                Spacer()

                Button("Run Now") {
                    appState.showToast("Triggered automation: \(auto.name)")
                    appState.createNewSession(agentId: auto.targetAgentId)
                    appState.sendMessage(text: auto.promptTemplate)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))

                Toggle("", isOn: Binding(
                    get: { auto.isEnabled },
                    set: { val in
                        if let idx = appState.automations.firstIndex(where: { $0.id == auto.id }) {
                            appState.automations[idx].isEnabled = val
                            PersistenceManager.shared.saveAutomations(appState.automations)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button {
                    appState.automations.removeAll(where: { $0.id == auto.id })
                    PersistenceManager.shared.saveAutomations(appState.automations)
                    appState.showToast("Automation deleted")
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.8))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }

            Text(auto.promptTemplate)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.15))
                .cornerRadius(6)
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}

public struct NewAutomationModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var triggerType: AutomationTriggerType = .scheduled
    @State private var schedule: String = "Daily at 9:00 AM"
    @State private var targetAgentId: String = "lead-assistant"
    @State private var promptTemplate: String = "Scan workspace files and provide a status update."

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create Automation")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Automation Name")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("e.g. Nightly Codebase Sweep", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trigger Type")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $triggerType) {
                            ForEach(AutomationTriggerType.allCases, id: \.self) { t in
                                HStack {
                                    Image(systemName: t.icon)
                                    Text(t.displayName)
                                }
                                .tag(t)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Schedule / Event Condition")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("e.g. Every 2 hours / On git commit", text: $schedule)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Assigned Agent")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $targetAgentId) {
                            ForEach(appState.agents) { ag in
                                Text(ag.name).tag(ag.id)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt Template to Execute")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextEditor(text: $promptTemplate)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(height: 100)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Automation") {
                    guard !name.isEmpty else { return }
                    let auto = Automation(
                        workspaceId: appState.activeWorkspaceId,
                        name: name,
                        description: description,
                        triggerType: triggerType,
                        cronSchedule: schedule,
                        targetAgentId: targetAgentId,
                        promptTemplate: promptTemplate
                    )
                    appState.automations.append(auto)
                    PersistenceManager.shared.saveAutomations(appState.automations)
                    isPresented = false
                    appState.showToast("Automation '\(name)' created")
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 520)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
