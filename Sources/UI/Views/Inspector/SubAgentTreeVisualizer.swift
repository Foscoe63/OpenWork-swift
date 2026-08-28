import SwiftUI

public struct SubAgentTreeVisualizer: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AGENT HIERARCHY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
                        Text("Live Sub-Agent Orchestration Tree")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                // Root Lead Agent Card
                rootLeadAgentCard

                // Sub-Agent Branch Nodes
                if appState.activeSubAgentTasks.isEmpty && appState.currentAgent.subAgentIds.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 24))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.5))
                        Text("No active sub-agents spawned yet.")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.activeSubAgentTasks) { task in
                            subAgentTaskNode(task: task)
                        }

                        // Also show configured sub-agents
                        if appState.activeSubAgentTasks.isEmpty {
                            ForEach(appState.currentAgent.subAgentIds, id: \.self) { subId in
                                if let agent = appState.agents.first(where: { $0.id == subId }) {
                                    configuredSubAgentNode(agent: agent)
                                }
                            }
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Root Lead Agent Card
    private var rootLeadAgentCard: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.currentAgent.avatar)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color(hex: appState.currentAgent.color))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(appState.currentAgent.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                    Text("LEAD")
                        .font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.2))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        .cornerRadius(3)
                }

                Text(appState.currentAgent.role)
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            Circle()
                .fill(appState.isGenerating ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
        }
        .padding(10)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(8)
        .padding(.horizontal, 12)
    }

    // MARK: - Active Sub-Agent Task Node
    private func subAgentTaskNode(task: SubAgentTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Tree branch line indicator
            Rectangle()
                .fill(ThemeColors.border(for: appState.settings.theme))
                .frame(width: 2)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: task.subAgentAvatar)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: task.status.colorHex))

                    Text(task.subAgentName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                    Spacer()

                    Text(task.status.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: task.status.colorHex))
                }

                Text(task.taskTitle)
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                if !task.resultSummary.isEmpty {
                    Text(task.resultSummary)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .padding(4)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(4)
                }

                // Progress Bar
                ProgressView(value: task.progress)
                    .tint(Color(hex: task.status.colorHex))
                    .scaleEffect(y: 0.5)
            }
            .padding(8)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .cornerRadius(6)
        }
        .padding(.trailing, 12)
    }

    // MARK: - Configured Sub-Agent Node
    private func configuredSubAgentNode(agent: Agent) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(ThemeColors.border(for: appState.settings.theme))
                .frame(width: 2, height: 28)

            Image(systemName: agent.avatar)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: agent.color))

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Text(agent.role)
                    .font(.system(size: 9.5))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            Text("Ready")
                .font(.system(size: 9))
                .foregroundColor(.green)
        }
        .padding(.trailing, 12)
    }
}
