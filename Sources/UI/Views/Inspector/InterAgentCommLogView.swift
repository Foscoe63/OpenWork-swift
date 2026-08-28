import SwiftUI

public struct InterAgentCommLogView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("INTER-AGENT COMMUNICATION")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
                        Text("Live Agent Message Routing Network")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    Spacer()

                    Button {
                        appState.interAgentMessages.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.plain)
                    .help("Clear Message Log")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                if appState.interAgentMessages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.system(size: 24))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.5))
                        Text("No agent messages recorded yet.")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.interAgentMessages) { msg in
                            agentMessageCard(msg: msg)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func agentMessageCard(msg: AgentMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Routing Header
            HStack(spacing: 6) {
                Image(systemName: msg.messageType.icon)
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

                Text(msg.fromAgentName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                Text(msg.toAgentName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Spacer()

                Text(msg.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))
            }

            // Content
            Text(msg.content)
                .font(.system(size: 11.5))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                .lineSpacing(2)

            // Message Type Tag
            Text(msg.messageType.displayName)
                .font(.system(size: 8.5, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(ThemeColors.border(for: appState.settings.theme))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                .cornerRadius(4)
        }
        .padding(10)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}
