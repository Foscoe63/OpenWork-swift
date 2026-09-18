import SwiftUI

public struct ToolsPanelView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AGENT TOOLS & MCP")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
                        Text("Active Capabilities for Autonomous Agents")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                VStack(spacing: 8) {
                    ForEach(appState.tools) { tool in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: tool.category.icon)
                                .font(.system(size: 13))
                                .foregroundColor(tool.isEnabled ? ThemeColors.accent(for: appState.settings.accentColor) : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tool.displayName)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                    Text(tool.name)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                }

                                Text(tool.description)
                                    .font(.system(size: 10))
                                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { tool.isEnabled },
                                set: { val in
                                    if let idx = appState.tools.firstIndex(where: { $0.id == tool.id }) {
                                        appState.tools[idx].isEnabled = val
                                        PersistenceManager.shared.saveTools(appState.tools)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        .padding(10)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 16)
        }
    }
}
